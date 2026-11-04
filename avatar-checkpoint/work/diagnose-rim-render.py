import bpy
s=bpy.context.scene
for o in bpy.data.objects:
 if o.type=='CURVES' or o.type=='CURVE' and o.name.endswith('_PlushGroom'): o.hide_render=True
s.camera=bpy.data.objects['Fur Detail Camera'];s.render.resolution_x=600;s.render.resolution_y=600;s.cycles.samples=24;s.render.filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/rim-clay-diagnostic.png'
bpy.ops.render.render(write_still=True)
