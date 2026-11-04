import bpy,math,json,numpy as np
from pathlib import Path
root=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an');scene=bpy.context.scene;rig=bpy.data.objects['Mascot Rig'];head=rig.pose.bones['Head']
scene.frame_set(1)
for prop,label in [('Blink','Both eyes'),('Blink Left','Left eye wink'),('Blink Right','Right eye wink'),('Smile','Smile amount')]:
 head[prop]=0.;head.id_properties_ui(prop).update(min=0.,max=1.,soft_min=0.,soft_max=1.,description=label)
def drive(key,side=None,prop='Blink'):
 d=key.driver_add('value').driver;d.type='SCRIPTED'
 var=d.variables.new();var.name='amount';var.type='SINGLE_PROP';var.targets[0].id=rig;var.targets[0].data_path='pose.bones["Head"]["'+prop+'"]'
 if side:
  var=d.variables.new();var.name='wink';var.type='SINGLE_PROP';var.targets[0].id=rig;var.targets[0].data_path='pose.bones["Head"]["Blink '+('Left' if side=='L' else 'Right')+'"]';d.expression='max(amount,wink)'
 else:d.expression='amount'
for side in ['L','R']:
 ob=bpy.data.objects['Eye_'+side]
 assert ob.data.shape_keys is None,'Inspect existing expressions before adding another set.'
 ob.shape_key_add(name='Basis');key=ob.shape_key_add(name='Blink')
 for v in key.data:
  x,y,z=v.co;v.co=(x,y*.30,.26*(1-x*x)+z*.045)
 drive(key,side)
 gl=bpy.data.objects['Glint_'+side];gl.shape_key_add(name='Basis');gkey=gl.shape_key_add(name='Blink')
 for v in gkey.data:v.co=(0,0,0)
 drive(gkey,side)
mouth=bpy.data.objects['Mouth'];mouth.shape_key_add(name='Basis');smile=mouth.shape_key_add(name='Smile')
for v in smile.data:
 u=min(1,abs(v.co.x)/.060);v.co.z+=.009*u*u-.002*(1-u*u)
drive(smile,prop='Smile')
for prop,keys in [('Blink',[(1,0),(12,0),(16,1),(20,0),(72,0),(76,1),(80,0),(120,0)]),('Smile',[(1,0),(20,0),(28,.65),(38,.65),(60,0),(120,0)])]:
 for frame,value in keys:head[prop]=value;head.keyframe_insert(data_path='["'+prop+'"]',frame=frame,group='Face expressions')
# Lighten the interactive viewport only. Full-density render geometry is preserved.
G='Mascot Fur - responsive viewport'
group=bpy.data.node_groups.get(G)
if group is None:
 group=bpy.data.node_groups.new(G,'GeometryNodeTree')
 group.interface.new_socket(name='Geometry',in_out='INPUT',socket_type='NodeSocketGeometry');group.interface.new_socket(name='Geometry',in_out='OUTPUT',socket_type='NodeSocketGeometry')
 density=group.interface.new_socket(name='Viewport Fur Density',in_out='INPUT',socket_type='NodeSocketFloat');density.default_value=.22;density.min_value=.01;density.max_value=1.
 n=group.nodes;l=group.links;src=n.new('NodeGroupInput');src.location=(-850,150)
 ident=n.new('GeometryNodeInputIndex');ident.location=(-850,-100)
 setid=n.new('GeometryNodeStoreNamedAttribute');setid.data_type='INT';setid.domain='CURVE';setid.inputs['Name'].default_value='id';setid.location=(-650,150);l.new(src.outputs['Geometry'],setid.inputs['Geometry']);l.new(ident.outputs['Index'],setid.inputs['Value'])
 random=n.new('FunctionNodeRandomValue');random.data_type='FLOAT';random.location=(-650,-200)
 for sock in random.inputs:
  if sock.name=='Min' and sock.type=='VALUE':sock.default_value=0.
  if sock.name=='Max' and sock.type=='VALUE':sock.default_value=1.
 l.new(ident.outputs['Index'],random.inputs['ID'])
 greater=n.new('ShaderNodeMath');greater.operation='GREATER_THAN';greater.location=(-400,-120)
 l.new(next(s for s in random.outputs if s.name=='Value' and s.type=='VALUE'),greater.inputs[0]);l.new(src.outputs['Viewport Fur Density'],greater.inputs[1])
 viewport=n.new('GeometryNodeIsViewport');viewport.location=(-400,-350)
 both=n.new('FunctionNodeBooleanMath');both.operation='AND';both.location=(-180,-120);l.new(greater.outputs[0],both.inputs[0]);l.new(viewport.outputs[0],both.inputs[1])
 delete=n.new('GeometryNodeDeleteGeometry');delete.domain='CURVE';delete.location=(20,150);l.new(setid.outputs['Geometry'],delete.inputs['Geometry']);l.new(both.outputs[0],delete.inputs['Selection'])
 deform=n.new('GeometryNodeDeformCurvesOnSurface');deform.location=(230,150);l.new(delete.outputs['Geometry'],deform.inputs['Curves'])
 out=n.new('NodeGroupOutput');out.location=(460,150);l.new(deform.outputs['Curves'],out.inputs['Geometry'])
