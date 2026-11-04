import bpy
from mathutils import Vector
s=bpy.context.scene
cam=s.camera;cam.location=(.10,-4,1.16);cam.rotation_euler=(Vector((0,0,.96))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.ortho_scale=2.72
root='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/outputs/plush-character/'
s.render.resolution_x=1440;s.render.resolution_y=1600;s.cycles.samples=128;s.render.filepath=root+'cream-mascot.png'
s['FinePlushRefinement']='Smooth protected face opening, individually sampled short underfur with fine wispy upper pile, lower shoulders, fuller hood, warm face and single eye gleams.'
bpy.context.view_layer.update();bpy.ops.wm.save_as_mainfile(filepath=root+'cream-mascot.blend');bpy.ops.render.render(write_still=True)
print('Final 1440x1600 fine-plush front render and scene saved.')
