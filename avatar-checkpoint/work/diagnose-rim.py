import bpy, json, math
from mathutils import Vector
from mathutils.bvhtree import BVHTree
D=bpy.context.evaluated_depsgraph_get()
B={}
for name in ['Coat','Face']:
 ob=bpy.data.objects[name];e=ob.evaluated_get(D);me=e.to_mesh();me.calc_loop_triangles()
 print('OBJECT',name,len(ob.data.vertices),len(me.vertices),[(m.name,m.type,getattr(m,'levels',None),getattr(m,'thickness',None)) for m in ob.modifiers])
 B[name]=BVHTree.FromPolygons([tuple(ob.matrix_world@v.co) for v in me.vertices],[tuple(t.vertices) for t in me.loop_triangles],all_triangles=True)
 e.to_mesh_clear()
def point(a,r):
 c=math.cos(a);s=math.sin(a);n=2.2 if s>=0 else 3.85
 return .39*r*math.copysign(abs(c)**(2/n),c),1.55+.279*r*math.copysign(abs(s)**(2/n),s)
def h(name,x,z):
 p,n,i,d=B[name].ray_cast(Vector((x,-2,z)),Vector((0,1,0)),4)
 return p.y if p else 10
samples=[]
for i in range(720):
 a=2*math.pi*i/720
 # Inner radial location of coat visibility.
 vals=[]
 for j in range(101):
  r=.94+j*.0012;x,z=point(a,r);cy=h('Coat',x,z);fy=h('Face',x,z)
  if cy<fy:vals.append(r)
 edge=min(vals) if vals else None
 samples.append((i,edge))
print('EDGES',json.dumps(samples))
co=bpy.data.objects['Coat'];base=26754;per=214
for layer in [0,1,8,9]:
 print('LIP',layer,[(i,tuple(round(c,7) for c in co.data.vertices[base+layer*per+i].co)) for i in range(per) if i%5==0])
