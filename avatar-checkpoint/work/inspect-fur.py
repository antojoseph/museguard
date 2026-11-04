import bpy,json
names=['Coat','Arm_L','Arm_R','Foot_L','Foot_R']
result={}
for name in names:
 ob=bpy.data.objects[name]
 result[name]={'verts':len(ob.data.vertices),'scale':list(ob.scale),'particles':[{'name':ps.name,'count':ps.settings.count,'length':ps.settings.hair_length,'rendered_children':ps.settings.rendered_child_count,'material':ps.settings.material,'density':ps.vertex_group_density} for ps in ob.particle_systems],'materials':[m.name for m in ob.data.materials]}
print(json.dumps(result))
print('Hair curves available:',hasattr(bpy.data,'hair_curves'))
if hasattr(bpy.data,'hair_curves'):
 h=bpy.data.hair_curves.new('FurAPIProbe')
 print('Curve funcs:',[x.identifier for x in h.bl_rna.functions])
 print('Curve properties:',[x.identifier for x in h.bl_rna.properties])
 bpy.data.hair_curves.remove(h)
print('Current output',bpy.context.scene.render.filepath)
