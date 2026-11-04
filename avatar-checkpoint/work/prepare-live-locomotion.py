import bpy,json
s=bpy.context.scene;s.sync_mode='FRAME_DROP';s.frame_set(1)
views=[]
for area in bpy.context.screen.areas:
 if area.type=='VIEW_3D':
  space=area.spaces.active;space.overlay.show_overlays=False;space.region_3d.view_perspective='CAMERA';space.shading.type='MATERIAL';views.append({'type':space.shading.type,'overlays':space.overlay.show_overlays})
 if area.type=='DOPESHEET_EDITOR':
  region=next((r for r in area.regions if r.type=='WINDOW'),None)
  if region:
   with bpy.context.temp_override(area=area,region=region):bpy.ops.action.view_all()
bpy.ops.wm.save_as_mainfile(filepath=bpy.data.filepath);print(json.dumps({'views':views,'frame':s.frame_current,'action':bpy.data.objects['Mascot Rig'].animation_data.action.name}))
