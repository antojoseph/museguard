#!/usr/bin/env python3
"""Render walk/climb journeys and inspect side/rear joints through a full gait.
uv run --with pillow --with imageio-ffmpeg --with numpy --with scipy python scripts/preview-locomotion.py
"""
from pathlib import Path
import json, os, struct, subprocess, tempfile, time
from PIL import Image, ImageDraw
import imageio_ffmpeg
import numpy as np
from scipy.ndimage import binary_fill_holes, label
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/locomotion-preview';OUT.mkdir(parents=True,exist_ok=True)
config=json.loads((ROOT/'build/Run/SentinelPet.app/Contents/Resources/MuseRenderer.json').read_text())
bridge=Path(tempfile.mkdtemp(prefix='muse-locomotion-'));os.chmod(bridge,0o700)
state='idle';phase_start=time.time();duration=1;inspection=0;direction=1;scene=None

def command():
    c=dict(state=state,phaseStart=phase_start,phaseDuration=duration,accessory='guard',gaze=0,travelDirection=direction,debugMotion=True,inspectionYaw=inspection,heartbeat=time.time())
    if scene:c['desktopScene']=scene
    p=bridge/'command.tmp';p.write_text(json.dumps(c));p.replace(bridge/'command.json')

def frame():
    try:b=(bridge/'frame.rgba').read_bytes()
    except FileNotFoundError:return None
    if len(b)<24:return None
    magic,version,w,h,seq,flags=struct.unpack_from('<6I',b)
    assert magic==0x4D555345
    off=40 if version==2 else 24
    if len(b)!=off+w*h*4:return None
    rect=struct.unpack_from('<4f',b,24) if version==2 else None
    return seq,Image.frombytes('RGBA',(w,h),b[off:]),rect

command();log=(bridge/'stdout.log').open('w')
proc=subprocess.Popen([config['executable'],config['project'],'/Game/Maps/MuseStage','-game','-RenderOffscreen','-windowed','-ResX=448','-ResY=448','-nosound','-unattended','-NoSplash',f'-MuseBridge={bridge}',f'-abslog={bridge}/unreal.log'],stdout=log,stderr=log)
writer=None;samples=[];checks=[];seen=-1
try:
    deadline=time.monotonic()+60
    while not frame():
        assert proc.poll() is None and time.monotonic()<deadline
        command();time.sleep(.1)
    writer=imageio_ffmpeg.write_frames(str(OUT/'walk-and-climb.mp4'),(1280,800),fps=30,codec='libx264',quality=8,macro_block_size=2);writer.send(None)
    timeline=[('walk',4,0,1,(180,140,620,140)),('climb',8,0,1,(180,140,180,740)),('walk',2,0,1,None),('walk',2,90,1,None),('walk',2,150,1,None),('walk',2,180,1,None),('walk',2,0,-1,None)]
    for index,(state,duration,inspection,direction,path) in enumerate(timeline):
        scene=dict(enabled=True,width=1280,height=800,fromX=path[0],fromY=path[1],toX=path[2],toY=path[3],fromScale=1,toScale=1,homeSize=220) if path else None
        phase_start=time.time();command();start=time.monotonic();last_hb=start;seqs=[];times=[];encoded=0;latest=None;max_hole=0
        while time.monotonic()-start<duration:
            now=time.monotonic()
            if now-last_hb>.15:command();last_hb=now
            f=frame()
            if not f or seen==f[0]:time.sleep(.003);continue
            seen,im,rect=f
            if bool(rect)!=bool(scene):continue
            m=json.loads((bridge/'motion.json').read_text())
            if m['state']!=state:continue
            samples.append(dict(m,scenario=index));seqs.append(seen);times.append(now)
            bg=Image.new('RGBA',(1280,800),(230,240,250,255));d=ImageDraw.Draw(bg)
            d.text((30,24),'Muse Guard — '+('hand-over-hand climb' if state=='climb' else 'walking / joint inspection'),fill=(45,60,80),font_size=24)
            if rect:
                x,y,w,h=rect;assert im.width/w==2
                tile=im.resize((round(w),round(h)),Image.Resampling.LANCZOS)
                bg.alpha_composite(tile,(round(x),round(800-y-h)))
            else:bg.alpha_composite(im,((1280-im.width)//2,(800-im.height)//2))
            mask=np.array(im.getchannel('A'))>100
            holes=binary_fill_holes(mask)&~mask
            _,counts=np.unique(label(holes)[0],return_counts=True)
            if len(counts)>1:max_hole=max(max_hole,int(max(counts[1:])))
            if len(seqs)%12==0:im.save(OUT/f'{index}-{state}-{len(seqs)}.png')
            latest=bg.convert('RGB')
            target=int((now-start)*30)+1
            while encoded<target:writer.send(latest.tobytes());encoded+=1
        while latest and encoded<round(duration*30):writer.send(latest.tobytes());encoded+=1
        fps=(seqs[-1]-seqs[0])/(times[-1]-times[0]) if len(seqs)>1 else 0
        checks.append(dict(scenario=index,state=state,inspection=inspection,fps=round(fps,1),max_enclosed_transparent_pixels=max_hole))
    writer.close();writer=None
    (OUT/'motion.json').write_text(json.dumps(samples));(OUT/'checks.json').write_text(json.dumps(checks,indent=2))
    climb=[m for m in samples if m['scenario']==1 and .12<m['phase']<.88]
    assert climb and all(m['climbing'] and m['desktopScene'] and m['perspectiveScale']==1 for m in climb)
    assert max(m['projectedY'] for m in climb)-min(m['projectedY'] for m in climb)>400
    assert max(m['leftHandHeight']-m['rightHandHeight'] for m in climb)>4
    assert min(m['leftHandHeight']-m['rightHandHeight'] for m in climb)<-4
    walking=[m for m in samples if m['scenario']==0 and .2<m['phase']<.85]
    assert max(m['rumpSway'] for m in walking)>1 and min(m['rumpSway'] for m in walking)<-1
    assert max(abs(m['rumpBounce']) for m in walking)>.15
    assert all(abs(m['rumpSway'])<2.2 for m in samples)
    assert all(abs(m['rumpSway'])<.01 and abs(m['rumpBounce'])<.01 for m in samples if m['scenario']==1 and m['phase']>.3)
    assert all(c['fps']>=24 for c in checks)
    print(json.dumps(checks,indent=2))
finally:
    if writer:writer.close()
    proc.terminate()
    try:proc.wait(timeout=8)
    except subprocess.TimeoutExpired:proc.kill();proc.wait()
    log.close()
