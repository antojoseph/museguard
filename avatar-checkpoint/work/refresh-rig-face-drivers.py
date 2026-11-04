import bpy,json
r=bpy.data.objects['Mascot Rig'];r.update_tag(refresh={'OBJECT','DATA','TIME'})
for n in ['Eye_L','Eye_R','Glint_L','Glint_R','Mouth']:
 k=bpy.data.objects[n].data.shape_keys;k.update_tag()
 for fc in k.animation_data.drivers:fc.driver.expression=fc.driver.expression+' '
bpy.context.view_layer.update();bpy.context.scene.frame_set(16);bpy.context.view_layer.update()
ev=r.evaluated_get(bpy.context.evaluated_depsgraph_get())
print(json.dumps({'head':list(r.pose.bones['Head'].items()),'evaluated':list(ev.pose.bones['Head'].items()),'eyevalues':[k.value for k in bpy.data.objects['Eye_L'].data.shape_keys.key_blocks],'driver_valid':[fc.driver.is_valid for fc in bpy.data.objects['Eye_L'].data.shape_keys.animation_data.drivers]}))
