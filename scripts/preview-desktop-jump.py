#!/usr/bin/env python3
"""Render the fixed-camera desktop leap, with a synthetic page for scale.
uv run --with pillow --with imageio-ffmpeg python scripts/preview-desktop-jump.py
"""
from pathlib import Path
import json, os, struct, subprocess, tempfile, time
from PIL import Image, ImageDraw
import imageio_ffmpeg
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/desktop-jump-preview'; OUT.mkdir(parents=True, exist_ok=True)
config = json.loads((ROOT/'build/Run/SentinelPet.app/Contents/Resources/MuseRenderer.json').read_text())
bridge = Path(tempfile.mkdtemp(prefix='muse-desktop-check-')); os.chmod(bridge, 0o700)
scene = dict(enabled=True, width=1728, height=1080, fromX=134, fromY=134, toX=864, toY=540, fromScale=1, toScale=1, homeSize=220)
state, phase_start, duration = 'prepare', time.time(), 1
reduced = False

def command():
    data = dict(state=state, phaseStart=phase_start, phaseDuration=duration, desktopScene=scene,
                travelDirection=1 if scene['toX']>scene['fromX'] else -1, accessory='guard', gaze=0,
                reduceMotion=reduced, debugMotion=True, heartbeat=time.time())
    p=bridge/'command.tmp'; p.write_text(json.dumps(data)); p.replace(bridge/'command.json')

def frame():
    try: data=(bridge/'frame.rgba').read_bytes()
    except FileNotFoundError: return None
    if len(data)<24: return None
    magic,version,w,h,seq,flags=struct.unpack_from('<6I',data)
    assert magic==0x4D555345 and version==2 and w<=2048 and h<=2048
    assert len(data)==40+w*h*4
    if not flags&1: return None
    x,y,cw,ch=struct.unpack_from('<4f',data,24)
    assert w/cw==2 and h/ch==2, 'Desktop avatar lost Retina pixel density'
    tile=Image.frombytes('RGBA',(w,h),data[40:])
    bounds=tile.getchannel('A').point(lambda a:255 if a>24 else 0).getbbox()
    assert bounds and min(bounds[:2])>2 and bounds[2]<w-2 and bounds[3]<h-2, ('crop clipped',bounds)
    if state=='stop': tile.save(OUT/'stop-retina-detail.png')
    scale=1280/scene['width']
    desktop=Image.new('RGBA',(1280,800))
    tile=tile.resize((round(cw*scale),round(ch*scale)),Image.Resampling.LANCZOS)
    desktop.alpha_composite(tile,(round(x*scale),round((scene['height']-y-ch)*scale)))
    return seq,desktop

