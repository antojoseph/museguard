import bpy,time,json,sys
from pathlib import Path
root=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an');s=bpy.context.scene
args=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
first=int(args[0]) if args else 1;last=int(args[1]) if len(args)>1 else s.frame_end;tag=args[2] if len(args)>2 else 'render'
frames=root/(args[3] if len(args)>3 else 'work/showcase/frames');frames.mkdir(parents=True,exist_ok=True);progress=root/f'work/showcase/{tag}-progress.json'
p=bpy.context.preferences.addons['cycles'].preferences;p.compute_device_type='METAL';p.get_devices()
for d in p.devices:d.use=d.type=='METAL'
s.cycles.device='GPU';s.render.use_persistent_data=True
started=time.monotonic();done=0
for frame in range(first,last+1):
 path=frames/f'frame_{frame:04d}.png'
 if path.exists():
  done+=1;continue
 s.frame_set(frame);s.render.filepath=str(path);t=time.monotonic();bpy.ops.render.render(write_still=True);done+=1
 data={'frame':frame,'done':done,'total':last-first+1,'frame_seconds':round(time.monotonic()-t,3),'elapsed_seconds':round(time.monotonic()-started,2),'file':str(path)}
 progress.write_text(json.dumps(data));print('SHOWCASE_PROGRESS '+json.dumps(data),flush=True)
print('SHOWCASE_FINISHED '+str(last-first+1),flush=True)
