import bpy,math,numpy as np
rng=np.random.default_rng(92361)
# Dense short underfur supports a separate layer of fine, irregular wisps.
for name in ['Coat','Arm_L','Arm_R','Foot_L','Foot_R']:
 data=bpy.data.objects[name+'_PlushGroom'].data
 pos=np.empty(len(data.points)*3,np.float32);data.position_data.foreach_get('vector',pos);pos=pos.reshape((-1,7,3))
 pos=pos[:,0:1,:]+(pos-pos[:,0:1,:])*.58
 data.position_data.foreach_set('vector',pos.ravel())
 radii=np.empty(len(data.points),np.float32);data.attributes['radius'].data.foreach_get('value',radii);radii*=.78;data.attributes['radius'].data.foreach_set('value',radii)
 # Random thinning leaves room for the longer pile to cast small natural shadows.
 remove=np.flatnonzero(rng.random(len(data.curves))<.38)
 data.remove_curves(indices=remove.tolist())

eye=next(n for n in bpy.data.materials['EyeMat'].node_tree.nodes if n.type=='BSDF_PRINCIPLED');eye.inputs['Specular IOR Level'].default_value=0
for name in ['Glint_L','Glint_R']:bpy.data.objects[name].scale=(.0045,.0014,.0062)
mat=bpy.data.materials['GroomedCreamFibers'];collection=bpy.data.collections['Cream Plush Fur'];deps=bpy.context.evaluated_depsgraph_get()
def guards(name,guides,children,length):
 source=bpy.data.objects[name];ev=source.evaluated_get(deps);me=ev.to_mesh(preserve_all_data_layers=True,depsgraph=deps);me.calc_loop_triangles()
 verts=np.array([v.co[:] for v in me.vertices],np.float32);normals=np.array([v.normal[:] for v in me.vertices],np.float32);tri=np.array([t.vertices[:] for t in me.loop_triangles],np.int32);tv=verts[tri]
 weights=np.ones(len(verts),np.float32);vg=source.vertex_groups.get('FurDensity' if name=='Coat' else 'NoSoleFur' if name.startswith('Foot') else '__none__')
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
 if name.startswith('Foot'):keep&=roots[:,2]>.04
 parentLength=np.repeat(length*rng.uniform(.76,1.23,guides),children);parentAngle=np.repeat(rng.normal(0,.22,guides),children)
 roots=roots[keep];parents=parents[keep];ns=ns[keep];N=len(roots);L=parentLength[keep]*rng.uniform(.80,1.14,N);angles=parentAngle[keep]+rng.normal(0,.06,N)
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
 if name.startswith('Foot'):
  safe=pos[:,:,2].min(1)>=.013;pos=pos[safe];radii=radii[safe]
 count=len(pos);data=bpy.data.hair_curves.new(name+'WispyPile');data.add_curves([7]*count);data.position_data.foreach_set('vector',pos.ravel());radius=data.attributes.new('radius','FLOAT','POINT');radius.data.foreach_set('value',radii.astype(np.float32).ravel());data.set_types(type='CATMULL_ROM');data.materials.append(mat)
 ob=bpy.data.objects.new(name+'_WispyPile',data);collection.objects.link(ob);print(name,count,'fine wisps')
guards('Coat',50000,8,.036)
guards('Arm_L',7000,8,.032)
guards('Arm_R',7000,8,.032)
guards('Foot_L',2500,7,.026)
guards('Foot_R',2500,7,.026)
s=bpy.context.scene;s.render.resolution_x=900;s.render.resolution_y=1000;s.cycles.samples=64;s.render.filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/wispy-fur-preview.png'
bpy.context.view_layer.update();bpy.ops.wm.save_as_mainfile(filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/work/wispy-fur-stage.blend');bpy.ops.render.render(write_still=True)
print('Layered underfur and fine wisps preview rendered.')
