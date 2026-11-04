import bpy,json
s=bpy.context.scene
out={'file':bpy.data.filepath,'objects':[],'nodes':{}}
for n in ['Coat','Arm_L','Arm_R','Face','Coat_PlushGroom','Mouth']:
 o=bpy.data.objects[n]
 d={'name':n,'type':o.type,'matrix':[list(r) for r in o.matrix_world],'bounds':[[min((o.matrix_world@v.co)[i] for v in o.data.vertices),max((o.matrix_world@v.co)[i] for v in o.data.vertices)] for i in range(3)] if o.type=='MESH' else None}
 if o.type=='CURVES':
  try:
   m=o.modifiers.new('Readiness probe','ARMATURE');d['armature_support']=m.type;o.modifiers.remove(m)
  except Exception as e:d['armature_support']=str(e)
  d['attributes']=[(a.name,a.data_type,a.domain) for a in o.data.attributes]
 out['objects'].append(d)
g=bpy.data.node_groups.new('Rig API Probe','GeometryNodeTree')
for typ in ['GeometryNodeDeformCurvesOnSurface','GeometryNodeObjectInfo','FunctionNodeTransformPoint','GeometryNodeInputNamedAttribute','GeometryNodeInputIsViewport','GeometryNodeDeleteGeometry','GeometryNodeInputPosition','GeometryNodeSetPosition','GeometryNodeSampleNearestSurface','GeometryNodeInputCurveHandlePositions','GeometryNodeStoreNamedAttribute','GeometryNodeTransform']:
 try:
  n=g.nodes.new(typ);out['nodes'][typ]={'inputs':[(x.name,x.bl_socket_idname) for x in n.inputs],'outputs':[(x.name,x.bl_socket_idname) for x in n.outputs]}
 except Exception as e:out['nodes'][typ]=str(e)
bpy.data.node_groups.remove(g)
print(json.dumps(out))
