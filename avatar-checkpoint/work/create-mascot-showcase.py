import bpy,math,json
from pathlib import Path
from mathutils import Vector,Euler
root=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an');out=root/'outputs/plush-character';s=bpy.context.scene;r=bpy.data.objects['Mascot Rig']
if bpy.context.screen and bpy.context.screen.is_animation_playing:bpy.ops.screen.animation_cancel(restore_frame=False)
assert Path(bpy.data.filepath).name=='cream-mascot-rigged.blend','Keep source and showcase versions separate.'
old=r.animation_data.action;old.use_fake_user=True;r.animation_data.action=None
s.frame_set(1);s.frame_start=1;s.frame_end=360;s.render.fps=24;s.render.fps_base=1
rest={pb.name:pb.bone.matrix_local.to_3x3().copy() for pb in r.pose.bones}
head=r.pose.bones['Head']
for prop in ['Blink','Blink Left','Blink Right','Smile']:head[prop]=0.0
r.update_tag(refresh={'OBJECT','DATA','TIME'});bpy.context.view_layer.update()
def smooth(x):
 x=max(0.,min(1.,x));return x*x*(3-2*x)
def win(t,a,b,ramp=.25):return smooth((t-a)/ramp)*(1-smooth((t-(b-ramp))/ramp))
def rot(name,xyz):
 R=Euler(tuple(math.radians(v) for v in xyz),'XYZ').to_matrix();r.pose.bones[name].rotation_euler=(rest[name].inverted()@R@rest[name]).to_euler('XYZ')
def move(name,xyz):r.pose.bones[name].location=rest[name].inverted()@Vector(xyz)
for f in range(1,361):
 t=(f-1)/24.
 angles={name:[0.,0.,0.] for name in rest}
 for pb in r.pose.bones:pb.location=(0,0,0);pb.scale=(1,1,1)
 blink=win(t,.45,.82,.12)+win(t,14.35,14.70,.12)
 smile=.10
 look=win(t,.75,2.05,.20);angles['Head'][2]+=10*math.sin((t-.75)/1.3*math.tau)*look
 bow=win(t,2.05,2.95,.3);angles['Chest'][0]+=6*bow;angles['Body'][2]-=3*bow;angles['Head'][0]-=2*bow
 for side,sign,a,b in [('R',-1,3.,5.),('L',1,5.,7.)]:
  w=win(t,a,b,.35);angles['Arm.'+side][1]+=sign*55*w;angles['Forearm.'+side][1]+=sign*100*w
  angles['Hand.'+side][1]+=sign*14*math.sin((t-a-.35)*math.tau*2)*w
  angles['Head'][2]+=sign*6*w;smile+=.50*w
 shift=0.
 for side,a,b in [('L',7.05,7.65),('R',7.75,8.35),('L',8.45,9.05),('R',9.15,9.75)]:
  if a<=t<=b:
   u=(t-a)/(b-a);lift=math.sin(math.pi*u)**2
   angles['Leg.'+side][0]-=10*lift;angles['Shin.'+side][0]+=18*lift;angles['Foot.'+side][0]-=8*lift
   other='R' if side=='L' else 'L';angles['Arm.'+other][0]+=8*lift;angles['Arm.'+side][0]-=6*lift
   shift=(.012 if side=='L' else -.012)*lift
 leftwink=win(t,10.15,10.65,.16);rightwink=win(t,11.10,11.60,.16)
 smile=max(smile,.8*win(t,10.,12.,.3))
 turn=18*math.sin((t-12)*math.pi)*win(t,12.,14.,.2);angles['Root'][2]+=turn;angles['Head'][2]-=turn*.22
 turnx=.045*math.sin((t-12)*math.pi)*win(t,12.,14.,.2)
 bounce=0.
 if 14.05<=t<=14.85:bounce=.026*math.sin(math.pi*(t-14.05)/.8)**2
 smile=max(smile,.85*smooth((t-12.)/.5))
 for name,xyz in angles.items():rot(name,xyz)
 move('Root',(shift+turnx,0,0));move('Body',(0,0,bounce))
 for pb in r.pose.bones:
  pb.keyframe_insert('rotation_euler',frame=f,group=pb.name)
  if pb.name in ['Root','Body']:pb.keyframe_insert('location',frame=f,group=pb.name)
 for prop,value in [('Blink',blink),('Blink Left',leftwink),('Blink Right',rightwink),('Smile',min(1.,smile))]:
  head[prop]=float(value);head.keyframe_insert(data_path='["'+prop+'"]',frame=f,group='Face expressions')
a=r.animation_data.action;a.name='Mascot showcase - all free rig controls'
for layer in a.layers:
 for strip in layer.strips:
  for bag in strip.channelbags:
   for fc in bag.fcurves:
    for k in fc.keyframe_points:k.interpolation='LINEAR'
for mark in list(s.timeline_markers):s.timeline_markers.remove(mark)
for f,name in [(1,'Hello / blink'),(19,'Look around'),(50,'Bow'),(73,'Right wave'),(121,'Left wave'),(169,'Little steps'),(241,'Winks and smile'),(289,'Turn around'),(337,'Happy bounce')]:s.timeline_markers.new(name,frame=f)
s.render.engine='CYCLES';s.cycles.device='GPU';s.cycles.samples=16;s.cycles.use_adaptive_sampling=True;s.cycles.adaptive_threshold=.065;s.cycles.adaptive_min_samples=4;s.cycles.use_denoising=True;s.cycles.denoiser='OPENIMAGEDENOISE';s.cycles.denoising_use_gpu=True
s.cycles.max_bounces=6;s.cycles.diffuse_bounces=2;s.cycles.glossy_bounces=3;s.cycles.transmission_bounces=3;s.cycles.transparent_max_bounces=6
s.render.use_persistent_data=True;s.render.resolution_x=1080;s.render.resolution_y=1080;s.render.resolution_percentage=100;s.render.image_settings.file_format='PNG';s.render.image_settings.color_mode='RGB';s.render.image_settings.color_depth='8';s.render.image_settings.compression=15
s.camera=bpy.data.objects['Cam_3Q'];s.camera.location=(.10,-4,1.16);s.camera.rotation_euler=(Vector((0,0,.99))-s.camera.location).to_track_quat('-Z','Y').to_euler();s.camera.data.type='ORTHO';s.camera.data.ortho_scale=2.72
s.render.filepath=str(root/'work/showcase/frames/frame_');(root/'work/showcase/frames').mkdir(parents=True,exist_ok=True)
r.update_tag(refresh={'OBJECT','DATA','TIME'})
for n in ['Eye_L','Eye_R','Glint_L','Glint_R','Mouth']:
 k=bpy.data.objects[n].data.shape_keys;k.update_tag()
 for fc in k.animation_data.drivers:fc.driver.expression=fc.driver.expression.strip()+' '
s.frame_set(96);bpy.context.view_layer.update()
# Hide the cheek decals in solid view only; render visibility remains on.
for n in ['Blush_L','Blush_R']:bpy.data.objects[n].hide_render=False
bpy.ops.wm.save_as_mainfile(filepath=str(out/'cream-mascot-showcase.blend'))
manifest={'file':bpy.data.filepath,'frames':360,'fps':24,'duration_seconds':15,'size':[1080,1080],'samples':16,'device':'Metal GPU','action':a.name}
(root/'work/showcase/manifest.json').write_text(json.dumps(manifest,indent=2));print(json.dumps(manifest))
