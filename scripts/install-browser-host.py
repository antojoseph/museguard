#!/usr/bin/env python3
"""Prepare Muse Guard's native host; --install explicitly registers it in Chrome.

The default writes only a reviewable package under build/BrowserInstall. Loading
BrowserExtension in Chrome is a separate, user-controlled action.
"""
from __future__ import annotations
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
HOST_NAME = 'com.antojoseph.museguard'


def extension_id(manifest_path):
    manifest = json.loads(Path(manifest_path).read_text())
    encoded = manifest.get('key')
    if not isinstance(encoded, str):
        raise ValueError('The extension manifest needs its stable public key before preparing the host.')
    public_key = base64.b64decode(encoded, validate=True)
    digest = hashlib.sha256(public_key).digest()[:16]
    return ''.join(chr(ord('a') + nibble) for byte in digest for nibble in (byte >> 4, byte & 15))


def write_private(path, contents, mode=0o600):
    path = Path(path)
    # Never follow a user-created symlink at a host/config destination.
    if path.is_symlink():
        raise ValueError(f'Refusing a symbolic-link destination: {path}')
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, 'O_NOFOLLOW', 0), mode)
    with os.fdopen(descriptor, 'w') as stream:
        stream.write(contents)
    path.chmod(mode)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install', action='store_true', help='Register for this user\'s Google Chrome after reviewing the preview package.')
    parser.add_argument('--extension-manifest', type=Path, default=ROOT / 'BrowserExtension/manifest.json')
    parser.add_argument('--python', type=Path, default=Path(sys.executable))
    arguments = parser.parse_args(argv)
    identifier = extension_id(arguments.extension_manifest)
    origin = f'chrome-extension://{identifier}/'
    home = Path.home()
    support = home / 'Library/Application Support/MuseGuard'
    directory = support / 'BrowserNativeHost' if arguments.install else ROOT / 'build/BrowserInstall'
    if directory.is_symlink():
        raise ValueError('Refusing a symbolic-link native host directory.')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    interpreter = arguments.python.resolve(strict=True)
    if not interpreter.is_file() or not os.access(interpreter, os.X_OK):
        raise ValueError('The selected Python interpreter is not executable.')
    script = directory / 'muse_guard_host.py'
    write_private(script, (ROOT / 'BrowserNativeHost/muse_guard_host.py').read_text())
    configuration = directory / 'config.json'
    write_private(configuration, json.dumps(dict(allowed_origins=[origin], socket_path=str(support / 'BrowserBridge/bridge.sock')), indent=2) + '\n')
    wrapper = directory / 'muse-guard-host'
    write_private(wrapper, '#!/bin/sh\nexec ' + ' '.join(shlex.quote(str(value)) for value in (interpreter, script, '--config', configuration)) + ' "$@"\n', 0o700)
    manifest = dict(name=HOST_NAME, description='Muse Guard local browser safety bridge', path=str(wrapper), type='stdio', allowed_origins=[origin])
    write_private(directory / f'{HOST_NAME}.json', json.dumps(manifest, indent=2) + '\n')
    if arguments.install:
        hosts = home / 'Library/Application Support/Google/Chrome/NativeMessagingHosts'
        if hosts.is_symlink():
            raise ValueError('Refusing a symbolic-link Chrome host directory.')
        hosts.mkdir(parents=True, exist_ok=True)
        write_private(hosts / f'{HOST_NAME}.json', json.dumps(manifest, indent=2) + '\n')
        print('Registered Muse Guard native messaging for Google Chrome.')
    else:
        print('Prepared only; Chrome registration was not changed.')
    print(f'Extension ID: {identifier}')
    print(f'Host package: {directory}')
    print(f'Extension folder: {arguments.extension_manifest.resolve().parent}')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
