import bpy
from mathutils import Vector
root='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/outputs/plush-character/'
s=bpy.context.scene
s.render.filepath=root+'cream-mascot.png'
bpy.data.images['Render Result'].save_render(filepath=s.render.filepath,scene=s)
collection=bpy.data.collections.get('Cream Plush Fur') or bpy.data.collections.new('Cream Plush Fur')
if collection.name not in s.collection.children:s.collection.children.link(collection)
for ob in list(bpy.data.objects):
 if ob.name.endswith('_PlushGroom'):
  if ob.name not in collection.objects:collection.objects.link(ob)
  for c in list(ob.users_collection):
   if c!=collection:c.objects.unlink(ob)
s['FurStyle']='Dense cream plush with tapered fibers, gentle directional tufts, shorter pile around face and soles.'
bpy.ops.wm.save_as_mainfile(filepath=root+'cream-mascot.blend')
# Inspect the real fibers in a separate close-up, then restore the full character camera.
original=s.camera
camdata=bpy.data.cameras.get('Fur Detail Camera') or bpy.data.cameras.new('Fur Detail Camera')
cam=bpy.data.objects.get('Fur Detail Camera')
if cam is None:
 cam=bpy.data.objects.new('Fur Detail Camera',camdata);s.collection.objects.link(cam)
cam.location=(.40,-3.5,1.50);target=Vector((0,-.38,1.10))
cam.rotation_euler=(target-cam.location).to_track_quat('-Z','Y').to_euler();camdata.type='ORTHO';camdata.ortho_scale=.85
try:
 s.camera=cam;s.render.resolution_x=1000;s.render.resolution_y=1000;s.render.filepath=root+'fur-detail.png'
 bpy.ops.render.render(write_still=True)
finally:
 s.camera=original;s.render.resolution_x=1200;s.render.resolution_y=1200;s.render.filepath=root+'cream-mascot.png'
 bpy.ops.wm.save_as_mainfile(filepath=root+'cream-mascot.blend')
print('Saved full mascot and native groom; fur close-up rendered; main camera restored.')
