import bpy,json
out={}
g=bpy.data.node_groups.new('Rig API Probe','GeometryNodeTree')
for typ in ['GeometryNodeDeformCurvesOnSurface','GeometryNodeObjectInfo','FunctionNodeTransformPoint','GeometryNodeInputNamedAttribute','GeometryNodeIsViewport','GeometryNodeDeleteGeometry','GeometryNodeStoreNamedAttribute','GeometryNodeTransform','GeometryNodeInputCurveTilt','GeometryNodeInputSplineLength','GeometryNodeInputIndex','GeometryNodeInputID','GeometryNodeSetID','ShaderNodeVectorRotate']:
 try:
  n=g.nodes.new(typ);out[typ]={'inputs':[(x.name,x.type,x.identifier) for x in n.inputs],'outputs':[(x.name,x.type,x.identifier) for x in n.outputs]}
 except Exception as e:out[typ]=str(e)
bpy.data.node_groups.remove(g)
o=bpy.data.objects['Coat_PlushGroom']
for m in list(o.modifiers):
 if m.name=='Readiness probe':o.modifiers.remove(m)
out['curve_properties']=[p.identifier for p in o.data.bl_rna.properties]
out['surface_ops']=[p for p in dir(bpy.ops.curves) if any(s in p for s in ['surface','attach','deform'])]
print(json.dumps(out))
