import bpy
r=bpy.data.objects['Mascot Rig'];h=r.pose.bones['Head']
for prop in ['Blink','Blink Left','Blink Right','Smile']:
 h[prop]=0.0;h.id_properties_ui(prop).update(min=0.,max=1.,soft_min=0.,soft_max=1.)
a=r.animation_data.action
for layer in a.layers:
 for strip in layer.strips:
  for bag in strip.channelbags:
   for fc in bag.fcurves:
    if '["Blink' in fc.data_path or '["Smile' in fc.data_path:fc.update_autoflags(r)
r.update_tag(refresh={'OBJECT','DATA','TIME'})
for n in ['Eye_L','Eye_R','Glint_L','Glint_R','Mouth']:
 k=bpy.data.objects[n].data.shape_keys;k.update_tag()
 for fc in k.animation_data.drivers:fc.driver.expression=fc.driver.expression.strip()+' '
bpy.context.view_layer.update();bpy.context.scene.frame_set(14);bpy.context.view_layer.update()
value=bpy.data.objects['Eye_L'].data.shape_keys.key_blocks['Blink'].value
assert .1<value<.9,'Blink must interpolate smoothly.'
print('Blink controls interpolate smoothly:',value)
