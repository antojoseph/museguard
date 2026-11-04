import bpy
from pathlib import Path
s=bpy.context.scene;p=bpy.context.preferences.addons['cycles'].preferences;p.compute_device_type='METAL';p.get_devices()
for d in p.devices:d.use=d.type=='METAL'
s.cycles.device='GPU';s.cycles.samples=12;s.render.resolution_percentage=67;s.render.use_persistent_data=True
for name in ['Coat','Coat_FurBindingSurface']:
 for m in bpy.data.objects[name].modifiers:
  if m.type=='ARMATURE':m.use_deform_preserve_volume=True
for f in [12,405,415,452,470]:
 s.frame_set(f);s.render.filepath=str(Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/locomotion/previews')/f'dqs_{f:04d}.png');bpy.ops.render.render(write_still=True)
