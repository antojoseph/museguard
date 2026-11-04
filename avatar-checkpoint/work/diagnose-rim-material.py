import bpy
for name in ['CoatMat','FaceMat']:
 m=bpy.data.materials[name]
 print(name)
 for n in m.node_tree.nodes:
  print(n.name,n.type,[(i.name,str(i.default_value)) for i in n.inputs if hasattr(i,'default_value') and i.name in ['Strength','Distance','Scale','Roughness','Base Color']])
 print('LINKS',[(l.from_node.name,l.from_socket.name,l.to_node.name,l.to_socket.name) for l in m.node_tree.links])
