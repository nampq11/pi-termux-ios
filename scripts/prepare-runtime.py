#!/usr/bin/env python3
"""Refresh pi-spaces from source and package the mobile runtime before every Android build."""
import gzip
import hashlib
from pathlib import Path
import sys
import tarfile
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from payload_common import (ROOT, RUNTIME, FILES, refresh_pi_spaces_bundle, check_runtime_inputs,
                            entries, digest, replace_if_changed)

ASSETS = ROOT / 'android/app/src/main/assets'

refresh_pi_spaces_bundle()
check_runtime_inputs()
if not (ASSETS / 'rootfs.bin').is_file():
    raise SystemExit('Termux rootfs.bin is missing; prepare the rootfs asset first')

ASSETS.mkdir(parents=True, exist_ok=True)
temporary = None
try:
    with tempfile.NamedTemporaryFile(dir=ASSETS, suffix='.tmp', delete=False) as raw:
        temporary = Path(raw.name)
        with gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                for name in FILES:
                    for path in entries(RUNTIME / name):
                        info = archive.gettarinfo(str(path), 'runtime/' + path.relative_to(RUNTIME).as_posix())
                        info.uid = info.gid = info.mtime = 0
                        info.uname = info.gname = ''
                        if info.isfile():
                            with path.open('rb') as stream:
                                archive.addfile(info, stream)
                        else:
                            archive.addfile(info)
    replace_if_changed(temporary, ASSETS / 'runtime.bin')
    temporary = None
    # Both payloads determine extraction; RuntimeInstaller's version still covers installer changes.
    fingerprint = hashlib.sha256(digest(ASSETS / 'rootfs.bin') + digest(ASSETS / 'runtime.bin')).hexdigest()
    with tempfile.NamedTemporaryFile(dir=ASSETS, suffix='.tmp', delete=False) as raw:
        temporary = Path(raw.name)
        raw.write((fingerprint + '\n').encode('ascii'))
    replace_if_changed(temporary, ASSETS / 'payload.sha256')
    temporary = None
    print(f'Mobile assets prepared; payload {fingerprint}')
finally:
    if temporary:
        temporary.unlink(missing_ok=True)
