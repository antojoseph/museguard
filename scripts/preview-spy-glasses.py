#!/usr/bin/env python3
"""Preview and check Muse's real 3D spy-glasses activity in a private renderer.

Run: uv run --with pillow --with imageio-ffmpeg python scripts/preview-spy-glasses.py
Requires a built SentinelPet or MuseGuardStudio app. No running app bridge or
user setting is touched. The main clip keeps the complete don/wear/doff cycle;
checks.json records source cadence separately from the fixed 30 fps video.
"""
from pathlib import Path
import argparse
import json
import os
import shutil
import struct
import subprocess
import tempfile
import time
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SPY_FIELDS = ('spyWear', 'spyHandWeight', 'spyAttach', 'spyVisible', 'spyGripError',
              'spyDoffGrabAge', 'spyTempleDistance', 'protectionActive', 'spyCheckTouch')


def ffmpeg_path():
    explicit = os.environ.get('MUSE_FFMPEG')
    if explicit:
        return explicit
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        executable = shutil.which('ffmpeg')
        if executable:
            return executable
        raise RuntimeError('Install imageio-ffmpeg or set MUSE_FFMPEG to an ffmpeg executable.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, help='Built app MuseRenderer.json')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/spy-glasses-preview')
    args = parser.parse_args()
    candidates = [ROOT / 'build/Run' / app / 'Contents/Resources/MuseRenderer.json'
                  for app in ('SentinelPet.app', 'MuseGuardStudio.app')]
    config_path = args.config or next((path for path in candidates if path.exists()), None)
    if config_path is None:
        raise RuntimeError('Build the app first, or pass --config pointing to MuseRenderer.json.')
    config = json.loads(config_path.read_text())
    ffmpeg = ffmpeg_path()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    bridge = Path(tempfile.mkdtemp(prefix='muse-spy-glasses-preview-'))
    os.chmod(bridge, 0o700)
    current = dict(state='idle', working=False, reduceMotion=False, protectionActive=False)
    phase_start = time.time()
    phase_duration = 1.0

    def command():
        payload = dict(current, accessory='guard', gaze=0, heartbeat=time.time(),
                       phaseStart=phase_start, phaseDuration=phase_duration,
                       travelDirection=1, debugMotion=True)
        temporary = bridge / 'command.tmp'
        temporary.write_text(json.dumps(payload))
        temporary.replace(bridge / 'command.json')

    def frame():
        try:
            data = (bridge / 'frame.rgba').read_bytes()
        except FileNotFoundError:
            return None
        if len(data) < 24:
            return None
        magic, version, width, height, sequence, _ = struct.unpack_from('<6I', data)
        if (magic, version, width, height) != (0x4D555345, 1, 640, 640) or len(data) != 24 + width * height * 4:
            return None
        return sequence, Image.frombytes('RGBA', (width, height), data[24:])

    def motion():
        try:
            return json.loads((bridge / 'motion.json').read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    phases = [
        ('baseline', 'idle', False, False, 1.2),
        ('don-and-wear', 'idle', True, False, 5.0),
        ('doff', 'idle', False, False, 3.0),
        ('quick-on', 'idle', True, False, .25),
        ('quick-off', 'idle', False, False, 3.2),
        ('before-reverse', 'idle', True, False, 1.7),
        ('start-doff', 'idle', False, False, .45),
        ('resume-during-doff', 'idle', True, False, 1.5),
        ('warning-interrupt', 'stop', True, False, .7),
        ('before-sleep', 'idle', True, False, 2.0),
        ('sleep-interrupt', 'sleep', True, False, 1.0),
        ('wake', 'wake', False, False, 1.2),
        ('reduced-on', 'idle', True, True, 1.2),
        ('reduced-steady', 'idle', True, True, 1.0),
        ('reduced-off', 'idle', False, True, .7),
        ('onduty-ready', 'idle', False, False, 2.0, True),
        ('onduty-check', 'idle', True, False, 1.6, True),
        ('onduty-background', 'idle', False, False, 2.0, True),
        ('off-duty', 'idle', False, False, 3.0, False),
        ('manual-scanning', 'scanning', True, False, 2.0),
    ]
    targets = {
        'don-and-wear': [('don-mid', .42), ('don-seat', .69), ('don-release', .90), ('worn', 1.0)],
        'doff': [('doff-reach', .87), ('doff-detach', .65), ('doff-mid', .40)],
    }
    best = {}
    published = set()
    samples = []
    summaries = []
    checks = []
    failure = None
    writer = None
    encoded_frames = 0
    active_clip = 'muse-spy-glasses.mp4'
    clip_frames = {active_clip: 0}
    video_next = None
    last_sequence = -1
    command()
    log = (bridge / 'stdout.log').open('w')
    process = subprocess.Popen([
        config['executable'], config['project'], '/Game/Maps/MuseStage', '-game',
        '-RenderOffscreen', '-windowed', '-ResX=448', '-ResY=448', '-nosound',
        '-unattended', '-NoSplash', '-NoLoadingScreen', f'-MuseBridge={bridge}',
        f'-abslog={bridge}/unreal.log'], stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 90
        while frame() is None or motion() is None:
            if process.poll() is not None:
                raise RuntimeError('Private renderer exited before its first frame.')
            if time.monotonic() > deadline:
                raise RuntimeError('Private renderer startup timed out.')
            command()
            time.sleep(.15)
        if not all(field in motion() for field in SPY_FIELDS):
            raise RuntimeError('Rebuild the renderer: the spy-glasses debug fields are missing.')
        writer = subprocess.Popen([
            ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-f', 'rawvideo',
            '-pix_fmt', 'rgb24', '-s', '640x640', '-r', '30', '-i', '-', '-an',
            '-c:v', 'libx264', '-crf', '18', '-pix_fmt', 'yuv420p',
            '-movflags', '+faststart', str(out / 'muse-spy-glasses.mp4')],
            stdin=subprocess.PIPE, stderr=subprocess.PIPE)
        for index, phase in enumerate(phases):
            label, state, working, reduced, duration, *duty = phase
            protection = bool(duty and duty[0])
            current = dict(state=state, working=working, reduceMotion=reduced, protectionActive=protection)
            phase_start = time.time()
            phase_duration = duration
            started = time.monotonic()
            heartbeat = started
            command()
            times, sequences, matching = [], [], []
            last_image = None
            last_bounds = None
            if index == 0:
                video_next = started
            if label == 'onduty-ready':
                active_clip = 'muse-on-duty.mp4'
                clip_frames[active_clip] = 0
                writer = subprocess.Popen([
                    ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-f', 'rawvideo',
                    '-pix_fmt', 'rgb24', '-s', '640x640', '-r', '30', '-i', '-', '-an',
                    '-c:v', 'libx264', '-crf', '18', '-pix_fmt', 'yuv420p',
                    '-movflags', '+faststart', str(out / active_clip)],
                    stdin=subprocess.PIPE, stderr=subprocess.PIPE)
                video_next = started
            while time.monotonic() - started < duration:
                now = time.monotonic()
                if process.poll() is not None:
                    raise RuntimeError('Private renderer stopped during preview.')
                if now - heartbeat > .15:
                    command()
                    heartbeat = now
                found = frame()
                if found:
                    sequence, image = found
                    if sequence != last_sequence:
                        last_sequence = sequence
                        last_image = image
                        times.append(now)
                        sequences.append(sequence)
                        last_bounds = image.getchannel('A').point(lambda a: 255 if a > 24 else 0).getbbox()
                        data = motion()
                        # State can stay idle across a toggle. Confirm the command
                        # was consumed before attributing its debug sample.
                        if data and data.get('state') == state and data.get('workingRequested') == working and data.get('protectionActive') == protection:
                            data = dict(data, preview_phase=label, elapsed_s=round(now-started, 5), frame=sequence)
                            matching.append(data)
                            samples.append(data)
                            for name, wear in targets.get(label, []):
                                score = abs(data['spyWear'] - wear)
                                if name == 'worn':
                                    score += data.get('eyeClosure', 0) * .2
                                if name not in best or score < best[name][0]:
                                    best[name] = (score, image.copy(), data)
                                if score < .04 and name not in published:
                                    image.save(out / (name + '.png'))
                                    published.add(name)
                            if label == 'onduty-check' and data['spyCheckTouch'] > .95:
                                name = 'on-duty-adjust'
                                score = abs(data['elapsed_s'] - .70)
                                if name not in best or score < best[name][0]:
                                    best[name] = (score, image.copy(), data)
                                if score < .05 and name not in published:
                                    image.save(out / (name + '.png'))
                                    published.add(name)
                    if writer and now >= video_next:
                        background = Image.new('RGBA', image.size, (230, 240, 250, 255))
                        background.alpha_composite(image)
                        writer.stdin.write(background.convert('RGB').tobytes())
                        video_next += 1/30
                        clip_frames[active_clip] += 1
                        if active_clip == 'muse-spy-glasses.mp4':
                            encoded_frames += 1
                time.sleep(.003)
            if last_image:
                last_image.save(out / f'{label}.png')
            fps = ((sequences[-1]-sequences[0]) / max(.01, times[-1]-times[0])) if len(sequences) > 1 else 0
            summaries.append(dict(phase=label, source_fps=round(fps, 2), samples=len(matching),
                                  bounds=last_bounds, last={key: matching[-1][key] for key in SPY_FIELDS} if matching else None))
            if index == 2 or label == 'off-duty':
                writer.stdin.close()
                error = writer.stderr.read().decode()
                if writer.wait(timeout=15):
                    raise RuntimeError('Preview encoding failed: ' + error)
                writer = None
        by_phase = {label: [sample for sample in samples if sample['preview_phase'] == label]
                    for label, *_ in phases}

        def check(name, passed, detail=None):
            checks.append(dict(name=name, passed=bool(passed), detail=detail))

        check('all phases acknowledged', all(by_phase.values()))
        check('baseline hidden', all(not m['spyVisible'] and m['spyWear'] == 0 for m in by_phase['baseline']))
        on, off = by_phase['don-and-wear'], by_phase['doff']
        check('one complete don and wear', any(.1 < m['spyWear'] < .9 for m in on) and on[-1]['spyWear'] > .99 and on[-1]['spyVisible'])
        check('one complete doff', any(.1 < m['spyWear'] < .9 for m in off) and off[-1]['spyWear'] == 0 and not off[-1]['spyVisible'])
        quick = by_phase['quick-off']
        check('short job completes don then stows', max(m['spyWear'] for m in quick) > .99 and quick[-1]['spyWear'] == 0)
        before, resumed = by_phase['start-doff'], by_phase['resume-during-doff']
        check('resumes removal without reset', 0 < before[-1]['spyWear'] < 1 and abs(resumed[0]['spyWear']-before[-1]['spyWear']) < .2 and resumed[-1]['spyWear'] == 1)
        for label in ['warning-interrupt', 'sleep-interrupt', 'wake']:
            check(label + ' takes priority', all(m['spyWear'] == 0 and not m['spyVisible'] for m in by_phase[label]))
        steady = by_phase['reduced-steady']
        check('reduced motion static', all(m['spyWear'] == 1 and m['spyAttach'] == 1 and m['spyHandWeight'] == 0 and m['spyVisible'] for m in steady))
        check('reduced motion stows', by_phase['reduced-off'][-1]['spyWear'] == 0 and not by_phase['reduced-off'][-1]['spyVisible'])
        duty = by_phase['onduty-ready']
        check('on-duty without inference wears glasses', duty[-1]['spyWear'] > .99 and duty[-1]['spyVisible'])
        touch = max(m['spyCheckTouch'] for m in by_phase['onduty-check'])
        check('new on-duty check adjusts temple', touch > .8, dict(max_touch=touch))
        check('between on-duty checks stays worn', all(m['spyWear'] > .99 and m['spyVisible'] for m in by_phase['onduty-background']))
        check('leaving duty stows glasses', by_phase['off-duty'][-1]['spyWear'] == 0 and not by_phase['off-duty'][-1]['spyVisible'])
        scanning = by_phase['manual-scanning']
        check('manual screen analysis wears glasses', scanning[-1]['spyWear'] > .99 and scanning[-1]['spyVisible'])
        attached = [m for m in on+off if m['spyHandWeight'] > .95 and .05 < m['spyAttach'] < .98]
        error = max((m['spyGripError'] for m in attached), default=0)
        check('near-attachment grip below 1.5cm', bool(attached) and error < 1.5, dict(max_error_cm=error, samples=len(attached)))
        check('silhouette stays inside frame', all(row['bounds'] and row['bounds'][0] > 2 and row['bounds'][1] > 2 and row['bounds'][2] < 638 and row['bounds'][3] < 638 for row in summaries))
    except Exception as error:
        failure = str(error)
    finally:
        if writer:
            writer.stdin.close()
            try:
                writer.wait(timeout=15)
            except subprocess.TimeoutExpired:
                writer.kill()
                writer.wait()
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        log.close()
        for name, (_, image, _) in best.items():
            image.save(out / (name + '.png'))
        (out / 'motion.json').write_text(json.dumps(samples, indent=2) + '\n')
        report = dict(bridge=str(bridge), video_fps=30, video_frames=encoded_frames,
                      video_duration_s=encoded_frames/30, phases=summaries, checks=checks,
                      clips={name: dict(frames=count, duration_s=count/30) for name, count in clip_frames.items()},
                      failure=failure, snapshots={name: data for name, (_, _, data) in best.items()})
        (out / 'checks.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(output=str(out), checks=checks, failure=failure), indent=2))
    return 1 if failure or any(not item['passed'] for item in checks) else 0


if __name__ == '__main__':
    raise SystemExit(main())
