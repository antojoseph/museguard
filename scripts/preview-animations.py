#!/usr/bin/env python3
"""Check real Unreal frames and record a continuous, constant-cadence MP4.
Run: uv run --with pillow --with imageio-ffmpeg python scripts/preview-animations.py
No transition frames are removed. Poll faster than the renderer so every new
frame is encoded once; checks.json reports source cadence and sequence gaps.
"""
from pathlib import Path
import json, os, struct, subprocess, tempfile, time
from PIL import Image
import imageio_ffmpeg
root=Path(__file__).resolve().parents[1]
config=json.loads((root/'build/Run/MuseGuardStudio.app/Contents/Resources/MuseRenderer.json').read_text())
out=root/'build/animation-preview';out.mkdir(parents=True,exist_ok=True)
bridge=Path(tempfile.mkdtemp(prefix='muse-animation-check-'));os.chmod(bridge,0o700)
phase_state=None
phase_start=0.
phase_duration=1.
travel_direction=1.
def command(state,accessory,reduce_motion=False,duration=None,direction=None):
    global phase_state,phase_start,phase_duration,travel_direction
    if state != phase_state:
        phase_state=state;phase_start=time.time()
        phase_duration={'notice':.48,'jump':1.05,'return':1.05,'land':.38}.get(state,1.)
    if duration is not None: phase_duration=duration
    if direction is not None: travel_direction=direction
    p=bridge/'command.tmp'
    p.write_text(json.dumps(dict(state=state,accessory=accessory,gaze=0,heartbeat=time.time(),reduceMotion=reduce_motion,phaseStart=phase_start,phaseDuration=phase_duration,travelDirection=travel_direction,debugMotion=True)))
    p.replace(bridge/'command.json')
def frame():
    try: b=(bridge/'frame.rgba').read_bytes()
    except FileNotFoundError: return None
    if len(b)!=24+640*640*4: return None
    magic,version,w,h,seq,_=struct.unpack_from('<6I',b)
    assert (magic,version,w,h)==(0x4D555345,1,640,640)
    return seq,Image.frombytes('RGBA',(w,h),b[24:])
command('idle','guard')
log=(bridge/'stdout.log').open('w')
proc=subprocess.Popen([config['executable'],config['project'],'/Game/Maps/MuseStage','-game','-RenderOffscreen','-windowed','-ResX=448','-ResY=448','-nosound','-unattended','-NoSplash','-NoLoadingScreen',f'-MuseBridge={bridge}',f'-abslog={bridge}/unreal.log'],stdout=log,stderr=log)
evidence=[];writer=None;video_frames=0
try:
    deadline=time.monotonic()+60
    while frame() is None:
        assert proc.poll() is None,'Renderer exited before its first frame'
        assert time.monotonic()<deadline,'Renderer startup timed out'
        command('idle','guard');time.sleep(.1)
    # Allow shaders and renderer startup work to settle before judging cadence.
    for _ in range(20): command('idle','guard');time.sleep(.1)
    writer=imageio_ffmpeg.write_frames(str(out/'muse-3d-jump.mp4'),(640,640),fps=30,codec='libx264',quality=9,output_params=['-movflags','+faststart'])
    writer.send(None)
    timeline=[('idle','guard',1.5,1),('notice','guard',.48,1),('jump','guard',1.05,1),('land','guard',.38,1),('stop','guard',1.8,1),('explain','guard',1.8,1),('notice','guard',.48,-1),('return','guard',1.05,-1),('land','guard',.38,-1),('idle','guard',1.5,-1),('scanning','focus',1.5,1),('idle','none',1.5,1)]
    motion_samples=[];milestones={}
    last_seen=-1
    for index,(state,accessory,duration,direction) in enumerate(timeline):
        start=time.monotonic();last_heartbeat=start;seqs=[];times=[]
        command(state,accessory,duration=duration,direction=direction)
        while time.monotonic()-start<duration:
            now=time.monotonic()
            if now-last_heartbeat>.2: command(state,accessory);last_heartbeat=now
            f=frame()
            assert f is not None, 'Published frame disappeared during atomic replacement'
            seq,im=f
            if seq==last_seen: time.sleep(1/240);continue
            last_seen=seq;seqs.append(seq);times.append(time.monotonic())
            bounds=im.getchannel('A').point(lambda a:255 if a>24 else 0).getbbox()
            assert bounds and bounds[0]>3 and bounds[1]>3 and bounds[2]<637 and bounds[3]<637,(state,bounds)
            if (bridge/'motion.json').exists():
                motion=json.loads((bridge/'motion.json').read_text())
                motion_samples.append(dict(motion,frame=seq))
                targets={'notice':('crouch',.60),'jump':('apex',.50),'land':('landing',.50),'return':('return-apex',.50)}
                if motion['state'] in targets:
                    name,phase=targets[motion['state']]
                    difference=abs(motion['phase']-phase)
                    if name not in milestones or difference<milestones[name][0]:
                        milestones[name]=(difference,im.copy())
                if motion['state']=='jump' and abs(motion['phase']-.86)<.04: im.save(out/'jump-descent.png')
            if index<10:
                bg=Image.new('RGBA',im.size,(230,240,250,255));bg.alpha_composite(im)
                writer.send(bg.convert('RGB').tobytes());video_frames+=1
        im.save(out/f'{state}-{accessory}.png')
        fps=(seqs[-1]-seqs[0])/max(.01,times[-1]-times[0])
        evidence.append(dict(state=state,accessory=accessory,render_fps=round(fps,1),sampled_frames=len(seqs),distinct_frames=len(set(seqs)),skipped_source_frames=sum(max(0,b-a-1) for a,b in zip(seqs,seqs[1:])),bounds=bounds))
        if duration>1: assert fps>=24, f'Renderer cadence too low in {state}: {fps:.1f} fps'
    writer.close();writer=None
    for name,(_,im) in milestones.items(): im.save(out/f'jump-{name}.png')
    air=[m for m in motion_samples if m['state']=='jump']
    assert max(m['height'] for m in air)>24 and max(m['depth'] for m in air)>19
    assert max(abs(m['yaw']) for m in air)>30
    assert max(m['leftKneeBend'] for m in air)>100
    assert all(m['projection']=='perspective' for m in air)
    planted=[m for m in motion_samples if (m['state']=='notice' and .2<m['phase']<.7) or (m['state']=='land' and .2<m['phase']<.8)]
    assert len(planted)>5
    assert max(abs(m[k]-3) for m in planted for k in ['leftAnkleHeight','rightAnkleHeight'])<.15
    (out/'jump-motion.json').write_text(json.dumps(motion_samples,indent=2)+'\n')
    # Exercise reduced-motion rendering too without changing the user's setting.
    command('stop','guard',True);time.sleep(.5)
    frame()[1].save(out/'reduced-motion.png')
    (out/'checks.json').write_text(json.dumps(dict(mesh='Jolly',bridge=str(bridge),poses=evidence,video_frames=video_frames,video_fps=30),indent=2)+'\n')
    print(json.dumps(evidence,indent=2));print(out/'muse-3d-jump.mp4')
finally:
    if writer is not None: writer.close()
    proc.terminate()
    try: proc.wait(timeout=8)
    except subprocess.TimeoutExpired: proc.kill();proc.wait()
    log.close()
