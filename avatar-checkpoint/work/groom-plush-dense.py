import bpy, math, random
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

def lin(v):return v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4
def rgb(h):return tuple(lin(int(h[i:i+2],16)/255) for i in (0,2,4))
# Tinted, matte plush fibers with subtle strand-to-strand variation.
mat=bpy.data.materials.get('GroomedCreamFibers') or bpy.data.materials.new('GroomedCreamFibers')
mat.use_nodes=True;nodes=mat.node_tree.nodes;nodes.clear();links=mat.node_tree.links
out=nodes.new('ShaderNodeOutputMaterial');hair=nodes.new('ShaderNodeBsdfHairPrincipled');hair.parametrization='COLOR'
info=nodes.new('ShaderNodeHairInfo');ramp=nodes.new('ShaderNodeValToRGB')
ramp.color_ramp.elements.remove(ramp.color_ramp.elements[1])
for i,(pos,col) in enumerate([(0,'CEB48F'),(.35,'DBC3A0'),(.8,'E4D0AF'),(1,'EEDDC2')]):
 e=ramp.color_ramp.elements[0] if i==0 else ramp.color_ramp.elements.new(pos)
 e.position=pos;e.color=(*rgb(col),1)
links.new(info.outputs['Random'],ramp.inputs['Fac']);links.new(ramp.outputs['Color'],hair.inputs['Color'])
hair.inputs['Roughness'].default_value=.62
if 'Radial Roughness' in hair.inputs:hair.inputs['Radial Roughness'].default_value=.72
if 'Coat' in hair.inputs:hair.inputs['Coat'].default_value=.0
links.new(hair.outputs[0],out.inputs['Surface']);mat.diffuse_color=(*rgb('E8D6B6'),1)

# Keep the old particle coat available but hidden for a reversible comparison.
for name in ['Coat','Arm_L','Arm_R','Foot_L','Foot_R']:
 ob=bpy.data.objects[name]
 for mod in ob.modifiers:
  if mod.type=='PARTICLE_SYSTEM':mod.show_render=False;mod.show_viewport=False
 for old in list(bpy.data.objects):
  if old.name==name+'_PlushGroom':bpy.data.objects.remove(old,do_unlink=True)

rng=np.random.default_rng(58271)

