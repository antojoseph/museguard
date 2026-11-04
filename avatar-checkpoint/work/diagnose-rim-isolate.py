import bpy
s=bpy.context.scene
s.camera=bpy.data.objects['Fur Detail Camera'];s.render.resolution_x=600;s.render.resolution_y=600;s.cycles.samples=24
for mode in ['main-only','fringe-only']:
 for o in bpy.data.objects:
  if o.type=='CURVES':
   if mode=='main-only':o.hide_render=(o.name in ['FaceEdge_PlushGroom','FaceInnerEdge_PlushGroom'])
   else:o.hide_render=(o.name not in ['FaceEdge_PlushGroom','FaceInnerEdge_PlushGroom'])
 s.render.filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/rim-'+mode+'.png'
 bpy.ops.render.render(write_still=True)
