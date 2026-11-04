from pathlib import Path
from PIL import Image,ImageChops,ImageStat,ImageDraw
import json,hashlib,shutil
R=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an');work=R/'work/locomotion';frames=work/'frames';decoded=work/'decoded';rows=[];thumbs=[]
for p in sorted(decoded.glob('decoded_*.png')):
 f=int(p.stem.split('_')[-1]);a=Image.open(p).convert('RGB');b=Image.open(frames/f'frame_{f:04d}.png').convert('RGB');error=sum(ImageStat.Stat(ImageChops.difference(a,b)).mean)/3;assert a.size==(1080,1080) and error<3,(f,error);rows.append({'frame':f,'mean_channel_error':error,'sha256':hashlib.sha256(a.tobytes()).hexdigest()});a.thumbnail((270,270));thumbs.append((f,a))
assert len(rows)==17 and len({r['sha256'] for r in rows})==17
sheet=Image.new('RGB',(270*5,300*4),'white');d=ImageDraw.Draw(sheet)
for i,(f,im) in enumerate(thumbs):
 x=i%5*270;y=i//5*300;sheet.paste(im,(x,y));d.text((x+8,y+276),str(f),fill='black')
sheet.save(work/'final-video-contact-sheet.jpg',quality=92)
meta=json.loads((work/'video-metadata.json').read_text());assert meta['frames']==528 and meta['size']==[1080,1080] and meta['duration_seconds']==22
result={'video':meta,'decoded_frames_checked':len(rows),'maximum_mean_channel_error':max(r['mean_channel_error'] for r in rows),'comparisons':rows};(work/'final-video-validation.json').write_text(json.dumps(result,indent=2));print(json.dumps({k:v for k,v in result.items() if k!='comparisons'}))
shutil.copy2(frames/'frame_0012.png',R/'outputs/plush-character/cream-mascot-walk-and-climb-poster.png')
