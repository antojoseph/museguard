import bpy,math,json,numpy as np
from pathlib import Path
from mathutils import Vector
ROOT=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an')
OUT=ROOT/'outputs/plush-character'
assert not bpy.data.objects.get('Mascot Rig'),'A rig already exists; inspect it before rebuilding.'
assert bpy.data.objects.get('Coat') and len(bpy.data.objects['Coat'].data.vertices)==84257,'Unexpected avatar topology.'
assert bpy.data.filepath==str(OUT/'cream-mascot.blend'),'The approved master must be open before making the rigged copy.'
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'cream-mascot-rigged.blend'))
# Everything below changes only the separate rigged project.
collection=bpy.data.collections.new('Mascot Rig Controls');bpy.context.scene.collection.children.link(collection)
arm=bpy.data.armatures.new('Cream Mascot Skeleton');rig=bpy.data.objects.new('Mascot Rig',arm);collection.objects.link(rig)
rig.show_in_front=True;arm.display_type='STICK';rig['Rig type']='Free native Blender custom rig';rig['Instructions']='Select Mascot Rig, enter Pose Mode, and rotate the named controls. Alt-R and Alt-G reset selected controls. Rest frame 1; pose examples are on the timeline.'
bpy.ops.object.select_all(action='DESELECT');rig.select_set(True);bpy.context.view_layer.objects.active=rig;bpy.ops.object.mode_set(mode='EDIT')
bones={}
def bone(name,head,tail,parent=None,deform=True):
 b=arm.edit_bones.new(name);b.head=head;b.tail=tail;b.use_deform=deform
 if parent:b.parent=bones[parent]
 bones[name]=b;return b
bone('Root',(0,0,.013),(0,0,.22),deform=False)
bone('Body',(0,0,.43),(0,0,.73),'Root')
bone('Chest',(0,0,.73),(0,0,1.12),'Body')
bone('Head',(0,0,1.12),(0,0,1.88),'Chest')
for side,sign in [('L',-1),('R',1)]:
 bone('Arm.'+side,(sign*.445,.015,1.18),(sign*.665,-.045,.85),'Chest')
 bone('Forearm.'+side,(sign*.665,-.045,.85),(sign*.720,-.135,.43),'Arm.'+side)
 bone('Hand.'+side,(sign*.720,-.135,.43),(sign*.712,-.160,.365),'Forearm.'+side)
 bone('Leg.'+side,(sign*.240,0,.45),(sign*.250,-.015,.22),'Body')
 bone('Shin.'+side,(sign*.250,-.015,.22),(sign*.250,-.035,.065),'Leg.'+side)
 bone('Foot.'+side,(sign*.250,-.035,.065),(sign*.250,-.180,.055),'Shin.'+side)
bpy.ops.object.mode_set(mode='OBJECT')
for pb in rig.pose.bones:
 pb.rotation_mode='XYZ';pb.lock_location=(True,True,True);pb.lock_scale=(True,True,True)
 if pb.name in ['Root','Body']:pb.lock_location=(False,False,False)
 if pb.name=='Root':pb.lock_scale=(False,False,False)
 pb.bone.color.palette='THEME03' if pb.name.endswith('.L') else 'THEME04' if pb.name.endswith('.R') else 'THEME02'
# Preserve groom-density groups and all geometry; add only deform weights.
def smooth(a,b,x):
 t=np.clip((x-a)/(b-a),0,1);return t*t*(3-2*t)
def meshcoords(ob):
 p=np.empty(len(ob.data.vertices)*3,np.float32);ob.data.vertices.foreach_get('co',p);return p.reshape(-1,3)
def applyweights(ob,weights):
 for name,w in weights.items():
  vg=ob.vertex_groups.get(name) or ob.vertex_groups.new(name=name)
  # Bucketing gives exact-enough smooth skinning without hundreds of thousands of API calls.
  q=np.rint(np.asarray(w)*10000).astype(np.int32)
  order=np.argsort(q);split=np.flatnonzero(np.diff(q[order]))+1
  for inds in np.split(order,split):
   val=int(q[inds[0]])
   if val>0:vg.add(inds.tolist(),val/10000.,'REPLACE')
 m=ob.modifiers.new('Mascot skeleton','ARMATURE');m.object=rig;m.use_deform_preserve_volume=False
 while ob.modifiers.find(m.name)>0:
  bpy.context.view_layer.objects.active=ob;bpy.ops.object.modifier_move_up(modifier=m.name)
 ob['Rig binding']='Custom smooth weights; free native Blender armature'
 return m
