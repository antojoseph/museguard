import bpy,math,numpy as np
from mathutils import Vector
rng=np.random.default_rng(75241)
coat=bpy.data.objects['Coat'];vg=coat.vertex_groups['FurDensity']
for v in coat.data.vertices:
 if v.co.z<.035:vg.add([v.index],max(0,min(1,(v.co.z-.018)/.017)),'REPLACE')
bpy.context.view_layer.update();deps=bpy.context.evaluated_depsgraph_get()
mat=bpy.data.materials['GroomedCreamFibers'];collection=bpy.data.collections['Cream Plush Fur']
def make_groom(name,count,length):
 source=bpy.data.objects['Coat'];evaluated=source.evaluated_get(deps)
 me=evaluated.to_mesh(preserve_all_data_layers=True,depsgraph=deps);me.calc_loop_triangles()
 vertices=np.asarray([v.co[:] for v in me.vertices],np.float32);normals=np.asarray([v.normal[:] for v in me.vertices],np.float32)
 triangles=np.asarray([t.vertices[:] for t in me.loop_triangles],np.int32)
 tv=vertices[triangles];areas=np.linalg.norm(np.cross(tv[:,1]-tv[:,0],tv[:,2]-tv[:,0]),axis=1)*.5
 weights=np.ones(len(vertices),np.float32)
 vg=source.vertex_groups['LegFur']
 if vg:
  for v in me.vertices:weights[v.index]=next((g.weight for g in v.groups if g.group==vg.index),0.)
 probs=areas*weights[triangles].mean(axis=1);assert probs.sum()>0,(name,'No emission weights');probs/=probs.sum()
 candidates=int(count*1.3);ids=rng.choice(len(triangles),candidates,p=probs)
 u=rng.random((candidates,2));su=np.sqrt(u[:,0]);bc=np.stack([1-su,su*(1-u[:,1]),su*u[:,1]],axis=1)
 roots=(tv[ids]*bc[:,:,None]).sum(axis=1)
 ns=(normals[triangles[ids]]*bc[:,:,None]).sum(axis=1);ns/=np.maximum(np.linalg.norm(ns,axis=1),1e-8)[:,None]
 density=(weights[triangles[ids]]*bc).sum(axis=1)
 keep=rng.random(candidates)<density
 if name=='Coat':
  powers=np.where(roots[:,2]>=1.55,2.2,3.85)
  r=(np.abs(roots[:,0]/.39)**powers+np.abs((roots[:,2]-1.55)/.279)**powers)**(1/powers)
  front=(roots[:,1]<-.18)&(roots[:,2]>1.15)&(roots[:,2]<1.96)
  keep&=~(front&(r<1.025))
 if name=='Legs':keep&=roots[:,2]>.035
 use=np.flatnonzero(keep)[:count];roots=roots[use];ns=ns[use];count=len(use)
 evaluated.to_mesh_clear()
 flow=np.zeros_like(roots);flow[:,2]=-1
 flow[:,0]=.14*np.sin(roots[:,2]*16+roots[:,1]*11)+.07*np.cos(roots[:,0]*23)
 flow[:,1]=.04*np.sin(roots[:,0]*19+roots[:,2]*17)
 lengths=length*rng.uniform(.73,1.23,count)
 lengths*=.84+.26*np.clip((roots[:,2]-.13)/.40,0,1)
 if name=='Coat':
  powers=np.where(roots[:,2]>=1.55,2.2,3.85);r=(np.abs(roots[:,0]/.39)**powers+np.abs((roots[:,2]-1.55)/.279)**powers)**(1/powers)
  front=(roots[:,1]<-.18)&(roots[:,2]>1.15)&(roots[:,2]<1.96)
  away=np.stack([roots[:,0],np.zeros(count),(roots[:,2]-1.55)*1.3],axis=1);away/=np.maximum(np.linalg.norm(away,axis=1),1e-8)[:,None]
  blend=np.clip((1.23-r)/.17,0,1);blend=blend*blend*(3-2*blend);blend*=front
  flow=flow*(1-blend[:,None])+away*blend[:,None]
  fade=np.clip((r-1.025)/.16,0,1);fade=fade*fade*(3-2*fade)
  lengths*=np.where(front,.22+.78*fade,1)
 tang=flow-ns*np.sum(flow*ns,axis=1)[:,None];tang/=np.maximum(np.linalg.norm(tang,axis=1),1e-8)[:,None]
 side=np.cross(ns,tang);side/=np.maximum(np.linalg.norm(side,axis=1),1e-8)[:,None]
 # Small individual deviations preserve the overall downward plush nap.
 angle=rng.normal(0,.10,count);direction=tang*np.cos(angle[:,None])+side*np.sin(angle[:,None])
 t=np.linspace(0,1,7,dtype=np.float32)[None,:,None]
 lift=lengths[:,None,None]*(.66*t-.17*t*t)
 swept=lengths[:,None,None]*(.23*t+.53*t*t)
 phase=rng.uniform(0,2*math.pi,count)[:,None,None];wave=rng.uniform(-1,1,count)[:,None,None]
 irregular=side[:,None,:]*(.00085*wave*np.sin(math.pi*t)+.00035*np.sin(phase+9*t)*t)
 pos=(roots[:,None,:]+ns[:,None,:]*(lift-.00035)+direction[:,None,:]*swept+irregular).astype(np.float32)
 root_radius=(rng.uniform(.000115,.000225,count)*.78).astype(np.float32)
 radii=root_radius[:,None]*(.94*(1-t[0,:,0])**.75+.06)[None,:]
 if name=='Legs':
  safe=pos[:,:,2].min(axis=1)>=.013;pos=pos[safe];radii=radii[safe];count=len(pos)
 old=bpy.data.objects.get(name+'_PlushGroom')
 if old:
  olddata=old.data;bpy.data.objects.remove(old,do_unlink=True)
  if olddata.users==0:bpy.data.hair_curves.remove(olddata)
 data=bpy.data.hair_curves.new(name+'FineFibers');data.add_curves([7]*count);data.position_data.foreach_set('vector',pos.ravel())
 radius=data.attributes.new('radius','FLOAT','POINT');radius.data.foreach_set('value',radii.astype(np.float32).ravel());data.set_types(type='CATMULL_ROM');data.materials.append(mat)
 ob=bpy.data.objects.new(name+'_PlushGroom',data);collection.objects.link(ob);ob['description']='Fine dense cream plush, individually sampled on the smooth surface; short outward nap beside face.'
 print(name,count,'fine strands')

