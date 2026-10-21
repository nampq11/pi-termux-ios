#!/usr/bin/env python3
"""Shared payload helpers for the Android and iOS app packaging scripts."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('PI_SPACES_SOURCE', str(ROOT.parent / 'pi-spaces'))).resolve()
RUNTIME = ROOT / 'runtime'

# Files that make up the mobile runtime payload (same set on both platforms).
FILES = ['server.mjs', 'common.mjs', 'remote-env.mjs', 'env-server.mjs', 'pi-serverd.mjs',
         'serverd-tcp.mjs', 'space-keystore.mjs', 'spaces-mobile.mjs', 'remote-client.mjs',
         'remote-provision.mjs', 'remote-state.mjs', 'ssh-transport.mjs', 'ssh-js-backend.mjs',
         'pi-spaces.mjs', 'package.json', 'package-lock.json', 'public', 'node_modules']

# Static relative imports (`from './x.mjs'`, `import './x.mjs'`); dynamic
# import() and bare specifiers (node_modules) are out of scope by design.
_RELATIVE_IMPORT_RE = re.compile(r"""\bfrom\s+['"](\.[^'"]+)['"]|\bimport\s+['"](\.[^'"]+)['"]""")
_REMOTE_FILES_RE = re.compile(r'export const REMOTE_FILES = \[([^\]]*)\]', re.S)


def import_closure(entry):
    """Transitive static relative imports of a runtime entry file (names relative to runtime/)."""
    seen, stack = set(), [entry]
    while stack:
        name = stack.pop()
        if name in seen:
            continue
        seen.add(name)
        try:
            text = (RUNTIME / name).read_text()
        except FileNotFoundError:
            continue  # reported as missing by the manifest set difference
        for match in _RELATIVE_IMPORT_RE.findall(text):
            spec = match[0] or match[1]
            stack.append(spec[2:])  # strip the leading './'
    seen.discard(entry)
    return seen


def check_import_closures():
    """An entry importing an unmanifested file ships a runtime that crashes on
    the device (and on remote hosts); fail the build instead. The same check
    runs on npm test (runtime/test-manifests.mjs) for the inner loop."""
    missing = import_closure('server.mjs') - set(FILES)
    if missing:
        raise SystemExit(f'server.mjs imports files missing from FILES in payload_common.py: {sorted(missing)}')
    match = _REMOTE_FILES_RE.search((RUNTIME / 'remote-provision.mjs').read_text())
    if not match:
        raise SystemExit('cannot parse REMOTE_FILES from runtime/remote-provision.mjs')
    remote_files = set(re.findall(r"'([^']+)'", match.group(1)))
    missing = import_closure('pi-serverd.mjs') - remote_files
    if missing:
        raise SystemExit(f'pi-serverd.mjs imports files missing from REMOTE_FILES in remote-provision.mjs: {sorted(missing)}')
    if import_closure('env-server.mjs'):
        raise SystemExit('env-server.mjs must stay dependency-free (no relative imports)')


def refresh_pi_spaces_bundle():
    """Rebuild pi-spaces.mjs from the sibling source checkout when available."""
    source_available = (SOURCE / 'scripts/bundle-mobile.mjs').is_file()
    if not source_available:
        print(f'WARNING: pi-spaces source checkout missing or incompatible: {SOURCE}; '
              'using existing mobile bundles without refreshing them. Set PI_SPACES_SOURCE to enable refresh.',
              file=sys.stderr)
        return
    subprocess.run(['npm', 'run', 'bundle'], cwd=SOURCE, check=True,
                   env={**os.environ, 'PI_SPACES_MOBILE_ROOT': str(ROOT)})
    if not (RUNTIME / 'pi-spaces.mjs').is_file():
        raise SystemExit('Required mobile bundle missing: pi-spaces.mjs; prepare it from a pi-spaces source checkout first')


def check_runtime_inputs():
    """Verify the payload inputs exist before packaging."""
    if not (RUNTIME / 'node_modules/@earendil-works/pi-durable').is_dir():
        raise SystemExit('Mobile runtime dependencies missing; install the locked runtime dependencies first')
    check_import_closures()
    for name in FILES:
        if name not in ('pi-spaces.mjs', 'space-examples') and not (RUNTIME / name).exists():
            raise SystemExit(f'Required runtime input missing: {name}')
    if (RUNTIME / 'space-examples').is_dir():
        FILES.append('space-examples')
    else:
        print('WARNING: optional space-examples missing; packaging the runtime without CLI examples', file=sys.stderr)


def entries(path):
    """All payload files: skip node_modules/.bin, keep valid symlinks, recurse sorted."""
    if path.name == '.bin':
        return
    if not path.exists() and not path.is_symlink():
        return
    # Retain valid links, exclude broken links without deleting developer files.
    if path.is_symlink():
        if path.exists():
            yield path
        return
    yield path
    if path.is_dir():
        for child in sorted(path.iterdir()):
            yield from entries(child)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.digest()


def replace_if_changed(source, target):
    """Atomically replace target only when content differs, to keep builds incremental."""
    if target.is_file() and digest(source) == digest(target):
        source.unlink()
    else:
        source.replace(target)
