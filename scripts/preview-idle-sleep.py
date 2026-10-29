#!/usr/bin/env python3
"""Check the real 3D idle, side-angle prone sleep and wake interruption.
Run: uv run --with pillow --with imageio-ffmpeg python scripts/preview-idle-sleep.py
No transition frames are removed. Poll faster than the renderer so every new
frame is encoded once; checks.json reports source cadence and sequence gaps.
"""
from pathlib import Path
import json, os, struct, subprocess, tempfile, time
from PIL import Image
import imageio_ffmpeg
root=Path(__file__).resolve().parents[1]
config=json.loads((root/'build/Run/MuseGuardStudio.app/Contents/Resources/MuseRenderer.json').read_text())
out=root/'build/idle-sleep-preview';out.mkdir(parents=True,exist_ok=True)
bridge=Path(tempfile.mkdtemp(prefix='muse-idle-check-'));os.chmod(bridge,0o700)
phase_state=None
phase_start=0.
phase_duration=1.
travel_direction=1.
inspection_yaw=0.
def command(state,accessory,reduce_motion=False,duration=None,direction=None):
    global phase_state,phase_start,phase_duration,travel_direction
    if state != phase_state:
        phase_state=state;phase_start=time.time()
        phase_duration={'notice':.48,'jump':1.05,'return':1.05,'land':.38}.get(state,1.)
    if duration is not None: phase_duration=duration
    if direction is not None: travel_direction=direction
    p=bridge/'command.tmp'
    p.write_text(json.dumps(dict(state=state,accessory=accessory,gaze=0,heartbeat=time.time(),reduceMotion=reduce_motion,phaseStart=phase_start,phaseDuration=phase_duration,travelDirection=travel_direction,debugMotion=True,inspectionYaw=inspection_yaw)))
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
    writer=imageio_ffmpeg.write_frames(str(out/'muse-sleep.mp4'),(640,640),fps=30,codec='libx264',quality=9,output_params=['-movflags','+faststart'])
    writer.send(None)
    timeline=[('idle','guard',2.,1),('stretch','guard',3.,1),('drowsy','guard',2.,1),('sleep','guard',12.,1),('wake','guard',1.3,1),('notice','guard',.36,1),('jump','guard',.86,1),('land','guard',.32,1),('stop','guard',1.5,1),('idle','guard',1.,1),('sleep','guard',1.4,1),('wake','guard',1.1,1),('idle','guard',1.,1)]
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
                targets={'notice':('crouch',.60),'jump':('apex',.50),'land':('landing',.50),'sleep':('face-down',.85),'stretch':('stretch',.5)}
                if motion['state'] in targets:
                    name,phase=targets[motion['state']]
                    difference=abs(motion['phase']-phase)
                    if name not in milestones or difference<milestones[name][0]:
                        milestones[name]=(difference,im.copy())
                if motion.get('magicCast',0)>.7 and .25<motion.get('bedScale',0)<.85: im.save(out/'bed-conjure.png')
                if motion.get('magicDismiss',0)>.7 and .15<motion.get('bedScale',0)<.85: im.save(out/'bed-dismiss.png')
                if motion.get('yawn',0)>.95: im.save(out/'yawn.png')
                if motion['state']=='jump' and abs(motion['phase']-.86)<.04: im.save(out/'jump-descent.png')
            if True:
                bg=Image.new('RGBA',im.size,(230,240,250,255));bg.alpha_composite(im)
                writer.send(bg.convert('RGB').tobytes());video_frames+=1
        if state!='sleep' or duration>3: im.save(out/f'{state}-{accessory}.png')
        fps=(seqs[-1]-seqs[0])/max(.01,times[-1]-times[0])
        evidence.append(dict(state=state,accessory=accessory,render_fps=round(fps,1),sampled_frames=len(seqs),distinct_frames=len(set(seqs)),skipped_source_frames=sum(max(0,b-a-1) for a,b in zip(seqs,seqs[1:])),bounds=bounds))
        if duration>1: assert fps>=24, f'Renderer cadence too low in {state}: {fps:.1f} fps'
    writer.close();writer=None
    for name,(_,im) in milestones.items(): im.save(out/f'jump-{name}.png')
    (out/'sleep-motion.json').write_text(json.dumps(motion_samples,indent=2)+'\n')
    sleeping=[m for m in motion_samples if m['state']=='sleep' and m['sleepAmount']>.99]
    assert len(sleeping)>40
    assert any(m['magicCast']>.5 and m['bedScale']==0 and m['wandAmount']>.5 for m in motion_samples)
    assert any(m['magicCast']>.7 and .2<m['bedScale']<.9 for m in motion_samples)
    assert any(m['magicDismiss']>.7 and .1<m['bedScale']<.9 for m in motion_samples)
    assert all(m['wandAmount']==0 for m in sleeping)
    assert all(m['wandAmount']==0 for m in motion_samples if m['state']=='jump')
    # The prone belly rests on the mattress, with only soft compression and
    # sub-centimeter breathing movement rather than a visible hovering gap.
    assert all(-2 < m['bellyMattressClearance'] < 1 for m in sleeping)
    assert all(60 < m['restingBodyTop'] < 90 for m in sleeping), 'Upright body depth became a tall hump'
    assert all(26 < m['restingFootLow'] < 29 for m in sleeping), 'Tucked feet lost mattress contact'
    assert any(m.get('yawn',0)>.95 and m['sleepAmount']==0 for m in motion_samples)
    assert all(m.get('furTufts',0)==32000 for m in motion_samples)
    assert all(abs(m['bodyPitch']+90)<.01 and m['eyeClosure']>.99 for m in sleeping)
    assert all(abs(m['cameraYaw']-180)>30 for m in sleeping)
    assert max(m['breath'] for m in sleeping)-min(m['breath'] for m in sleeping)>1.5
    assert any(m['state']=='wake' and m['sleepAmount']<.001 for m in motion_samples)
    assert all(m['sleepAmount']<.001 for m in motion_samples if m['state']=='jump')
    (out/'sleep-motion.json').write_text(json.dumps(motion_samples,indent=2)+'\n')
    # Exercise reduced-motion rendering too without changing the user's setting.
    command('sleep','guard',True);time.sleep(3.5)
    frame()[1].save(out/'reduced-motion.png')
    # Inspect the same skin from the sides and back, including accessory fit.
    for label,angle in [('front',0),('left',-90),('back',180),('rear-quarter',135),('right',90)]:
        inspection_yaw=angle
        for _ in range(12): command('idle','none',True);time.sleep(.1)
        frame()[1].save(out/f'surface-{label}.png')
    (out/'checks.json').write_text(json.dumps(dict(mesh='Jolly',bridge=str(bridge),poses=evidence,video_frames=video_frames,video_fps=30),indent=2)+'\n')
    print(json.dumps(evidence,indent=2));print(out/'muse-sleep.mp4')
finally:
    if writer is not None: writer.close()
    proc.terminate()
    try: proc.wait(timeout=8)
    except subprocess.TimeoutExpired: proc.kill();proc.wait()
    log.close()