def guards(name,guides,children,length):
 source=bpy.data.objects['Coat'];ev=source.evaluated_get(deps);me=ev.to_mesh(preserve_all_data_layers=True,depsgraph=deps);me.calc_loop_triangles()
 verts=np.array([v.co[:] for v in me.vertices],np.float32);normals=np.array([v.normal[:] for v in me.vertices],np.float32);tri=np.array([t.vertices[:] for t in me.loop_triangles],np.int32);tv=verts[tri]
 weights=np.ones(len(verts),np.float32);vg=source.vertex_groups['LegFur']
 if vg:
  for v in me.vertices:weights[v.index]=next((g.weight for g in v.groups if g.group==vg.index),0)
 probs=np.linalg.norm(np.cross(tv[:,1]-tv[:,0],tv[:,2]-tv[:,0]),axis=1)*weights[tri].mean(axis=1);probs/=probs.sum()
 ids=rng.choice(len(tri),guides,p=probs);u=rng.random((guides,2));su=np.sqrt(u[:,0]);parentbc=np.stack([1-su,su*(1-u[:,1]),su*u[:,1]],1);parents=(tv[ids]*parentbc[:,:,None]).sum(1)
 ids=np.repeat(ids,children);parentbc=np.repeat(parentbc,children,axis=0);parents=np.repeat(parents,children,axis=0);N=len(ids)
 u=rng.random((N,2));su=np.sqrt(u[:,0]);randomBC=np.stack([1-su,su*(1-u[:,1]),su*u[:,1]],1);bc=parentbc*.65+randomBC*.35
 roots=(tv[ids]*bc[:,:,None]).sum(1);ns=(normals[tri[ids]]*bc[:,:,None]).sum(1);ns/=np.maximum(np.linalg.norm(ns,axis=1),1e-8)[:,None];density=(weights[tri[ids]]*bc).sum(1)
 keep=(rng.random(N)<density)
 if name=='Coat':
  p=np.where(roots[:,2]>=1.55,2.2,3.85);r=(np.abs(roots[:,0]/.39)**p+np.abs((roots[:,2]-1.55)/.279)**p)**(1/p);front=(roots[:,1]<-.18)&(roots[:,2]>1.15)&(roots[:,2]<1.96);keep&=~(front&(r<1.045))
 if name=='Legs':keep&=roots[:,2]>.04
 parentLength=np.repeat(length*rng.uniform(.76,1.23,guides),children);parentAngle=np.repeat(rng.normal(0,.22,guides),children)
 roots=roots[keep];parents=parents[keep];ns=ns[keep];N=len(roots);L=parentLength[keep]*rng.uniform(.80,1.14,N);angles=parentAngle[keep]+rng.normal(0,.06,N)
 L*=.84+.32*np.clip((roots[:,2]-.13)/.40,0,1)
 ev.to_mesh_clear()
 flow=np.zeros_like(roots);flow[:,2]=-1;flow[:,0]=.21*np.sin(roots[:,2]*18+roots[:,1]*12)+.10*np.cos(roots[:,0]*25);flow[:,1]=.06*np.sin(roots[:,0]*21+roots[:,2]*13)
 if name=='Coat':
  p=np.where(roots[:,2]>=1.55,2.2,3.85);r=(np.abs(roots[:,0]/.39)**p+np.abs((roots[:,2]-1.55)/.279)**p)**(1/p);front=(roots[:,1]<-.18)&(roots[:,2]>1.15)&(roots[:,2]<1.96)
  away=np.stack([roots[:,0],np.zeros(N),(roots[:,2]-1.55)*1.3],1);away/=np.maximum(np.linalg.norm(away,axis=1),1e-8)[:,None];blend=np.clip((1.25-r)/.19,0,1);blend=blend*blend*(3-2*blend)*front
  flow=flow*(1-blend[:,None])+away*blend[:,None];fade=np.clip((r-1.045)/.17,0,1);L*=np.where(front,.20+.8*fade,1)
 d=flow-ns*np.sum(flow*ns,axis=1)[:,None];d/=np.maximum(np.linalg.norm(d,axis=1),1e-8)[:,None];side=np.cross(ns,d);side/=np.maximum(np.linalg.norm(side,axis=1),1e-8)[:,None]
 d=d*np.cos(angles[:,None])+side*np.sin(angles[:,None]);offset=roots-parents
 t=np.linspace(0,1,7,dtype=np.float32)[None,:,None];phase=rng.uniform(0,2*math.pi,N)[:,None,None];wave=rng.uniform(-1,1,N)[:,None,None]
 pos=(roots[:,None,:]+ns[:,None,:]*(L[:,None,None]*(.82*t-.20*t*t)-.00025)+d[:,None,:]*(L[:,None,None]*(.23*t+.49*t*t))-offset[:,None,:]*(.40*t*t)+side[:,None,:]*(.0014*wave*np.sin(math.pi*t)+.00065*np.sin(phase+8*t)*t)).astype(np.float32)
 widths=rng.uniform(.000155,.000275,N).astype(np.float32);radii=widths[:,None]*(.94*(1-t[0,:,0])**.7+.06)[None,:]
 if name=='Legs':
  safe=pos[:,:,2].min(1)>=.013;pos=pos[safe];radii=radii[safe]
 count=len(pos);data=bpy.data.hair_curves.new(name+'WispyPile');data.add_curves([7]*count);data.position_data.foreach_set('vector',pos.ravel());radius=data.attributes.new('radius','FLOAT','POINT');radius.data.foreach_set('value',radii.astype(np.float32).ravel());data.set_types(type='CATMULL_ROM');data.materials.append(mat)
 ob=bpy.data.objects.new(name+'_WispyPile',data);collection.objects.link(ob);print(name,count,'fine wisps')

make_groom('Legs',150000,.018)
guards('Legs',18000,8,.031)
s=bpy.context.scene;original=s.camera
cam=bpy.data.objects.get('Leg Detail Camera')
if cam is None:
 data=bpy.data.cameras.new('Leg Detail Camera');cam=bpy.data.objects.new('Leg Detail Camera',data);s.collection.objects.link(cam)
cam.location=(.10,-3,.50);cam.rotation_euler=(Vector((0,-.03,.29))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.type='ORTHO';cam.data.ortho_scale=1.20
saved=(s.render.resolution_x,s.render.resolution_y,s.cycles.samples,s.render.filepath)
try:
 s.camera=cam;s.render.resolution_x=900;s.render.resolution_y=900;s.cycles.samples=64;s.render.filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/integral-legs-preview.png';bpy.ops.render.render(write_still=True)
finally:
 s.camera=original;s.render.resolution_x,s.render.resolution_y,s.cycles.samples,s.render.filepath=saved
bpy.ops.wm.save_as_mainfile(filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/integral-legs-stage.blend')
print('Continuous legs groomed to match the body; close-up preview rendered.')
