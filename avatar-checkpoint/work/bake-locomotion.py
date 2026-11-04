import bpy,math,json,sys
from pathlib import Path
from mathutils import Matrix,Vector
ROOT=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an');sys.path.insert(0,str(ROOT/'work'))
from locomotion_math import smoothstep,two_bone_ik,bone_target_matrix,plan_footsteps,Footstep,FootstepPlan
s=bpy.context.scene;rig=bpy.data.objects['Mascot Rig'];assert Path(bpy.data.filepath).name=='cream-mascot-locomotion.blend'
if rig.animation_data and rig.animation_data.action:rig.animation_data.action.use_fake_user=True;rig.animation_data.action=None
bones=list(rig.pose.bones);rest={p.name:p.bone.matrix_local.copy() for p in bones};heads={p.name:p.bone.head_local.copy() for p in bones};lengths={p.name:p.bone.length for p in bones}
feet={side:heads['Foot.'+side].copy() for side in ['L','R']}
def turn_at(point,axis,angle):return Matrix.Translation(point)@Matrix.Rotation(angle,4,axis)@Matrix.Translation(-point)
def activity(t,d=2.):return smoothstep(t/.14)*smoothstep((d-t)/.20)
labels=['Forward','Backward','Left','Right','Forward left','Forward right','Back left','Back right']
dirs=[(0,-1),(0,1),(-1,0),(1,0),(-1,-1),(1,-1),(-1,1),(1,1)]
segments=[];origin=Vector((0,0,0))
for label,xy in zip(labels,dirs):
 direction=Vector((*xy,0)).normalized();start=origin.copy();end=start+direction*.20
 def path(t,start=start,end=end):return start.lerp(end,smoothstep(t/1.3))
 plan=plan_footsteps(path,1.3,feet,cycle=1.,duty=.62,lift=.016)
 for step in plan.steps:step.lift*=min(1.,(step.end_ankle-step.start_ankle).length/.08)
 assert plan.end_time<2.,(label,plan.end_time)
 segments.append((label,direction,path,plan,start.copy()));origin=end
assert origin.length<1e-6
stairfeet={side:p.copy() for side,p in feet.items()};steps=[]
for side,a,b,y,z in [('R',.15,.85,-.340,.120),('L',1.0,1.70,-.425,.120),('R',2.0,2.70,-.705,.175),('L',2.85,3.55,-.775,.175),('R',3.75,4.25,-.775,.175)]:
 target=Vector((feet[side].x,y,z));steps.append(Footstep(side,a,b,stairfeet[side].copy(),target.copy(),.014,True));stairfeet[side]=target
stairs=FootstepPlan({side:p.copy() for side,p in feet.items()},tuple(steps),0,4.25,6.)
previous={};expected={};stats={'max_ik_reach_error':0.,'minimum_body_crouch':0.,'maximum_bone_scale_error':0.,'stance_frames':0,'clips':labels+['Climb two steps']};perframe=[]
for frame in range(1,529):
 t=(frame-1)/24;isclimb=frame>=385
 if not isclimb:
  idx=(frame-1)//48;local=((frame-1)%48)/24;label,direction,path,plan,start=segments[idx];root=path(local);act=activity(local);phase=2*math.pi*local
  target={side:plan.sample(side,local) for side in ['L','R']};roll=math.radians(1.1)*math.sin(phase)*act;lean=0.;twist=math.radians(.8)*math.sin(phase)*act;crouch=-.010*act-.002*math.sin(phase*2)**2*act
 else:
  local=t-16;label='Climb two steps';direction=Vector((0,-1,0));target={side:stairs.sample(side,local) for side in ['L','R']};left,right=target['L'][0],target['R'][0];gap=min(1.,abs(left.y-right.y)/.370);avg=(left+right)/2;root=Vector((avg.x,avg.y+.035*(1-gap),avg.z-.065));act=activity(local,6.);phase=2*math.pi*local/1.8
  roll=max(-math.radians(8),min(math.radians(8),-math.atan2(right.z-left.z,.48)));lean=math.radians(4)*act;twist=math.radians(.8)*math.sin(phase)*act;crouch=-.008*act
 rootT=Matrix.Translation(root)
 bodyRotation=turn_at(heads['Body'],'Y',roll)@turn_at(heads['Body'],'X',lean)
 body0=rootT@bodyRotation
 # Lower the pelvis to preserve each fixed contact within the short leg's reach.
 ceiling=0.
 for side in ['L','R']:
  H=body0@heads['Leg.'+side];A=target[side][0];reach=lengths['Leg.'+side]+lengths['Shin.'+side]-.0004;hsq=(A.x-H.x)**2+(A.y-H.y)**2
  assert hsq<reach*reach,(frame,side,'Horizontal reach')
  ceiling=min(ceiling,A.z+math.sqrt(reach*reach-hsq)-H.z)
 crouch=min(crouch,ceiling);stats['minimum_body_crouch']=min(stats['minimum_body_crouch'],crouch)
 BT=Matrix.Translation((0,0,crouch))@body0;CT=BT@turn_at(heads['Chest'],'Z',twist);HT=CT@turn_at(heads['Head'],'Y',-roll*.65)@turn_at(heads['Head'],'X',-lean*.5)
 transforms={'Root':rootT,'Body':BT,'Chest':CT,'Head':HT}
 for side,sign in [('L',1),('R',-1)]:
  if isclimb:armangle=-math.radians(12)*act+math.radians(4)*math.sin(phase)*sign*act;armAxis=Vector((1,0,0));foreangle=-math.radians(12)*act
  else:armangle=math.radians(9)*math.sin(phase)*sign*act;armAxis=Vector((direction.y,-direction.x,0));foreangle=-math.radians(3)*abs(math.sin(phase))*act
  AT=CT@turn_at(heads['Arm.'+side],armAxis,armangle);FT=AT@turn_at(heads['Forearm.'+side],'X',foreangle)
  transforms['Arm.'+side]=AT;transforms['Forearm.'+side]=FT;transforms['Hand.'+side]=FT
 desired={name:transform@rest[name] for name,transform in transforms.items()}
 for side in ['L','R']:
  H=BT@heads['Leg.'+side];A=target[side][0];K,error=two_bone_ik(H,A,lengths['Leg.'+side],lengths['Shin.'+side],Vector((0,-1,0)))
  assert error<.0001,(frame,side,error);stats['max_ik_reach_error']=max(stats['max_ik_reach_error'],error)
  desired['Leg.'+side]=bone_target_matrix(rest['Leg.'+side],H,K-H);desired['Shin.'+side]=bone_target_matrix(rest['Shin.'+side],K,A-K)
  M=rest['Foot.'+side].copy();M.translation=A;desired['Foot.'+side]=M
 for pb in bones:
  parent=pb.parent
  base=desired[parent.name]@rest[parent.name].inverted()@rest[pb.name] if parent else rest[pb.name]
  basis=base.inverted()@desired[pb.name];loc,q,scale=basis.decompose();stats['maximum_bone_scale_error']=max(stats['maximum_bone_scale_error'],max(abs(v-1) for v in scale))
  if pb.name in previous and q.dot(previous[pb.name])<0:q.negate()
  previous[pb.name]=q.copy();pb.rotation_mode='QUATERNION';pb.location=loc;pb.rotation_quaternion=q;pb.scale=(1,1,1)
  pb.keyframe_insert('location',frame=frame,group=pb.name);pb.keyframe_insert('rotation_quaternion',frame=frame,group=pb.name)
 h=rig.pose.bones['Head'];blink=0.
 for center in [1.5,4.7,7.5,10.3,13.6,15.4,18.0,21.1]:
  d=abs(t-center)
  if d<.13:blink=max(blink,math.cos(d/.13*math.pi/2)**2)
 for prop,val in [('Blink',blink),('Blink Left',0.),('Blink Right',0.),('Smile',.12+.14*float(isclimb)*smoothstep((local-4.25)/.7))]:h[prop]=float(val);h.keyframe_insert(data_path='["'+prop+'"]',frame=frame,group='Face')
 expected[frame]={side:{'ankle':list(target[side][0]),'stance':target[side][1]} for side in ['L','R']};perframe.append({'frame':frame,'clip':label,'root':list(root),'crouch':crouch})
