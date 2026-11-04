import bpy
face=bpy.data.objects['Face'];coat=bpy.data.objects['Coat']
assert len(face.data.vertices)==2113
assert len(coat.data.vertices)==23598
assert 'RefinedRecessDepth' not in face,'Already refined; avoid repeated displacement'
# Keep the accepted opening contour and lip; shorten only the inward return.
change=.010
for v in face.data.vertices:
    v.co.y-=change
base=136*160+2;per_layer=204
for layer in range(1,10):
    t=layer/9
    weight=max(0,(t-.72)/.28)**2
    for j in range(per_layer):
        coat.data.vertices[base+(layer-1)*per_layer+j].co.y-=change*weight
for name in ['Eye_L','Eye_R','Glint_L','Glint_R','Mouth','Blush_L','Blush_R']:
    bpy.data.objects[name].location.y-=change
face['RefinedRecessDepth']=.022
face.data.update();coat.data.update();bpy.context.view_layer.update()
scene=bpy.context.scene
scene.render.resolution_x=1024;scene.render.resolution_y=1024;scene.cycles.samples=64
bpy.ops.wm.save_as_mainfile(filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/outputs/plush-character/cream-mascot.blend')
bpy.ops.render.render(write_still=True)
print('Inner recess shortened from 32 to 22 mm; accepted lip contour and body preserved. Saved and rendered.')
