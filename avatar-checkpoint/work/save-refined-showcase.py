import bpy
assert bpy.data.filepath.endswith('cream-mascot-showcase.blend')
bpy.context.scene.frame_set(96)
bpy.ops.wm.save_as_mainfile(filepath=bpy.data.filepath)
print('Saved showcase with gentler leg motion; rig master unchanged.')
