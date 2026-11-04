import bpy
s=bpy.context.scene
bpy.data.objects['KeyLight'].data.color=(1.0,.91,.79)
bpy.data.objects['FillLight'].data.color=(1.0,.96,.90)
bpy.data.objects['FillLight'].data.energy=85
s.world.node_tree.nodes['Background'].inputs['Strength'].default_value=.28
s.cycles.samples=128;s.render.resolution_x=1200;s.render.resolution_y=1200
s.render.filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/fur-warm-preview.png'
bpy.ops.render.render(write_still=True)
print('Warm cream plush preview rendered')
