import bpy,json,time
from pathlib import Path
root=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an');s=bpy.context.scene;out=root/'work/locomotion/previews';out.mkdir(parents=True,exist_ok=True)
p=bpy.context.preferences.addons['cycles'].preferences;p.compute_device_type='METAL';p.get_devices()
for d in p.devices:d.use=d.type=='METAL'
s.cycles.device='GPU';s.cycles.samples=12;s.render.resolution_percentage=67;s.render.use_persistent_data=True
for f in [12,34,108,200,396,405,415,430,452,470,510]:
 s.frame_set(f);s.render.filepath=str(out/f'preview_{f:04d}.png');bpy.ops.render.render(write_still=True);print('PREVIEW '+str(f),flush=True)
