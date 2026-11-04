import bpy,math,json,numpy as np
from mathutils import Matrix,Vector
from pathlib import Path
root=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an');scene=bpy.context.scene;rig=bpy.data.objects['Mascot Rig']
assert rig.animation_data is None or rig.animation_data.action is None or rig.animation_data.action.name=='Rig check - wave and small step','Inspect existing animation before adding pose checks.'
def setrot(name,axis,degrees):
 pb=rig.pose.bones[name];rest=pb.bone.matrix_local.to_3x3();R=Matrix.Rotation(math.radians(degrees),3,axis);pb.rotation_euler=(rest.inverted()@R@rest).to_euler('XYZ')
def reset():
 for pb in rig.pose.bones:pb.rotation_euler=(0,0,0);pb.location=(0,0,0);pb.scale=(1,1,1)
def key(frame):
 for pb in rig.pose.bones:
  pb.keyframe_insert('rotation_euler',frame=frame,group=pb.name)
  if pb.name=='Body':pb.keyframe_insert('location',frame=frame,group=pb.name)
reset();key(1)
setrot('Head','Z',-10);setrot('Arm.R','Y',-55);setrot('Forearm.R','Y',-100);setrot('Hand.R','Y',-12);key(28)
setrot('Hand.R','Y',12);key(38)
reset();key(60)
setrot('Leg.L','X',-17);setrot('Shin.L','X',30);setrot('Foot.L','X',-13);setrot('Head','Z',8);setrot('Arm.L','X',12);key(86)
reset();key(120)
rig.animation_data.action.name='Rig check - wave and small step'
if not scene.timeline_markers:
 for frame,label in [(1,'REST'),(28,'WAVE'),(38,'WAVE RETURN'),(60,'REST'),(86,'SMALL STEP'),(120,'REST')]:scene.timeline_markers.new(label,frame=frame)
# Confirm each character vertex has normalized skin weights.
names={b.name for b in rig.data.bones if b.use_deform};weight_errors={}
for ob in scene.objects:
 if ob.type!='MESH' or not any(m.type=='ARMATURE' and m.object==rig for m in ob.modifiers):continue
 gids={g.index for g in ob.vertex_groups if g.name in names}
 sums=np.array([sum(g.weight for g in v.groups if g.group in gids) for v in ob.data.vertices]);weight_errors[ob.name]=float(np.abs(sums-1).max())
assert max(weight_errors.values())<.00021,'Some skin weights are unnormalized.'
# Check a visible raised arm and a lifted foot, and all roots following the skin.
checks={}
for frame in [1,28,86,120]:
 scene.frame_set(frame);bpy.context.view_layer.update();deps=bpy.context.evaluated_depsgraph_get()
 entry={}
 for n in ['Arm_R','Coat','Face']:
  ob=bpy.data.objects[n];ev=ob.evaluated_get(deps);me=ev.to_mesh();p=np.empty(len(me.vertices)*3,np.float32);me.vertices.foreach_get('co',p);p=p.reshape(-1,3);entry[n]={'min':p.min(0).tolist(),'max':p.max(0).tolist()};ev.to_mesh_clear()
 if frame in [1,120]:
  baseline=np.load(root/'work/rig-neutral-meshes.npz')
  errors=[]
  for n in baseline.files:
   ob=bpy.data.objects[n];ev=ob.evaluated_get(deps);me=ev.to_mesh();p=np.empty(len(me.vertices)*3,np.float32);me.vertices.foreach_get('co',p);errors.append(float(np.max(np.abs(p-baseline[n]))));ev.to_mesh_clear()
  entry['rest_mesh_error_max']=max(errors);assert max(errors)<.00001,'Neutral pose does not return exactly.'
 checks[str(frame)]=entry
scene.frame_set(28);bpy.context.view_layer.update()
# Leave the rig selected for visible posing. Bone controls remain in front of the model.
if bpy.context.object and bpy.context.object.mode!='OBJECT':bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.object.select_all(action='DESELECT');rig.select_set(True);bpy.context.view_layer.objects.active=rig
bpy.ops.object.mode_set(mode='POSE')
for pb in rig.pose.bones:pb.select=False
rig.pose.bones['Arm.R'].select=True;rig.data.bones.active=rig.data.bones['Arm.R']
for screen in bpy.data.screens:
 for area in screen.areas:
  if area.type=='VIEW_3D':
   sp=area.spaces.active;sp.overlay.show_overlays=True;sp.overlay.show_floor=False;sp.overlay.show_axis_x=False;sp.overlay.show_axis_y=False
   sp.shading.type='SOLID';sp.shading.color_type='MATERIAL';sp.region_3d.view_location=Vector((0,0,1.0));sp.region_3d.view_distance=3.2
scene.render.resolution_x=1000;scene.render.resolution_y=1000;scene.cycles.samples=48;scene.render.filepath=str(root/'outputs/plush-character/rig-wave-preview.png')
(root/'work/rig-pose-checks.json').write_text(json.dumps({'weight_errors':weight_errors,'poses':checks},indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(root/'outputs/plush-character/cream-mascot-rigged.blend'))
print(json.dumps({'weights_max_error':max(weight_errors.values()),'poses':checks,'action':rig.animation_data.action.name}))
bpy.ops.render.render(write_still=True)
print('Rigged wave preview rendered.')
