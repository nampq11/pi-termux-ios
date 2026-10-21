// Minimal USTAR archive writer. Remote provisioning stages a daemon release
// as a tar before uploading it; iOS denies spawning `tar`, so the archive is
// built in-process. Directories and regular files only — the remote payload
// is flat source and package files. uid/gid/mtime are normalized to zero for
// deterministic output (the release identity is the content hash in
// remote-provision.mjs, not archive metadata). Output extracts with any tar.
import { lstatSync, readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';

const BLOCK = 512;

/** Fixed-width, NUL-terminated octal field. */
function octal(value, length) {
  const s = value.toString(8);
  if (s.length > length - 1) throw new Error(`tar field overflow: ${s}`);
  return Buffer.from(s.padStart(length - 1, '0') + '\0', 'ascii');
}

function header(name, mode, size, typeflag) {
  if (Buffer.byteLength(name) > 100 || Buffer.byteLength(name) !== name.length) {
    throw new Error(`tar name too long or not ascii: ${name}`);
  }
  const h = Buffer.alloc(BLOCK);
  h.write(name, 0, 100, 'ascii');
  octal(mode & 0o7777, 8).copy(h, 100);
  octal(0, 8).copy(h, 108);  // uid
  octal(0, 8).copy(h, 116);  // gid
  octal(size, 12).copy(h, 124);
  octal(0, 12).copy(h, 136); // mtime
  h.write('        ', 148, 8, 'ascii'); // chksum placeholder: spaces
  h.write(typeflag, 156, 1, 'ascii');
  h.write('ustar\0', 257, 6, 'ascii');
  h.write('00', 263, 2, 'ascii');
  const sum = h.reduce((a, b) => a + b, 0);
  // chksum: 6 octal digits, NUL, space
  h.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'ascii');
  return h;
}

function fileEntry(name, mode, data) {
  const blocks = Math.ceil(data.length / BLOCK);
  return Buffer.concat([header(name, mode, data.length, '0'), data, Buffer.alloc(blocks * BLOCK - data.length)]);
}

/** Archive every entry in `names` (a file or a directory, walked in sorted
 * order) relative to `root`, as a USTAR buffer. */
export function buildUstar(root, names) {
  const parts = [];
  const add = (relative) => {
    const full = path.join(root, relative);
    const st = lstatSync(full);
    if (st.isDirectory()) {
      parts.push(header(relative + '/', 0o755, 0, '5'));
      for (const n of readdirSync(full).sort()) add(path.posix.join(relative, n));
    } else if (st.isFile()) {
      parts.push(fileEntry(relative, st.mode, readFileSync(full)));
    } else {
      throw new Error(`cannot archive non-regular file: ${relative}`);
    }
  };
  for (const n of names) add(n);
  parts.push(Buffer.alloc(BLOCK * 2)); // end-of-archive
  return Buffer.concat(parts);
}
