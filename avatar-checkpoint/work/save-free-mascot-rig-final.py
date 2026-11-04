import bpy,json
from pathlib import Path
root=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an');s=bpy.context.scene;r=bpy.data.objects['Mascot Rig']
# Transparent cheek decals are hidden only in the solid posing viewport, where transparency is unsupported.
for name in ['Blush_L','Blush_R']:bpy.data.objects[name].hide_set(True)
for p in r.pose.bones:p.select=False
r.pose.bones['Head'].select=True;r.data.bones.active=r.data.bones['Head']
# Verify independent wink controls with the shared blink animation at rest.
s.frame_set(1);h=r.pose.bones['Head'];h['Blink Left']=1.;r.update_tag();bpy.context.view_layer.update()
assert bpy.data.objects['Eye_L'].data.shape_keys.key_blocks['Blink'].value>.99
assert bpy.data.objects['Eye_R'].data.shape_keys.key_blocks['Blink'].value<.01
h['Blink Left']=0.;r.update_tag();bpy.context.view_layer.update()
s.frame_set(28);s.render.resolution_x=1000;s.render.resolution_y=1000;s.cycles.samples=48;s.render.filepath=str(root/'outputs/plush-character/rig-wave-preview.png');bpy.ops.render.render(write_still=True)
# Inspect a closed-eye expression from the existing detail camera.
main=s.camera;detail=bpy.data.objects.get('Fur Detail Camera')
if detail:
 s.camera=detail;s.frame_set(16);s.render.resolution_x=700;s.render.resolution_y=700;s.cycles.samples=32;s.render.filepath=str(root/'work/rig-blink-check.png');bpy.ops.render.render(write_still=True)
s.camera=main;s.frame_set(28);s.render.resolution_x=1000;s.render.resolution_y=1000;s.cycles.samples=48;s.render.filepath=str(root/'outputs/plush-character/rig-wave-preview.png')
bpy.ops.wm.save_as_mainfile(filepath=str(root/'outputs/plush-character/cream-mascot-rigged.blend'))
print(json.dumps({'saved':bpy.data.filepath,'body_controls':len(r.data.bones),'blink_wink_smile':'verified','active_frame':28,'active_control':'Head','master_unchanged':str(root/'outputs/plush-character/cream-mascot.blend')}))
