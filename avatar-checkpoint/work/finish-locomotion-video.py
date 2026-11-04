import subprocess,time,json,sys
from pathlib import Path
R=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an');frames=R/'work/locomotion/frames';started=time.monotonic();end=b'\x00\x00\x00\x00IEND\xaeB\x60\x82'
while True:
 paths=[frames/f'frame_{i:04d}.png' for i in range(1,529)]
 if all(p.exists() and p.stat().st_size>10000 for p in paths):
  complete=True
  for p in paths:
   with p.open('rb') as f:f.seek(-12,2);complete=complete and f.read()==end
  if complete:break
 if time.monotonic()-started>300:raise TimeoutError('Render frames are incomplete.')
 time.sleep(2)
print('All528 render frames complete; encoding.',flush=True)
with (R/'work/locomotion/encode.log').open('w') as log:
 subprocess.run(['/Applications/Blender.app/Contents/MacOS/Blender','-b','--factory-startup','-P',str(R/'work/encode-locomotion-video.py')],cwd=R,stdout=log,stderr=subprocess.STDOUT,check=True)
subprocess.run([sys.executable,str(R/'work/check-locomotion-video.py')],cwd=R,check=True)
print('LOCOMOTION_VIDEO_FINISHED',flush=True)
