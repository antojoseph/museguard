import bpy,json
r=bpy.data.objects['Mascot Rig'];s=bpy.context.scene;s.frame_set(1);h=r.pose.bones['Head'];a=r.animation_data.action
for layer in a.layers:
 for strip in layer.strips:
  for bag in strip.channelbags:
   for fc in list(bag.fcurves):
    if '["Blink' in fc.data_path or '["Smile' in fc.data_path:bag.fcurves.remove(fc)
for prop in ['Blink','Blink Left','Blink Right','Smile']:h[prop]=0.0
r.update_tag(refresh={'OBJECT','DATA','TIME'});bpy.context.view_layer.update()
for prop,keys in [('Blink',[(1,0),(12,0),(16,1),(20,0),(72,0),(76,1),(80,0),(120,0)]),('Smile',[(1,0),(20,0),(28,.65),(38,.65),(60,0),(120,0)])]:
 for frame,value in keys:h[prop]=float(value);h.keyframe_insert(data_path='["'+prop+'"]',frame=frame,group='Face expressions')
r.update_tag(refresh={'OBJECT','DATA','TIME'})
for n in ['Eye_L','Eye_R','Glint_L','Glint_R','Mouth']:
 k=bpy.data.objects[n].data.shape_keys;k.update_tag()
 for fc in k.animation_data.drivers:fc.driver.expression=fc.driver.expression.strip()+' '
bpy.context.view_layer.update();s.frame_set(14);bpy.context.view_layer.update()
value=bpy.data.objects['Eye_L'].data.shape_keys.key_blocks['Blink'].value
print(json.dumps({'blink_at14':value,'head_at14':h.get('Blink'),'type':str(type(h.get('Blink'))),'curves':[(fc.data_path,fc.evaluate(14),[(k.co[:],k.interpolation) for k in fc.keyframe_points]) for lay in a.layers for st in lay.strips for bag in st.channelbags for fc in bag.fcurves if '["Blink' in fc.data_path]}))
assert .1<value<.9,'Blink must interpolate smoothly.'
s.frame_set(28);bpy.ops.wm.save_as_mainfile(filepath=bpy.data.filepath)
