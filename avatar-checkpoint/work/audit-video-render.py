import bpy,json
s=bpy.context.scene
if bpy.context.screen and bpy.context.screen.is_animation_playing:
 bpy.ops.screen.animation_cancel(restore_frame=False)
p=bpy.context.preferences.addons['cycles'].preferences
info={'file':bpy.data.filepath,'engine':s.render.engine,'cycles_device':s.cycles.device,'compute_type':p.compute_device_type,'preview_samples':s.cycles.preview_samples,'transparent':s.render.film_transparent,'fps':s.render.fps,'camera':s.camera.name,'gpus':[]}
try:
 p.get_devices();info['devices']=[{'name':d.name,'type':d.type,'use':d.use} for d in p.devices]
except Exception as e:info['device_error']=str(e)
try:
 info['compute_types']=[(x.identifier,x.name) for x in p.bl_rna.properties['compute_device_type'].enum_items]
except Exception:pass
info['scene_cameras']=[o.name for o in s.objects if o.type=='CAMERA']
info['cycles_properties']=[p.identifier for p in s.cycles.bl_rna.properties if any(x in p.identifier for x in ['bvh','device','denois','adaptive','hair'])]
info['render_engines']=[x.identifier for x in s.render.bl_rna.properties['engine'].enum_items]
print(json.dumps(info))
