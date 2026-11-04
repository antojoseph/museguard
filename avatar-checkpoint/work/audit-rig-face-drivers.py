import bpy,json
s=bpy.context.scene;r=bpy.data.objects['Mascot Rig'];out={}
for frame in [1,16,28,120]:
 s.frame_set(frame);bpy.context.view_layer.update();deps=bpy.context.evaluated_depsgraph_get();evr=r.evaluated_get(deps)
 d={'head_blink':r.pose.bones['Head'].get('Blink','MISSING'),'evaluated_blink':evr.pose.bones['Head'].get('Blink','MISSING'),'drivers':[],'keys':[]}
 for n in ['Eye_L','Glint_L','Mouth']:
  o=bpy.data.objects[n];k=o.data.shape_keys
  for fc in k.animation_data.drivers:
   d['drivers'].append({'object':n,'valid':fc.driver.is_valid,'expression':fc.driver.expression,'variables':[(v.name,v.targets[0].data_path) for v in fc.driver.variables]})
  ev=o.evaluated_get(deps);mesh=ev.to_mesh();d['keys'].append({'object':n,'value':[b.value for b in k.key_blocks],'ev_values':[b.value for b in ev.data.shape_keys.key_blocks] if ev.type=='MESH' and ev.data.shape_keys else None,'vertex_z_range':max(v.co.z for v in mesh.vertices)-min(v.co.z for v in mesh.vertices)})
  ev.to_mesh_clear()
 out[str(frame)]=d
print(json.dumps(out))
