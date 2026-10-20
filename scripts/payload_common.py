#!/usr/bin/env python3
"""Shared payload helpers for the Android and iOS app packaging scripts."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('PI_SPACES_SOURCE', str(ROOT.parent / 'pi-spaces'))).resolve()
RUNTIME = ROOT / 'runtime'

# Files that make up the mobile runtime payload (same set on both platforms).
FILES = ['server.mjs', 'common.mjs', 'remote-env.mjs', 'env-server.mjs', 'pi-serverd.mjs',
         'space-keystore.mjs', 'spaces-mobile.mjs', 'remote-client.mjs', 'remote-provision.mjs', 'remote-state.mjs', 'pi-spaces.mjs', 'package.json',
         'package-lock.json', 'public', 'node_modules']


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
