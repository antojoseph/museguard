import bpy
from mathutils import Vector
s=bpy.context.scene;original=s.camera
root='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/outputs/plush-character/'
cam=bpy.data.objects['Fur Detail Camera'];cam.location=(.28,-3.7,1.73);cam.rotation_euler=(Vector((0,-.30,1.55))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.type='ORTHO';cam.data.ortho_scale=1.10
try:
 s.camera=cam;s.render.resolution_x=900;s.render.resolution_y=900;s.cycles.samples=96;s.render.filepath=root+'fur-detail.png'
 bpy.ops.render.render(write_still=True)
finally:
 s.camera=original;s.render.resolution_x=1080;s.render.resolution_y=1200;s.cycles.samples=128;s.render.filepath=root+'cream-mascot.png'
 bpy.ops.wm.save_as_mainfile(filepath=root+'cream-mascot.blend')
print('Updated face and fur detail rendered; front camera and final scene saved.')
