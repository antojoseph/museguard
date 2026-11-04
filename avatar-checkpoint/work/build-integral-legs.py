import bpy,bmesh,math,numpy as np
from mathutils import Vector
coat=bpy.data.objects['Coat'];old=coat.data
assert len(old.vertices)==28894,'Unexpected coat topology; preserve scene rather than making broad edits'
nt=176;junction=28*nt;cutz=float(old.vertices[junction].co.z);toprow=40;topz=float(old.vertices[toprow*nt].co.z)
# Preserve every retained upper vertex, polygon and density value exactly.
upperfaces=[list(p.vertices) for p in old.polygons if min(old.vertices[i].co.z for i in p.vertices)>=cutz-1e-6]
upperids=sorted(set(i for f in upperfaces for i in f));umap={k:i for i,k in enumerate(upperids)}
UV=[tuple(old.vertices[i].co) for i in upperids];UF=[[umap[i] for i in f] for f in upperfaces]
old_groups=[g.name for g in coat.vertex_groups];old_weights={i:{g.group:g.weight for g in old.vertices[i].groups} for i in upperids}
upper_ring=[umap[junction+i] for i in range(nt)]
# Closed lower-body working volume, capped well above the eventual seam.
lowfaces=[list(p.vertices) for p in old.polygons if max(old.vertices[i].co.z for i in p.vertices)<=topz+1e-6]
lowids=sorted(set(i for f in lowfaces for i in f));lmap={k:i for i,k in enumerate(lowids)}
V=[]
for i in lowids:
 x,y,z=old.vertices[i].co;u=max(0,min(1,(.34-z)/(.34-.205)));z+=.030*u*u;V.append((x,y,z))
F=[[lmap[i] for i in f] for f in lowfaces];F.append([lmap[toprow*nt+i] for i in range(nt)])
# Broader stumps: front surfaces blend up into the belly, with no shoe-like toe.
sections=[(.012,.250,-.035,.145,.150),(.023,.250,-.040,.172,.180),(.060,.250,-.040,.180,.195),(.130,.248,-.030,.187,.220),(.220,.245,-.015,.188,.255),(.320,.240,-.005,.200,.300),(.420,.240,0,.210,.335),(.530,.240,0,.200,.340),(.600,.240,0,.135,.250)]
for sign in [-1,1]:
 first=len(V);ns=80
 for z,cx,cy,rx,ry in sections:
  for i in range(ns):
   t=2*math.pi*i/ns;n=3.
   V.append((sign*cx+rx*math.copysign(abs(math.cos(t))**(2/n),math.cos(t)),cy+ry*math.copysign(abs(math.sin(t))**(2/n),math.sin(t)),z))
 for row in range(len(sections)-1):
  for i in range(ns):F.append([first+row*ns+i,first+row*ns+(i+1)%ns,first+(row+1)*ns+(i+1)%ns,first+(row+1)*ns+i])
 F.append([first+i for i in reversed(range(ns))]);F.append([first+(len(sections)-1)*ns+i for i in range(ns)])
me=bpy.data.meshes.new('LegUnionWorkingMesh');me.from_pydata(V,[],F);me.update()
temp=bpy.data.objects.new('LegUnionWorking',me);bpy.context.collection.objects.link(temp)
bm=bmesh.new();bm.from_mesh(me);bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces));bm.to_mesh(me);bm.free()
bpy.ops.object.select_all(action='DESELECT');temp.select_set(True);bpy.context.view_layer.objects.active=temp
rem=temp.modifiers.new('Continuous plush hips','REMESH');rem.mode='VOXEL';rem.voxel_size=.006;rem.use_smooth_shade=True
bpy.ops.object.modifier_apply(modifier=rem.name)
sm=temp.modifiers.new('Soft ankle transitions','SMOOTH');sm.factor=.70;sm.iterations=10;bpy.ops.object.modifier_apply(modifier=sm.name)
# Cut below the exact retained ring; a short analytic loft joins the two meshes.
bm=bmesh.new();bm.from_mesh(temp.data)
bmesh.ops.bisect_plane(bm,geom=list(bm.verts)+list(bm.edges)+list(bm.faces),dist=1e-6,plane_co=(0,0,.50),plane_no=(0,0,1),clear_outer=True)
profile=[(.22,.12,.14),(.25,.28,.25),(.34,.41,.33),(.53,.51,.39),(.82,.54,.40),(1.10,.50,.38)]
def pv(z,k):
 for i in range(len(profile)-1):
  if z<=profile[i+1][0]:break
 p=profile[i];q=profile[i+1];l=profile[max(0,i-1)];r=profile[min(len(profile)-1,i+2)];dt=q[0]-p[0];t=max(0,min(1,(z-p[0])/dt));m0=(q[k]-l[k])/(q[0]-l[0]);m1=(r[k]-p[k])/(r[0]-p[0])
 return (2*t**3-3*t*t+1)*p[k]+(t**3-2*t*t+t)*dt*m0+(-2*t**3+3*t*t)*q[k]+(t**3-t*t)*dt*m1
for v in bm.verts:
 x,y,z=v.co
 if z>.44:
  w=max(0,min(1,(z-.44)/.06));w=w*w*(3-2*w);rx=pv(z,1);ry=pv(z,2);n=2.4
  t=math.atan2(math.copysign(abs(y/ry)**(n/2),y),math.copysign(abs(x/rx)**(n/2),x))
  tx=rx*math.copysign(abs(math.cos(t))**(2/n),math.cos(t));ty=ry*math.copysign(abs(math.sin(t))**(2/n),math.sin(t));v.co.x=x+(tx-x)*w;v.co.y=y+(ty-y)*w
 if z<.025:v.co.z=.013