def groom(name,guides,children,length):
 ob=bpy.data.objects[name];me=ob.data;me.calc_loop_triangles()
 vertices=np.array([v.co[:] for v in me.vertices],dtype=np.float64)
 normals=np.array([v.normal[:] for v in me.vertices],dtype=np.float64)
 triangles=np.array([t.vertices[:] for t in me.loop_triangles],dtype=np.int32)
 tv=vertices[triangles];cross=np.cross(tv[:,1]-tv[:,0],tv[:,2]-tv[:,0]);areas=np.linalg.norm(cross,axis=1)*.5
 weights=np.ones(len(vertices))
 if name=='Coat':
  vg=ob.vertex_groups.get('FurDensity')
  for v in me.vertices:
   weights[v.index]=next((g.weight for g in v.groups if g.group==vg.index),0.)
 elif name.startswith('Foot'):
  vg=ob.vertex_groups.get('NoSoleFur')
  for v in me.vertices:
   weights[v.index]=next((g.weight for g in v.groups if g.group==vg.index),0.)
 probs=areas*np.mean(weights[triangles],axis=1)
 probs/=probs.sum()
 ti=rng.choice(len(triangles),size=guides,p=probs)
 u=rng.random((guides,2));su=np.sqrt(u[:,0]);bc=np.stack([1-su,su*(1-u[:,1]),su*u[:,1]],axis=1)
 roots=(tv[ti]*bc[:,:,None]).sum(axis=1)
 ns=(normals[triangles[ti]]*bc[:,:,None]).sum(axis=1);ns/=np.linalg.norm(ns,axis=1)[:,None]
 # Low-frequency swirls keep adjacent tufts aligned; the torso pile hangs downward.
 flow=np.zeros_like(ns);flow[:,2]=-1
 flow[:,0]=.24*np.sin(roots[:,2]*15+roots[:,1]*9)+.12*np.cos(roots[:,0]*20)
 if name=='Coat':
  hood=(roots[:,2]>1.16)&(roots[:,1]<-.12)
  flow[hood,0]+=roots[hood,0]*1.5
 if name.startswith('Arm'):
  flow[:,0]+=(.18 if name.endswith('R') else -.18)
 tang=flow-ns*np.sum(flow*ns,axis=1)[:,None]
 norms=np.linalg.norm(tang,axis=1);tang/=np.maximum(norms,.001)[:,None]
 side=np.cross(ns,tang);side/=np.maximum(np.linalg.norm(side,axis=1),.001)[:,None]
 guide_lengths=length*rng.uniform(.78,1.2,guides)
 # Reduce pile near the skin edge rather than allowing long fibers onto the face.
 if name=='Coat':
  mask=(roots[:,1]<0)&(roots[:,2]>1.10)&(roots[:,2]<1.9)
  for k in np.flatnonzero(mask):
   if abs(roots[k,0])<.405:
    nearest=ob.vertex_groups.get('FurDensity')
    dens=(weights[triangles[ti[k]]]*bc[k]).sum()
    guide_lengths[k]*=.65+.35*dens
 # Each sampled guide carries a coherent tuft with gently converging tips.
 count=guides*children
 pos=np.empty((count,7,3),dtype=np.float32);radii=np.empty((count,7),dtype=np.float32)
 bvh=BVHTree.FromPolygons([tuple(v) for v in vertices],[tuple(t) for t in triangles],all_triangles=True)
 idx=0
 for g in range(guides):
  root=roots[g];n=ns[g];d=tang[g];s=side[g];L=guide_lengths[g]
  for j in range(children):
   angle=rng.uniform(0,2*math.pi);rad=.012*math.sqrt(rng.random())
   offset=(d*math.cos(angle)+s*math.sin(angle))*rad
   co,no,face,dist=bvh.find_nearest(Vector(root+offset))
   p=np.array(co[:]);hn=np.array(no[:])
   if np.dot(hn,n)<0:hn=-hn
   strandL=L*rng.uniform(.80,1.12)
   wave=rng.uniform(-1,1);phase=rng.uniform(0,2*math.pi)
   rootR=rng.uniform(.00018,.00029)
   for step,t in enumerate(np.linspace(0,1,7)):
    # A soft arc, leaning with the groom rather than straight hedgehog spikes.
    lift=strandL*(.77*t-.20*t*t)
    swept=strandL*(.24*t+.53*t*t)
    converge=-offset*(.35*t*t)
    irregular=s*(.0018*wave*math.sin(math.pi*t)+.0008*math.sin(phase+8*t)*t)
    pos[idx,step]=p+n*(lift-.0006)+d*swept+converge+irregular
    radii[idx,step]=rootR*(.92*(1-t)**.7+.08)
   idx+=1
 data=bpy.data.hair_curves.new(name+'PlushCurves');data.add_curves([7]*count)
 data.position_data.foreach_set('vector',pos.ravel())
 radius=data.attributes.new('radius','FLOAT','POINT');radius.data.foreach_set('value',radii.ravel())
 data.set_types(type='CATMULL_ROM')
 data.materials.append(mat)
 fur=bpy.data.objects.new(name+'_PlushGroom',data);bpy.context.collection.objects.link(fur)
 fur['description']='Cream plush, downward curved tufts, varied lengths, tapered fibers'
 print(name,count,'groomed strands')

groom('Coat',18000,24,.041)
groom('Arm_L',2600,24,.037)
groom('Arm_R',2600,24,.037)
groom('Foot_L',1400,22,.030)
groom('Foot_R',1400,22,.030)
# A warm undercoat prevents pale gaps between strands.
base=bpy.data.materials['CoatMat'];bs=next(n for n in base.node_tree.nodes if n.type=='BSDF_PRINCIPLED')
bs.inputs['Base Color'].default_value=(*rgb('DBC6A5'),1)
# Less ambient fill lets the small shadows between the fibers read clearly.
bg=bpy.context.scene.world.node_tree.nodes.get('Background')
if bg:bg.inputs['Strength'].default_value=.38
scene=bpy.context.scene;scene.render.resolution_x=1024;scene.render.resolution_y=1024;scene.cycles.samples=64
bpy.context.view_layer.update()
bpy.ops.wm.save_as_mainfile(filepath='/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/outputs/plush-character/cream-mascot.blend')
bpy.ops.render.render(write_still=True)
print('Plush coat saved and preview rendered')
