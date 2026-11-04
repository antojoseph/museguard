import bpy,math,json
from mathutils import Vector
from pathlib import Path
ROOT=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an');OUT=ROOT/'outputs/plush-character';s=bpy.context.scene;rig=bpy.data.objects['Mascot Rig']
assert Path(bpy.data.filepath).name=='cream-mascot-showcase.blend'
if bpy.context.screen and bpy.context.screen.is_animation_playing:bpy.ops.screen.animation_cancel(restore_frame=False)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'cream-mascot-locomotion.blend'))
if rig.animation_data and rig.animation_data.action:rig.animation_data.action.use_fake_user=True;rig.animation_data.action=None
if bpy.context.object and bpy.context.object.mode!='OBJECT':bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.object.select_all(action='DESELECT');rig.select_set(True);bpy.context.view_layer.objects.active=rig
# Put the tiny knees into a shallow forward rest bend, without changing any mesh.
bpy.ops.object.mode_set(mode='EDIT')
for side in ['L','R']:
 leg=rig.data.edit_bones['Leg.'+side];shin=rig.data.edit_bones['Shin.'+side];H=leg.head.copy();A=shin.tail.copy();u=(A-H).normalized();pole=Vector((0,-1,0));p=(pole-u*pole.dot(u)).normalized();K=H+(A-H)*.595+p*.0092;leg.tail=K;shin.head=K
bpy.ops.object.mode_set(mode='OBJECT')
for pb in rig.pose.bones:pb.rotation_mode='QUATERNION';pb.rotation_quaternion=(1,0,0,0);pb.location=(0,0,0);pb.scale=(1,1,1)
for prop in ['Blink','Blink Left','Blink Right','Smile']:rig.pose.bones['Head'][prop]=0.0
rig.update_tag(refresh={'OBJECT','DATA','TIME'});bpy.context.view_layer.update()
exec(compile((ROOT/'work/refine-locomotion-weights.py').read_text(),'weights','exec'),globals())
report=refine_leg_weights(rig);(ROOT/'work/locomotion').mkdir(exist_ok=True);(ROOT/'work/locomotion/weight-refinement.json').write_text(json.dumps(report,indent=2))
# The walking floor meets the existing flat soles exactly.
bpy.data.objects['Ground'].location.z=.013
stage=bpy.data.collections.new('Locomotion stage');s.collection.children.link(stage)
mat=bpy.data.materials.new('Soft slate climbing steps');mat.use_nodes=True;bs=next(n for n in mat.node_tree.nodes if n.type=='BSDF_PRINCIPLED');bs.inputs['Base Color'].default_value=(.34,.43,.51,1);bs.inputs['Roughness'].default_value=.72;mat.diffuse_color=(.34,.43,.51,1)
for index,(front,back,bottom,top) in enumerate([(-.23,-1.13,.013,.068),(-.60,-1.13,.068,.123)],1):
 bpy.ops.mesh.primitive_cube_add(size=1,location=(0,(front+back)/2,(bottom+top)/2));ob=bpy.context.object;ob.name='Climbing step '+str(index);ob.dimensions=(1.6,front-back,top-bottom);bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
 for c in list(ob.users_collection):c.objects.unlink(ob)
 stage.objects.link(ob);ob.data.materials.append(mat);be=ob.modifiers.new('Soft step edges','BEVEL');be.width=.008;be.segments=3
 for frame,hidden in [(1,True),(384,True),(385,False),(528,False)]:ob.hide_render=hidden;ob.keyframe_insert('hide_render',frame=frame)
 ob['Purpose']='Two shallow physical treads, each 5.5cm high, for the climb animation.'
cam=bpy.data.objects['Cam_3Q'].copy();cam.data=cam.data.copy();cam.name='Locomotion Camera';s.collection.objects.link(cam);cam.location=(3.2,-6.3,3.1);cam.rotation_euler=(Vector((0,-.32,.96))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.type='ORTHO';cam.data.ortho_scale=3.15;s.camera=cam
captionmat=bpy.data.materials.new('Quiet charcoal captions');captionmat.use_nodes=True;captionmat.node_tree.nodes.clear();emit=captionmat.node_tree.nodes.new('ShaderNodeEmission');emit.inputs['Color'].default_value=(.055,.07,.08,1);emit.inputs['Strength'].default_value=1.;out=captionmat.node_tree.nodes.new('ShaderNodeOutputMaterial');captionmat.node_tree.links.new(emit.outputs[0],out.inputs['Surface'])
labels=['Forward','Backward','Left','Right','Forward left','Forward right','Back left','Back right','Climb']
for i,label in enumerate(labels):
 cu=bpy.data.curves.new(label+' caption','FONT');cu.body=label;cu.align_x='CENTER';cu.size=.085;ob=bpy.data.objects.new(label+' caption',cu);stage.objects.link(ob);ob.parent=cam;ob.location=(0,1.28,-5);cu.materials.append(captionmat)
 a=1+i*48 if i<8 else 385;b=(i+1)*48 if i<8 else 528
 for f,hidden in [(0,True),(a,False),(b,False),(b+1,True)]:ob.hide_render=hidden;ob.keyframe_insert('hide_render',frame=f)
# Render the same plush material and lighting as the approved avatar.
s.frame_start=1;s.frame_end=528;s.render.fps=24;s.render.fps_base=1;s.render.resolution_x=1080;s.render.resolution_y=1080;s.render.resolution_percentage=100;s.render.engine='CYCLES';s.cycles.device='GPU';s.cycles.samples=16;s.render.use_persistent_data=True;s.render.image_settings.media_type='IMAGE';s.render.image_settings.file_format='PNG';s.render.image_settings.color_mode='RGB';s.render.image_settings.color_depth='8';s.render.image_settings.compression=15
rig['Locomotion']='Baked planted-foot walking in eight directions plus two-step climbing. Original visual and rig masters remain separate.'
bpy.ops.object.select_all(action='DESELECT');rig.select_set(True);bpy.context.view_layer.objects.active=rig
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'cream-mascot-locomotion.blend'))
print(json.dumps({'saved':bpy.data.filepath,'weights':report,'stage':'Two 5.5cm steps','next':'Bake and validate planted-foot targets.'}))