for ob in scene.objects:
 if ob.type=='CURVES':
  mod=ob.modifiers.get('Follow Mascot Skin');assert mod
  mod.node_group=group
scene.sync_mode='FRAME_DROP'
text=bpy.data.texts.get('START HERE - Mascot Rig') or bpy.data.texts.new('START HERE - Mascot Rig');text.clear();text.write('''CREAM MASCOT — FREE BLENDER RIG\n\nThis file is a rigged copy of the approved mascot. The original cream-mascot.blend is separate. No paid add-ons are required.\n\nPLAY THE TEST\nPress Space with the pointer over the viewport or timeline. Frames 1 and 120 are neutral, 16 is a blink, 28–38 are the wave, and 86 is a small step.\n\nPOSE THE CHARACTER\nSelect Mascot Rig and enter Pose Mode. The visible circles are controls. Rotate Head, Chest, Arm/Forearm/Hand or Leg/Shin/Foot. Body moves the torso; Root moves the whole avatar. Use small steps for this character's short legs. Alt-R and Alt-G clear a selected control's rotation and location.\n\nFACE\nSelect Head, then find its Custom Properties in the bone properties or Item panel. Blink closes both eyes; Blink Left and Blink Right make winks; Smile deepens the smile. Values run from 0 to 1.\n\nFUR\nAll nine groom layers follow the skin. Viewport Fur Density defaults to 22% for easier posing; renders keep full strand density. The hidden Coat_FurBindingSurface is required—do not delete it.\n\nMAC APP\nThis is the detailed animation master. An optimized mesh/fur representation and USDZ export still need a separate RealityKit validation pass.\n''')
rig['Instructions']='See Blender text: START HERE - Mascot Rig. Space plays pose test; frames 1/120 rest, 16 blink, 28 wave, 86 small step.'
scene.frame_set(16);bpy.context.view_layer.update()
assert bpy.data.objects['Eye_L'].data.shape_keys.key_blocks['Blink'].value>.99,'Blink driver not updating.'
scene.frame_set(1);bpy.context.view_layer.update()
assert bpy.data.objects['Eye_L'].data.shape_keys.key_blocks['Blink'].value<.001,'Blink does not return to neutral.'
# Render the complete wave and stepping checks; all fur remains enabled for render.
scene.render.resolution_x=1000;scene.render.resolution_y=1000;scene.cycles.samples=48
for frame,filename in [(28,'rig-wave-preview.png'),(86,'rig-step-preview.png')]:
 scene.frame_set(frame);scene.render.filepath=str(root/'outputs/plush-character'/filename);bpy.ops.render.render(write_still=True)
scene.frame_set(28);scene.render.filepath=str(root/'outputs/plush-character/rig-wave-preview.png')
bpy.ops.wm.save_as_mainfile(filepath=str(root/'outputs/plush-character/cream-mascot-rigged.blend'))
print(json.dumps({'file':bpy.data.filepath,'bones':len(rig.data.bones),'face_controls':['Blink','Blink Left','Blink Right','Smile'],'viewport_fur':.22,'renders':'full density','test_action':rig.animation_data.action.name}))
