import bpy
from mathutils import Vector
s=bpy.context.scene
saved=(s.camera,s.render.resolution_x,s.render.resolution_y,s.cycles.samples,s.render.filepath)
root='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/outputs/plush-character/'
try:
 cam=bpy.data.objects['Three Quarter Camera'];cam.location=(1.55,-3.7,1.19);cam.rotation_euler=(Vector((0,0,.96))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.ortho_scale=2.72
 s.camera=cam;s.render.resolution_x=1200;s.render.resolution_y=1320;s.cycles.samples=96;s.render.filepath=root+'cream-mascot-three-quarter.png';bpy.ops.render.render(write_still=True)
 print('Angled view saved.')
 cam=bpy.data.objects['Fur Detail Camera'];cam.location=(.28,-3.7,1.73);cam.rotation_euler=(Vector((0,-.30,1.55))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.ortho_scale=1.10
 s.camera=cam;s.render.resolution_x=1000;s.render.resolution_y=1000;s.cycles.samples=96;s.render.filepath=root+'fur-detail.png';bpy.ops.render.render(write_still=True)
 print('New fine fur and face detail saved.')
finally:
 s.camera,s.render.resolution_x,s.render.resolution_y,s.cycles.samples,s.render.filepath=saved
 bpy.ops.wm.save_as_mainfile(filepath=root+'cream-mascot.blend')
print('Final front settings restored and Blender scene saved.')
