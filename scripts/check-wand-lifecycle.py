#!/usr/bin/env python3
"""Exercise wand visibility against the live renderer, including interruptions.

Run after building the renderer: python3 scripts/check-wand-lifecycle.py
Only this test's renderer process and temporary bridge are used.
"""
from pathlib import Path
import json
import os
import struct
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/wand-lifecycle-check'
OUT.mkdir(parents=True, exist_ok=True)
CONFIG = json.loads((ROOT / 'build/Run/MuseGuardStudio.app/Contents/Resources/MuseRenderer.json').read_text())
BRIDGE = Path(tempfile.mkdtemp(prefix='muse-wand-check-'))
os.chmod(BRIDGE, 0o700)
DESKTOP = dict(enabled=True, width=1728, height=1080, fromX=134, fromY=134,
               toX=864, toY=540, fromScale=1, toScale=1, homeSize=220)
current = None
phase_start = 0.0
last_sequence = -1
samples = []
checks = []


def command(state, reduced=False, desktop=False, duration=1.0):
    global current, phase_start
    identity = (state, reduced, desktop)
    if identity != current:
        current = identity
        phase_start = time.time()
    payload = dict(state=state, accessory='guard', gaze=0, heartbeat=time.time(),
                   reduceMotion=reduced, debugMotion=True, phaseStart=phase_start,
                   phaseDuration=duration, travelDirection=1,
                   desktopScene=DESKTOP if desktop else dict(enabled=False))
    temporary = BRIDGE / 'command.tmp'
    temporary.write_text(json.dumps(payload))
    temporary.replace(BRIDGE / 'command.json')


