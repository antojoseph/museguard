#!/usr/bin/env python3
"""Verify the checkpoint, reopen Blender, or resume Pi without copying secrets."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ASSET = ROOT / 'outputs/plush-character/cream-mascot-locomotion.blend'
GUIDE = ROOT / 'outputs/resume/RESUME.md'


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def verify():
    manifest = json.loads((ROOT / 'outputs/resume/assets-manifest.json').read_text())
    failures = []
    for entry in manifest['files']:
        path = ROOT / entry['path']
        if not path.is_file():
            failures.append(entry['path'] + ': missing')
        elif path.stat().st_size != entry['bytes'] or digest(path) != entry['sha256']:
            failures.append(entry['path'] + ': changed since checkpoint')
    if failures:
        raise RuntimeError('\n'.join(failures))
    print('Verified {} saved deliverables against the checkpoint manifest.'.format(len(manifest['files'])))
    print('Latest scene: ' + str(ASSET))
    print('Resume guide: ' + str(GUIDE))
    print('Blender installed: ' + str(Path('/Applications/Blender.app').exists()))
    print('Pi installed: ' + str((Path.home() / '.local/bin/pi').is_file()))


def prepare_pi():
    state = ROOT / '.local/pi-agent'
    sessions = ROOT / '.local/pi-sessions'
    state.mkdir(parents=True, exist_ok=True)
    sessions.mkdir(parents=True, exist_ok=True)
    template = ROOT / 'config/pi'
    for name in ['settings.json', 'models.json', 'mcp.json']:
        shutil.copy2(template / name, state / name)
    shutil.copytree(template / 'extensions', state / 'extensions', dirs_exist_ok=True)

    helper = Path.home() / '.pi/agent/baseten-key.py'
    models = json.loads((state / 'models.json').read_text())
    if helper.is_file():
        source = '!/usr/bin/python3 ' + shlex.quote(str(helper))
    elif os.environ.get('BASETEN_API_KEY'):
        source = 'BASETEN_API_KEY'
    else:
        raise RuntimeError('Pi authentication is external to Git. Restore the existing private Baseten helper or set BASETEN_API_KEY before launching Pi.')
    for provider in models['providers'].values():
        provider['apiKey'] = source
    (state / 'models.json').write_text(json.dumps(models, indent=2) + '\n')

    uvx = shutil.which('uvx') or str(Path.home() / '.local/bin/uvx')
    if not Path(uvx).is_file():
        raise RuntimeError('Install uv/uvx before starting Blender MCP.')
    runtime = Path.home() / '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3'
    python = str(runtime) if runtime.is_file() else sys.executable
    mcp = json.loads((state / 'mcp.json').read_text())
    mcp['mcpServers']['blender']['command'] = uvx
    mcp['mcpServers']['blender']['args'] = ['--python', python, 'mcp-for-blender==2.2.6']
    (state / 'mcp.json').write_text(json.dumps(mcp, indent=2) + '\n')

    env = os.environ.copy()
    env['PI_CODING_AGENT_DIR'] = str(state)
    env['PI_CODING_AGENT_SESSION_DIR'] = str(sessions)
    executable = Path.home() / '.local/bin/pi'
    if not executable.is_file():
        raise RuntimeError('Pi is not installed. See integrations/dependencies.json for the pinned release.')
    command = [str(executable), '--provider', 'baseten-hackathon', '--model',
               'meta-models/muse-spark-open-1026', '--thinking', 'xhigh',
               '--append-system-prompt', str(GUIDE), '--session-dir', str(sessions)]
    return command, env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['check', 'blender', 'pi', 'pi-check'], nargs='?', default='check')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if args.mode == 'check':
        verify()
        return 0
    if args.mode == 'blender':
        if not ASSET.is_file():
            raise RuntimeError('The saved Blender project is missing.')
        command = ['/usr/bin/open', '-a', 'Blender', str(ASSET)]
        if args.dry_run:
            print(shlex.join(command))
            return 0
        return subprocess.call(command, cwd=ROOT)
    command, env = prepare_pi()
    if args.mode == 'pi-check':
        command = [command[0], '--offline', '--list-models', 'baseten-hackathon']
    if args.dry_run:
        print(shlex.join(command))
        print('Authentication uses an external helper or environment variable; no secret was copied.')
        return 0
    return subprocess.call(command, cwd=ROOT, env=env)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError) as error:
        print('Resume check: ' + str(error), file=sys.stderr)
        sys.exit(1)
