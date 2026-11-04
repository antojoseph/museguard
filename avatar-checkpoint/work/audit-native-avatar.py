import bpy,json
s=bpy.context.scene
a={"file":bpy.data.filepath,"mesh_objects":[],"fur":[],"armatures":[],"actions":[a.name for a in bpy.data.actions],"shapekeys":[]}
for o in s.objects:
 if o.type=="MESH" and o.name not in ["Ground"]:
  a["mesh_objects"].append({"name":o.name,"vertices":len(o.data.vertices),"polygons":len(o.data.polygons),"uv_layers":len(o.data.uv_layers),"modifiers":[[m.name,m.type] for m in o.modifiers],"materials":[m.name if m else None for m in o.data.materials]})
  if o.data.shape_keys:a["shapekeys"].append({"name":o.name,"keys":[k.name for k in o.data.shape_keys.key_blocks]})
 elif o.type=="CURVES":
  a["fur"].append({"name":o.name,"curves":len(o.data.curves),"points":len(o.data.points),"surface":o.data.surface.name if o.data.surface else None,"modifiers":[m.type for m in o.modifiers]})
 elif o.type=="ARMATURE":a["armatures"].append(o.name)
print(json.dumps(a))