def observation():
    try:
        data = (BRIDGE / 'frame.rgba').read_bytes()
        motion = json.loads((BRIDGE / 'motion.json').read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    if len(data) < 24:
        return None
    magic, version, width, height, sequence, flags = struct.unpack_from('<6I', data)
    assert magic == 0x4D555345 and version in (1, 2)
    assert 0 < width <= 2048 and 0 < height <= 2048
    assert len(data) == (40 if version == 2 else 24) + width * height * 4
    return sequence, bool(flags & 1), motion


def collect(label, state, seconds, *, reduced=False, desktop=False):
    global last_sequence
    begin = time.monotonic()
    command(state, reduced, desktop, seconds)
    heartbeat = begin
    captured = []
    while time.monotonic() - begin < seconds:
        assert process.poll() is None, 'Renderer exited during ' + label
        now = time.monotonic()
        if now - heartbeat >= .2:
            command(state, reduced, desktop, seconds)
            heartbeat = now
        value = observation()
        if value is None or value[0] == last_sequence:
            time.sleep(.004)
            continue
        sequence, is_desktop, motion = value
        last_sequence = sequence
        # Metadata and image are each atomically published. Ignore the frame
        # crossing a command boundary until both describe the requested scene.
        if motion['state'] != state or is_desktop != desktop:
            continue
        sample = dict(motion, label=label, frame=sequence,
                      reducedMotion=reduced, elapsed=now - begin)
        captured.append(sample)
        samples.append(sample)
    assert captured, 'No matching renderer frames for ' + label
    checks.append(dict(label=label, frames=len(captured),
                       maximumWand=round(max(m['wandAmount'] for m in captured), 4)))
    return captured


def stowed(captured):
    for motion in captured:
        assert motion['wandAmount'] == 0, (motion['label'], 'unexpected wand', motion)
        assert motion['magicCast'] == 0 and motion['magicDismiss'] == 0, (
            motion['label'], 'stale magic', motion)


command('idle')
log = (BRIDGE / 'stdout.log').open('w')
process = subprocess.Popen(
    [CONFIG['executable'], CONFIG['project'], '/Game/Maps/MuseStage', '-game',
     '-RenderOffscreen', '-windowed', '-ResX=448', '-ResY=448', '-nosound',
     '-unattended', '-NoSplash', '-NoLoadingScreen', f'-MuseBridge={BRIDGE}',
     f'-abslog={BRIDGE}/unreal.log'], stdout=log, stderr=log)
try:
    deadline = time.monotonic() + 60
    while observation() is None:
        assert process.poll() is None, 'Renderer exited during startup'
        assert time.monotonic() < deadline, 'Renderer startup timed out'
        command('idle')
        time.sleep(.1)

    ordinary = ('idle', 'scanning', 'stretch', 'walk', 'climb', 'yawn', 'drowsy',
                'notice', 'jump', 'return', 'land', 'stop', 'explain', 'wake')
    for reduced in (False, True):
        for state in ordinary:
            stowed(collect(f'ordinary:{reduced}:{state}', state, .22, reduced=reduced))
        for state in ('prepare', 'walk', 'climb', 'notice', 'jump', 'return', 'land', 'stop'):
            stowed(collect(f'desktop:{reduced}:{state}', state, .22,
                            reduced=reduced, desktop=True))
    stowed(collect('reset-home', 'idle', .25))

    # A complete normal nap must summon the wand before casting and keep it
    # full size through each actual flick, then stow it before sleeping.
    nap = collect('full-nap', 'sleep', 8.7)
    cast = [m for m in nap if m['magicCast'] > .02]
    assert len(cast) > 10 and all(m['wandAmount'] > .999 for m in cast)
    assert all(m['wandPurpose'] == 'conjure' for m in cast)
    assert any(0 < m['wandAmount'] < .99 and m['magicCast'] == 0 for m in nap)
    resting = [m for m in nap if m['sleepAmount'] > .99]
    assert resting and all(m['wandAmount'] == 0 for m in resting)

    wake = collect('full-wake', 'wake', 1.2)
    dismiss = [m for m in wake if m['magicDismiss'] > .02]
    assert len(dismiss) > 5 and all(m['wandAmount'] > .999 for m in dismiss)
    assert all(m['wandPurpose'] == 'dismiss' for m in dismiss)
    assert all(m['sleepLie'] < .15 for m in wake if m['wandAmount'] > .01)
    stowed(collect('after-wake', 'idle', .35))

    # Cancelling while the wand has appeared but no bed exists cannot trigger
    # a second, unrelated dismissal spell.
    early = collect('cancel-before-bed:prepare', 'sleep', 3.3)
    assert any(m['wandAmount'] > .99 and m['bedScale'] == 0 for m in early)
    stowed(collect('cancel-before-bed:wake', 'wake', 1.2))
    stowed(collect('cancel-before-bed:idle', 'idle', .25))

    # Resume the same bed during waking: no new conjure and no stale dismiss.
    collect('reentry:bed', 'settle', 5.2)
    collect('reentry:waking', 'wake', .5)
    resumed = collect('reentry:resume', 'sleep', .6)
    stowed(resumed)
    assert all(m['conjureAge'] >= 1.95 for m in resumed)
    stowed(collect('reentry:jump', 'jump', 1.0))

    # Ordinary pose changes and desktop travel cancel magic even when the bed
    # has already started appearing and the previous wand was visible.
    for target in ('stop', 'climb'):
        collect(f'interrupt:{target}:bed', 'settle', 1.2)
        stowed(collect(f'interrupt:{target}:action', target, 1.0))
    collect('interrupt:desktop:bed', 'settle', 1.2)
    stowed(collect('interrupt:desktop:jump', 'jump', .8, desktop=True))
    stowed(collect('interrupt:desktop:home', 'idle', .25))

    # Reduced-motion bed transitions never produce a wand, including after a
    # normal conjure episode earlier in this same renderer session.
    stowed(collect('reduced:sleep', 'sleep', .4, reduced=True))
    resumed_motion = collect('reduced:resume-motion', 'sleep', .6)
    stowed(resumed_motion)
    assert all(m['sleepAmount'] > .99 and m['conjureAge'] >= 1.95 for m in resumed_motion)
    stowed(collect('reduced:wake', 'wake', .4, reduced=True))
    stowed(collect('reduced:idle', 'idle', .3, reduced=True))
    (OUT / 'checks.json').write_text(json.dumps(dict(bridge=str(BRIDGE), checks=checks), indent=2) + '\n')
    print(f'PASS: wand summon/hold/stow, {len(checks)} scenarios, {len(samples)} live frames')
    print(OUT / 'checks.json')
finally:
    (OUT / 'motion.json').write_text(json.dumps(samples, indent=2) + '\n')
    process.terminate()
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    log.close()