act=rig.animation_data.action;act.name='Showcase - eight directions and stair climb';act.use_fake_user=True
for layer in act.layers:
 for strip in layer.strips:
  for bag in strip.channelbags:
   for fc in bag.fcurves:
    for k in fc.keyframe_points:k.interpolation='LINEAR'
for marker in list(s.timeline_markers):s.timeline_markers.remove(marker)
for i,label in enumerate(labels):s.timeline_markers.new(label,frame=1+i*48)
s.timeline_markers.new('Climb two steps',frame=385)
# Validate evaluated, baked bone positions against the fixed targets.
maxerr=0.;maxstance=0.
for frame in range(1,529):
 s.frame_set(frame)
 for side in ['L','R']:
  target=Vector(expected[frame][side]['ankle']);actual=rig.pose.bones['Foot.'+side].head;err=(actual-target).length;maxerr=max(maxerr,err)
  if expected[frame][side]['stance']:maxstance=max(maxstance,err);stats['stance_frames']+=1
assert maxerr<.00005,('Baked ankle error',maxerr)
stats['maximum_baked_ankle_error']=maxerr;stats['maximum_stance_contact_error']=maxstance;stats['frames']=528;stats['fps']=24;stats['duration_seconds']=22
(ROOT/'work/locomotion/animation-validation.json').write_text(json.dumps(stats,indent=2));(ROOT/'work/locomotion/targets.json').write_text(json.dumps({'frames':expected,'motion':perframe}))
# Match scene visibility in the desktop viewport as well as the movie.
for ob in bpy.data.collections['Locomotion stage'].objects:
 if ob.animation_data and ob.animation_data.action:
  for layer in ob.animation_data.action.layers:
   for strip in layer.strips:
    for bag in strip.channelbags:
     for fc in list(bag.fcurves):
      if fc.data_path=='hide_render':
       values=[(int(k.co.x),bool(round(k.co.y))) for k in fc.keyframe_points]
       for f,hidden in values:ob.hide_viewport=hidden;ob.keyframe_insert('hide_viewport',frame=f)
for area in bpy.context.screen.areas:
 if area.type=='VIEW_3D':area.spaces.active.region_3d.view_perspective='CAMERA'
rig.update_tag(refresh={'OBJECT','DATA','TIME'});s.frame_set(1);bpy.context.view_layer.update()
text=bpy.data.texts.get('LOCOMOTION - playback guide') or bpy.data.texts.new('LOCOMOTION - playback guide');text.clear();text.write('Eight-direction planted-foot locomotion and two shallow stair steps.\n24 fps, frames 1-528 (22 seconds).\n1-48 Forward;49-96 Backward;97-144 Left;145-192 Right;193-240 Forward left;241-288 Forward right;289-336 Back left;337-384 Back right;385-528 Climb.\nBaked native bone animation; facial shape key drivers retained. The plush grooming uses Blender surface curves; a separate fur conversion is still needed for a native-app runtime asset.\nOriginal visual master, rig master and prior showcase are preserved as separate files.\n')
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'outputs/plush-character/cream-mascot-locomotion.blend'))
print(json.dumps(stats))