command()
log=(bridge/'stdout.log').open('w')
proc=subprocess.Popen([config['executable'],config['project'],'/Game/Maps/MuseStage','-game','-RenderOffscreen','-windowed','-ResX=448','-ResY=448','-nosound','-unattended','-NoSplash',f'-MuseBridge={bridge}',f'-abslog={bridge}/unreal.log'],stdout=log,stderr=log)
writer=None
samples=[]; checks=[]; milestones={}; seen=-1
try:
    deadline=time.monotonic()+60
    while frame() is None:
        assert proc.poll() is None, 'Renderer exited'
        assert time.monotonic()<deadline, 'Startup timed out'
        command(); time.sleep(.1)
    for _ in range(15): command(); time.sleep(.1)
    size=frame()[1].size
    bg=Image.new('RGBA',size,(225,234,244,255)); d=ImageDraw.Draw(bg)
    d.rounded_rectangle((210,65,1190,700),radius=14,fill=(255,255,255),outline=(193,205,219),width=2)
    d.rounded_rectangle((240,88,1155,124),radius=8,fill=(242,245,249))
    d.text((260,99),'microsoft-account-verify.example.test/login',fill=(69,83,103),font_size=17)
    d.text((380,210),'Microsoft 365 Security',fill=(33,47,70),font_size=34)
    d.text((380,270),'Verify your account to prevent deletion',fill=(89,101,119),font_size=21)
    for y,label in [(330,'Email'),(405,'Password'),(480,'Authenticator code')]:
        d.rounded_rectangle((380,y,970,y+52),radius=7,fill=(245,248,251),outline=(202,213,226))
        d.text((398,y+17),label,fill=(106,119,139),font_size=18)
    d.rounded_rectangle((380,565,970,618),radius=7,fill=(29,99,211))
    d.text((620,582),'Verify now',fill='white',font_size=20)
    d.text((24,20),'MUSE GUARD  /  Synthetic desktop preview',fill=(50,65,88),font_size=16)
    writer=imageio_ffmpeg.write_frames(str(OUT/'muse-desktop-leap.mp4'),size,fps=30,codec='libx264',quality=9,macro_block_size=2,output_params=['-movflags','+faststart']);writer.send(None)
    timeline=[('prepare',.8),('notice',.36),('jump',.86),('land',.32),('stop',2.),('reverse',0),('notice',.36),('return',.86),('land',.32),('idle',1.)]
    for phase,seconds in timeline:
        if phase=='reverse':
            scene=dict(scene,fromX=864,fromY=540,toX=134,toY=134,fromScale=1,toScale=1)
            continue
        state=phase;duration=seconds;phase_start=time.time();command()
        begin=time.monotonic(); next_heartbeat=begin; seqs=[]; times=[]; last_composite=None; encoded=0
        while time.monotonic()-begin<seconds:
            now=time.monotonic()
            if now>=next_heartbeat: command(); next_heartbeat=now+.2
            f=frame()
            if not f or f[0]==seen: time.sleep(1/240);continue
            seq,im=f;seen=seq;seqs.append(seq);times.append(now)
            bounds=im.getchannel('A').point(lambda a:255 if a>35 else 0).getbbox()
            assert bounds and bounds[0]>1 and bounds[1]>1 and bounds[2]<size[0]-1 and bounds[3]<size[1]-1,(phase,bounds)
            m=json.loads((bridge/'motion.json').read_text());samples.append(dict(m,frame=seq,bounds=bounds))
            composite=bg.copy();composite.alpha_composite(im)
            if phase=='stop':
                draw=ImageDraw.Draw(composite)
                draw.rounded_rectangle((810,245,1230,355),radius=18,fill=(255,248,233),outline=(204,143,44),width=2)
                draw.text((830,266),'Wait! This sign-in looks suspicious.',fill=(77,49,15),font_size=18)
                draw.text((830,302),'Do not enter your password or code.',fill=(77,49,15),font_size=17)
            last_composite=composite.convert('RGB')
            # Encode elapsed wall time, keeping repeated frames when rendering
            # falls behind rather than speeding up the performance in the video.
            target_frames=int((now-begin)*30)+1
            while encoded<target_frames: writer.send(last_composite.tobytes());encoded+=1
            if m['state']==phase:
                key=phase if phase in ('prepare','stop','idle') else f'{phase}-{scene["fromScale"]}'
                target=.5 if phase in ('notice','land') else .60
                score=abs(m['phase']-target)
                if key not in milestones or score<milestones[key][0]: milestones[key]=(score,composite.copy())
        while encoded<round(seconds*30) and last_composite is not None: writer.send(last_composite.tobytes());encoded+=1
        fps=(seqs[-1]-seqs[0])/max(.01,times[-1]-times[0]) if len(seqs)>1 else 0
        checks.append(dict(state=phase,fromScale=scene['fromScale'],fps=round(fps,1),frames=len(seqs),skipped=sum(max(0,b-a-1) for a,b in zip(seqs,seqs[1:]))))
    writer.close();writer=None
    for key,(_,im) in milestones.items(): im.save(OUT/f'{key}.png')
    (OUT/'motion.json').write_text(json.dumps(samples,indent=2))
    (OUT/'checks.json').write_text(json.dumps(dict(bridge=str(bridge),phases=checks),indent=2))
    air=[s for s in samples if s['state']=='jump'];back=[s for s in samples if s['state']=='return']
    assert max(m['worldArc'] for m in air)>95
    assert all(abs(m['perspectiveScale']-1)<.001 for m in samples), 'Unexpected enlargement'
    assert max(m['worldY'] for m in air)-min(m['worldY'] for m in air)>500
    assert max(m['leftKneeBend'] for m in air)>100
    assert any(m['blockPose']>.6 and m['phase']>.8 for m in air)
    stop=[m for m in samples if m['state']=='stop' and m['phase']>.2]
    assert max(abs(m['projectedX']-864)+abs(m['projectedY']-540) for m in stop)<1
    home=[m for m in samples if m['state']=='idle']
    assert max(abs(m['projectedX']-134)+abs(m['projectedY']-134) for m in home)<1
    assert back and min(m['perspectiveScale'] for m in back)<1.1
    assert all(m['fps']>=25 for m in checks if m['state'] in ('jump','return','stop'))
    print(json.dumps(checks,indent=2));print(OUT/'muse-desktop-leap.mp4')
finally:
    if writer: writer.close()
    proc.terminate()
    try: proc.wait(timeout=8)
    except subprocess.TimeoutExpired: proc.kill();proc.wait()
    log.close()