bmesh.ops.remove_doubles(bm,verts=list(bm.verts),dist=.00001)
bmesh.ops.dissolve_degenerate(bm,edges=list(bm.edges),dist=.000001)
loose=[v for v in bm.verts if not v.link_faces]
if loose:bmesh.ops.delete(bm,geom=loose,context='VERTS')
bm.verts.ensure_lookup_table();bm.verts.index_update()
edges=[e for e in bm.edges if e.is_boundary];graph={}
for e in edges:
 for v in e.verts:graph.setdefault(v.index,[]).append(e.other_vert(v).index)
assert graph and all(len(a)==2 for a in graph.values()),'Unexpected lower boundary'
start=min(graph,key=lambda i:(math.atan2(bm.verts[i].co.y,bm.verts[i].co.x)%(2*math.pi)))
loop=[start];prev=None;cur=start
while True:
 nxt=next(n for n in graph[cur] if n!=prev)
 if nxt==start:break
 assert nxt not in loop,'Boundary loop self-intersection'
 loop.append(nxt);prev,cur=cur,nxt
assert len(loop)==len(graph),'Multiple lower boundaries'
area=sum(bm.verts[loop[i]].co.x*bm.verts[loop[(i+1)%len(loop)]].co.y-bm.verts[loop[(i+1)%len(loop)]].co.x*bm.verts[loop[i]].co.y for i in range(len(loop)))
if area<0:loop=list(reversed(loop))
angles=[math.atan2(bm.verts[i].co.y/pv(.5,2),bm.verts[i].co.x/pv(.5,1))%(2*math.pi) for i in loop]
k=min(range(len(loop)),key=lambda i:angles[i]);loop=loop[k:]+loop[:k];angles=angles[k:]+angles[:k]
assert all(angles[i+1]>angles[i]-1e-7 for i in range(len(angles)-1)),'Boundary is not star-shaped'
offset=len(UV);LV=[tuple(v.co) for v in bm.verts];LF=[[offset+v.index for v in f.verts] for f in bm.faces];lower_ring=[offset+i for i in loop]
# Angular zipper includes every endpoint, even though ring resolutions differ.
allV=UV+LV;allF=UF+LF;i=j=0;na=len(upper_ring);nb=len(lower_ring)
A=[math.atan2(allV[v][1]/pv(cutz,2),allV[v][0]/pv(cutz,1))%(2*math.pi) for v in upper_ring]
A[0]=0.
while i<na or j<nb:
 aa=A[(i+1)%na]+(2*math.pi if i+1>=na else 0) if i<na else float('inf')
 bb=angles[(j+1)%nb]+(2*math.pi if j+1>=nb else 0) if j<nb else float('inf')
 if aa<bb:
  allF.append([upper_ring[i%na],upper_ring[(i+1)%na],lower_ring[j%nb]]);i+=1
 else:
  allF.append([upper_ring[i%na],lower_ring[(j+1)%nb],lower_ring[j%nb]]);j+=1
bm.free()
new=bpy.data.meshes.new('ContinuousBodyAndLegs');new.from_pydata(allV,[],allF);new.update()
check=bmesh.new();check.from_mesh(new);bmesh.ops.recalc_face_normals(check,faces=list(check.faces))
assert sum(e.is_boundary for e in check.edges)==214,'New seam is not closed'
assert not any(len(e.link_faces)>2 for e in check.edges),'Nonmanifold leg seam'
check.to_mesh(new);check.free()
for m in old.materials:new.materials.append(m)
for p in new.polygons:p.use_smooth=True
coat.data=new;coat.vertex_groups.clear()
for name in old_groups:coat.vertex_groups.new(name=name)
for original,newindex in umap.items():
 for groupindex,w in old_weights[original].items():coat.vertex_groups[groupindex].add([newindex],w,'REPLACE')
vg=coat.vertex_groups['FurDensity']
vg.add(list(range(offset,len(allV))),1.,'REPLACE')
legs=coat.vertex_groups.new(name='LegFur')
for v in new.vertices:
 u=max(0,min(1,(v.co.z-.525)/.040));u=u*u*(3-2*u);w=1-u
 if v.co.z<.035:w*=max(0,min(1,(v.co.z-.018)/.017))
 if w>0:legs.add([v.index],w,'REPLACE')
coat['TopologyVersion']='Continuous sculpted hips and legs; original upper-body vertices preserved.'
bpy.data.objects.remove(temp,do_unlink=True)
# Retire the old separate paws and both old fur layers.
for side in ['L','R']:
 for suffix in ['', '_PlushGroom','_WispyPile']:
  ob=bpy.data.objects.get('Foot_'+side+suffix)
  if ob:bpy.data.objects.remove(ob,do_unlink=True)
# Complementary blending keeps upper fur intact and avoids a density belt.
rng=np.random.default_rng(29117)
for name in ['Coat_PlushGroom','Coat_WispyPile']:
 data=bpy.data.objects[name].data;p=np.empty(len(data.points)*3,np.float32);data.position_data.foreach_get('vector',p);z=p.reshape((-1,7,3))[:,0,2]
 u=np.clip((z-.525)/.040,0,1);prob=u*u*(3-2*u);remove=np.flatnonzero(rng.random(len(z))>prob);data.remove_curves(indices=remove.tolist())
 print(name,'old lower roots replaced',len(remove))
bpy.context.view_layer.objects.active=coat;coat.select_set(True);bpy.context.view_layer.update()
bpy.ops.wm.save_as_mainfile(filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/integral-legs-stage.blend')
print('Continuous lower body built; seam boundaries verified; upper face and torso preserved. Lower ring',nb,'vertices.')