coat=bpy.data.objects['Coat'];p=meshcoords(coat);x=p[:,0];z=p[:,2]
head=smooth(1.02,1.23,z);chest=(1-head)*smooth(.62,1.00,z)
leg=(1-smooth(.32,.62,z))*smooth(.008,.070,np.abs(x));leg=np.where(z<.11,1.,leg)
central=1-head-chest
w={'Head':head,'Chest':chest,'Body':central*(1-leg)}
foot=1-smooth(.045,.13,z);thigh=smooth(.15,.30,z)
for side,sign in [('L',-1),('R',1)]:
 sidew=(x<0).astype(float) if sign<0 else (x>=0).astype(float)
 strength=central*leg*sidew
 w['Leg.'+side]=strength*thigh
 w['Shin.'+side]=strength*(1-thigh)*(1-foot)
 w['Foot.'+side]=strength*(1-thigh)*foot
applyweights(coat,w)
for side in ['L','R']:
 ob=bpy.data.objects['Arm_'+side];assert len(ob.data.vertices)==64*48
 t=np.repeat(np.linspace(0,1,64),48)
 shoulder=1-smooth(.025,.15,t);fore=smooth(.34,.66,t);hand=smooth(.86,1.,t)
 w={'Chest':shoulder,'Arm.'+side:(1-shoulder)*(1-fore),'Forearm.'+side:(1-shoulder)*fore*(1-hand),'Hand.'+side:(1-shoulder)*fore*hand}
 applyweights(ob,w)
for name in ['Face','Eye_L','Eye_R','Glint_L','Glint_R','Blush_L','Blush_R']:
 ob=bpy.data.objects[name];applyweights(ob,{'Head':np.ones(len(ob.data.vertices))})
# The smile is a legacy curve: use rigid bone parenting, preserving its world transform.
mouth=bpy.data.objects['Mouth'];world=mouth.matrix_world.copy();mouth.parent=rig;mouth.parent_type='BONE';mouth.parent_bone='Head';bpy.context.view_layer.update();mouth.matrix_world=world
# Free, simple visible control shapes, kept in a hidden helper collection.
shapes=bpy.data.collections.new('Rig Shapes - hidden helpers');bpy.context.scene.collection.children.link(shapes);shapes.hide_render=True
verts=[(math.cos(i*math.tau/48),0,math.sin(i*math.tau/48)) for i in range(48)];edges=[(i,(i+1)%48) for i in range(48)]
me=bpy.data.meshes.new('Circular rig control');me.from_pydata(verts,edges,[]);me.update();circle=bpy.data.objects.new('Rig circular control',me);shapes.objects.link(circle);circle.hide_render=True;circle.hide_set(True)
for pb in rig.pose.bones:
 pb.custom_shape=circle;pb.use_custom_shape_bone_size=False
 scale=.28 if pb.name=='Root' else .18 if pb.name in ['Body','Chest','Head'] else .09 if pb.name.startswith(('Arm.','Leg.','Foot.')) else .065
 pb.custom_shape_scale_xyz=(scale,scale,scale)
# Record neutral mesh reference for the quantitative pose/rest checks.
refs={}
deps=bpy.context.evaluated_depsgraph_get()
for name in ['Coat','Face','Arm_L','Arm_R','Eye_L','Eye_R','Blush_L','Blush_R']:
 ob=bpy.data.objects[name];ev=ob.evaluated_get(deps);mesh=ev.to_mesh();arr=np.empty(len(mesh.vertices)*3,np.float32);mesh.vertices.foreach_get('co',arr);refs[name]=arr;ev.to_mesh_clear()
np.savez_compressed(ROOT/'work/rig-neutral-meshes.npz',**refs)
scene=bpy.context.scene;scene.frame_start=1;scene.frame_end=120;scene.render.fps=30;scene.frame_set(1)
rig['Controls']='Root: move/turn whole avatar | Body: lean/bounce | Chest: upper-body bend | Head: look around | Arm/Forearm/Hand: wave | Leg/Shin/Foot: small steps'
bpy.context.view_layer.objects.active=rig;bpy.ops.object.select_all(action='DESELECT');rig.select_set(True)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'cream-mascot-rigged.blend'))
print(json.dumps({'rig':rig.name,'bones':len(arm.bones),'file':bpy.data.filepath,'bound_meshes':len(refs),'next':'Bind strand fur before posing.'}))
