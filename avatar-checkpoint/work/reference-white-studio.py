import bpy
s=bpy.context.scene
nt=s.compositing_node_group;nt.nodes.clear()
rl=nt.nodes.new('CompositorNodeRLayers');over=nt.nodes.new('CompositorNodeAlphaOver');out=nt.nodes.new('NodeGroupOutput')
over.inputs['Factor'].default_value=1;over.inputs['Background'].default_value=(1,1,1,1)
nt.links.new(rl.outputs['Image'],over.inputs['Foreground']);nt.links.new(over.outputs['Image'],out.inputs['Image'])
s.render.resolution_x=900;s.render.resolution_y=1000;s.cycles.samples=64
s.render.filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/new-reference-fur-preview.png'
collection=bpy.data.collections['Cream Plush Fur']
for ob in list(bpy.data.objects):
 if ob.name.endswith('_PlushGroom'):
  if ob.name not in collection.objects:collection.objects.link(ob)
  for c in list(ob.users_collection):
   if c!=collection:c.objects.unlink(ob)
bpy.context.view_layer.update()
bpy.ops.wm.save_as_mainfile(filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/reference-refinement-stage.blend')
bpy.ops.render.render(write_still=True)
print('Reference proportions and textured cream plush preview rendered.')
