import bpy
from mathutils import Vector
s=bpy.context.scene;original=s.camera
root='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/outputs/plush-character/'
cam=bpy.data.objects.get('Three Quarter Camera')
if cam is None:
 data=bpy.data.cameras.new('Three Quarter Camera');cam=bpy.data.objects.new('Three Quarter Camera',data);s.collection.objects.link(cam)
cam.location=(1.55,-3.7,1.25);cam.rotation_euler=(Vector((0,0,1.02))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.type='ORTHO';cam.data.ortho_scale=2.46
try:
 s.camera=cam;s.render.resolution_x=1000;s.render.resolution_y=1100;s.cycles.samples=96;s.render.filepath=root+'cream-mascot-three-quarter.png'
 bpy.ops.render.render(write_still=True)
finally:
 s.camera=original;s.render.resolution_x=1080;s.render.resolution_y=1200;s.cycles.samples=128;s.render.filepath=root+'cream-mascot.png'
 bpy.ops.wm.save_as_mainfile(filepath=root+'cream-mascot.blend')
print('Three-quarter shape and recessed-face verification render saved; front camera restored.')
