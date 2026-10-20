#!/usr/bin/env python3
"""Package the mobile runtime for the iOS app and fetch the embedded Node engine.

Produces:
  ios/Sources/PiMobile/Resources/runtime.zip   JS runtime payload (same file set as Android)
  ios/Sources/PiMobile/Resources/payload.sha256  fingerprint of runtime.zip
  ios/Frameworks/NodeMobile.xcframework        nodejs-mobile iOS engine (downloaded, pinned)

The Node engine cannot be exec'd on iOS, so no termux rootfs is shipped; the
Swift app runs the runtime in-process through node_start() instead.
"""
import hashlib
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import subprocess
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from payload_common import (ROOT, RUNTIME, FILES, refresh_pi_spaces_bundle, check_runtime_inputs,
                            entries, digest, replace_if_changed)

IOS = ROOT / 'ios'
RESOURCES = IOS / 'Sources/PiMobile/Resources'
FRAMEWORKS = IOS / 'Frameworks'
TOOLS = ROOT / 'tools'

NODE_MOBILE_VERSION = '24.22.0-0'
NODE_MOBILE_URL = f'https://github.com/fogtape/nodejs-mobile/releases/download/v{NODE_MOBILE_VERSION}/nodejs-mobile-ios-{NODE_MOBILE_VERSION}.zip'
NODE_MOBILE_SHA256 = 'f21ba80d2fa3d1fc313c48567576605209c07f41be66282ce7e0d687f2f42bd9'

ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)


def ensure_node_engine():
    framework = FRAMEWORKS / 'NodeMobile.xcframework'
    binaries = [framework / slice / 'NodeMobile.framework/NodeMobile'
                for slice in ('ios-arm64', 'ios-arm64-simulator')]
    if all(b.is_file() and os.access(b, os.X_OK) for b in binaries):
        return
    archive = TOOLS / Path(NODE_MOBILE_URL).name
    TOOLS.mkdir(parents=True, exist_ok=True)
    if not (archive.is_file() and digest(archive).hex() == NODE_MOBILE_SHA256):
        print(f'downloading nodejs-mobile {NODE_MOBILE_VERSION} …', file=sys.stderr)
        with tempfile.NamedTemporaryFile(dir=TOOLS, suffix='.tmp', delete=False) as raw:
            temporary = Path(raw.name)
        # curl, not urllib: some environments corrupt or truncate urllib downloads
        subprocess.run(['curl', '-fsSL', '-o', str(temporary), NODE_MOBILE_URL], check=True)
        if digest(temporary).hex() != NODE_MOBILE_SHA256:
            temporary.unlink(missing_ok=True)
            raise SystemExit('nodejs-mobile download failed the pinned SHA256 check')
        replace_if_changed(temporary, archive)
    if framework.is_dir():
        shutil.rmtree(framework)
    with tempfile.TemporaryDirectory(dir=FRAMEWORKS) as staging:
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(staging)
        shutil.move(Path(staging) / 'NodeMobile.xcframework', framework)
    for binary in binaries:
        # unzip drops the executable bit; SwiftPM rejects frameworks without it
        binary.chmod(binary.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(f'NodeMobile.xcframework {NODE_MOBILE_VERSION} ready', file=sys.stderr)


def build_runtime_zip():
    RESOURCES.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=RESOURCES, suffix='.tmp', delete=False) as raw:
            temporary = Path(raw.name)
            # fixed timestamps + stored entries: the on-device extractor (RuntimeArchive.swift)
            # has no deflate decompressor, so the payload trades size for simplicity
            with zipfile.ZipFile(raw, mode='w', compression=zipfile.ZIP_STORED) as archive:
                for name in FILES:
                    for path in entries(RUNTIME / name):
                        if path.is_symlink():
                            continue
                        relative = 'runtime/' + path.relative_to(RUNTIME).as_posix()
                        if path.is_dir():
                            info = zipfile.ZipInfo(relative + '/', ZIP_EPOCH)
                            info.external_attr = (0o40755 << 16) | 0x10
                            archive.writestr(info, b'')
                        else:
                            info = zipfile.ZipInfo(relative, ZIP_EPOCH)
                            info.external_attr = 0o644 << 16
                            with path.open('rb') as stream:
                                archive.writestr(info, stream.read())
        replace_if_changed(temporary, RESOURCES / 'runtime.zip')
        temporary = None
        fingerprint = hashlib.sha256(digest(RESOURCES / 'runtime.zip')).hexdigest()
        with tempfile.NamedTemporaryFile(dir=RESOURCES, suffix='.tmp', delete=False) as raw:
            temporary = Path(raw.name)
            raw.write((fingerprint + '\n').encode('ascii'))
        replace_if_changed(temporary, RESOURCES / 'payload.sha256')
        temporary = None
        print(f'iOS runtime payload prepared; payload {fingerprint}', file=sys.stderr)
    finally:
        if temporary:
            temporary.unlink(missing_ok=True)


refresh_pi_spaces_bundle()
check_runtime_inputs()
ensure_node_engine()
build_runtime_zip()
