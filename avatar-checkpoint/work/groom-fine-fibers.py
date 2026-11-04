import bpy,math,numpy as np

def lin(v):return v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4
def rgb(h):return tuple(lin(int(h[i:i+2],16)/255) for i in (0,2,4))
mat=bpy.data.materials['GroomedCreamFibers'];nodes=mat.node_tree.nodes
ramp=next(n for n in nodes if n.type=='VALTORGB')
for e,col in zip(ramp.color_ramp.elements,['D7C29E','E2CDB0','ECDAC0','F2E4CF']):e.color=(*rgb(col),1)
hair=next(n for n in nodes if n.type=='BSDF_HAIR_PRINCIPLED');hair.inputs['Roughness'].default_value=.62;hair.inputs['Radial Roughness'].default_value=.72
# Direct, dense sampling gives fine individual roots rather than sparse child bundles.
rng=np.random.default_rng(61241);deps=bpy.context.evaluated_depsgraph_get()
collection=bpy.data.collections['Cream Plush Fur']

def make_groom(name,count,length):
 source=bpy.data.objects[name];evaluated=source.evaluated_get(deps)
 me=evaluated.to_mesh(preserve_all_data_layers=True,depsgraph=deps);me.calc_loop_triangles()
 vertices=np.asarray([v.co[:] for v in me.vertices],np.float32);normals=np.asarray([v.normal[:] for v in me.vertices],np.float32)
 triangles=np.asarray([t.vertices[:] for t in me.loop_triangles],np.int32)
 tv=vertices[triangles];areas=np.linalg.norm(np.cross(tv[:,1]-tv[:,0],tv[:,2]-tv[:,0]),axis=1)*.5
 weights=np.ones(len(vertices),np.float32)
 vg=source.vertex_groups.get('FurDensity' if name=='Coat' else 'NoSoleFur' if name.startswith('Foot') else '__none__')
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
 if name.startswith('Foot'):keep&=roots[:,2]>.035
 use=np.flatnonzero(keep)[:count];roots=roots[use];ns=ns[use];count=len(use)
 evaluated.to_mesh_clear()
 flow=np.zeros_like(roots);flow[:,2]=-1
 flow[:,0]=.14*np.sin(roots[:,2]*16+roots[:,1]*11)+.07*np.cos(roots[:,0]*23)
 flow[:,1]=.04*np.sin(roots[:,0]*19+roots[:,2]*17)
 lengths=length*rng.uniform(.73,1.23,count)
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
 root_radius=rng.uniform(.000115,.000225,count).astype(np.float32)
 radii=root_radius[:,None]*(.94*(1-t[0,:,0])**.75+.06)[None,:]
 if name.startswith('Foot'):
  safe=pos[:,:,2].min(axis=1)>=.013;pos=pos[safe];radii=radii[safe];count=len(pos)
 old=bpy.data.objects.get(name+'_PlushGroom')
 if old:
  olddata=old.data;bpy.data.objects.remove(old,do_unlink=True)
  if olddata.users==0:bpy.data.hair_curves.remove(olddata)
 data=bpy.data.hair_curves.new(name+'FineFibers');data.add_curves([7]*count);data.position_data.foreach_set('vector',pos.ravel())
 radius=data.attributes.new('radius','FLOAT','POINT');radius.data.foreach_set('value',radii.astype(np.float32).ravel());data.set_types(type='CATMULL_ROM');data.materials.append(mat)
 ob=bpy.data.objects.new(name+'_PlushGroom',data);collection.objects.link(ob);ob['description']='Fine dense cream plush, individually sampled on the smooth surface; short outward nap beside face.'
 print(name,count,'fine strands')

make_groom('Coat',700000,.0305)
make_groom('Arm_L',100000,.028)
make_groom('Arm_R',100000,.028)
make_groom('Foot_L',40000,.024)
make_groom('Foot_R',40000,.024)
s=bpy.context.scene;s.render.resolution_x=900;s.render.resolution_y=1000;s.cycles.samples=64
s.render.filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/fine-fiber-preview.png'
bpy.context.view_layer.update()
bpy.ops.wm.save_as_mainfile(filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/fine-fiber-stage.blend')
bpy.ops.render.render(write_still=True)
print('Fine fiber reference refinement rendered.')
