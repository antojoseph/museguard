import bpy,numpy as np
from mathutils import Vector
s=bpy.context.scene
# Trim fibers that reach through the floor; the paws keep their soft rounded soles.
for name in ['Foot_L_PlushGroom','Foot_R_PlushGroom']:
 d=bpy.data.objects[name].data;pos=np.empty(len(d.points)*3,dtype=np.float32);d.position_data.foreach_get('vector',pos)
 p=pos.reshape((-1,7,3));bad=np.flatnonzero(p[:,:,2].min(axis=1)<.013)
 if len(bad):d.remove_curves(indices=bad.tolist())
 print(name,'sole fibers trimmed',len(bad))
# A single surface subdivision smooths the lip without changing its designed opening.
coat=bpy.data.objects['Coat']
mod=coat.modifiers.get('Smooth continuous lip') or coat.modifiers.new('Smooth continuous lip','SUBSURF');mod.levels=1;mod.render_levels=1
face=bpy.data.objects['Face']
mod=face.modifiers.get('Smooth curved skin') or face.modifiers.new('Smooth curved skin','SUBSURF');mod.levels=1;mod.render_levels=1
# Put surface smoothing before buried thickness.
bpy.context.view_layer.objects.active=face
bpy.ops.object.modifier_move_up(modifier=mod.name)
root='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/outputs/plush-character/'
s['ReferenceRefinement']='Wider and higher curved face, warmer ivory skin and peach cheeks, longer softly tapered arms, broader short feet, shorter irregular cream plush.'
s.render.resolution_x=1080;s.render.resolution_y=1200;s.cycles.samples=128;s.render.filepath=root+'cream-mascot.png'
bpy.context.view_layer.update()
bpy.ops.wm.save_as_mainfile(filepath=root+'cream-mascot.blend')
bpy.ops.render.render(write_still=True)
print('Front render and refined Blender scene saved.')
