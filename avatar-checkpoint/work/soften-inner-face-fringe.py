import bpy,math,numpy as np
from mathutils import Vector
s=bpy.context.scene;ob=bpy.data.objects['Coat'];me=ob.data;base=152*176+2;per=(len(me.vertices)-base)//10
assert base+per*10==len(me.vertices)
old=bpy.data.objects.get('FaceInnerEdge_PlushGroom')
if old:bpy.data.objects.remove(old,do_unlink=True)
# Short, individually tapered fibers finish the integral opening; no added rim mesh.
a=np.array([me.vertices[base+8*per+i].co[:] for i in range(per)])
b=np.array([me.vertices[base+9*per+i].co[:] for i in range(per)])
na=np.array([me.vertices[base+8*per+i].normal[:] for i in range(per)])
nb=np.array([me.vertices[base+9*per+i].normal[:] for i in range(per)])
from mathutils.bvhtree import BVHTree
deps=bpy.context.evaluated_depsgraph_get();evaluated=ob.evaluated_get(deps);smooth=evaluated.to_mesh();smooth.calc_loop_triangles()
bvh=BVHTree.FromPolygons([tuple(v.co) for v in smooth.vertices],[tuple(t.vertices) for t in smooth.loop_triangles],all_triangles=True)
lengths=np.linalg.norm(np.roll(a,-1,axis=0)-a,axis=1);prob=lengths/lengths.sum();rng=np.random.default_rng(7503)
count=24000;pos=np.empty((count,5,3),np.float32);rad=np.empty((count,5),np.float32)
for k,i in enumerate(rng.choice(per,count,p=prob)):
 j=(i+1)%per;u=rng.random();v=rng.random()
 p=(1-v)*((1-u)*a[i]+u*a[j])+v*((1-u)*b[i]+u*b[j]);n=(1-v)*((1-u)*na[i]+u*na[j])+v*((1-u)*nb[i]+u*nb[j]);n/=np.linalg.norm(n)
 point,no,_,_=bvh.find_nearest(Vector(p));p=np.array(point[:]);n=np.array(no[:])
 d=np.array([p[0],0,p[2]-1.55]);d-=n*np.dot(d,n);d/=np.linalg.norm(d);side=np.cross(n,d)
 L=rng.uniform(.004,.009);width=rng.uniform(.00010,.00018);wave=rng.uniform(-.0007,.0007)
 for step,t in enumerate(np.linspace(0,1,5)):
  pos[k,step]=p+n*(L*.65*t-.0003)+d*L*.40*t*t+side*wave*math.sin(math.pi*t)
  rad[k,step]=width*((1-t)**.7*.92+.08)
data=bpy.data.hair_curves.new('FineInnerOpeningFibers');data.add_curves([5]*count);data.position_data.foreach_set('vector',pos.ravel());radius=data.attributes.new('radius','FLOAT','POINT');radius.data.foreach_set('value',rad.ravel());data.set_types(type='CATMULL_ROM');data.materials.append(bpy.data.materials['GroomedCreamFibers'])
fur=bpy.data.objects.new('FaceInnerEdge_PlushGroom',data);bpy.data.collections['Cream Plush Fur'].objects.link(fur)
evaluated.to_mesh_clear()
original=s.camera;s.camera=bpy.data.objects['Fur Detail Camera'];s.render.resolution_x=900;s.render.resolution_y=900;s.cycles.samples=64
s.render.filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/soft-fringe-detail.png'
try:
 bpy.context.view_layer.update();bpy.ops.render.render(write_still=True)
finally:
 s.camera=original;s.render.resolution_x=1080;s.render.resolution_y=1200;s.cycles.samples=128;s.render.filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/outputs/plush-character/cream-mascot.png'
print('Fine inner face fringe projected onto the smoothed hood and inspected.')
