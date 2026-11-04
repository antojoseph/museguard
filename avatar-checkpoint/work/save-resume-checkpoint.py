import bpy,json,platform
from pathlib import Path
s=bpy.context.scene;rig=bpy.data.objects['Mascot Rig'];playing=bool(bpy.context.screen and bpy.context.screen.is_animation_playing);frame=s.frame_current
if playing:bpy.ops.screen.animation_cancel(restore_frame=False)
bpy.ops.file.pack_all()
# Reopen at the beginning of the complete showcase; preserve the prior view frame in the checkpoint metadata.
s.frame_set(1);bpy.ops.wm.save_as_mainfile(filepath=bpy.data.filepath)
actions=[{'name':a.name,'fake_user':a.use_fake_user,'frame_range':list(a.frame_range)} for a in bpy.data.actions if a.name.startswith(('Walk - ','Walk loop - ','Climb - '))]
missing=[]
for p in bpy.utils.blend_paths(absolute=True,packed=False):
 if p and not Path(p).exists():missing.append(p)
report={'blender_version':bpy.app.version_string,'saved_file':bpy.data.filepath,'saved_frame':s.frame_current,'view_frame_before_save':frame,'was_playing':playing,'active_action':rig.animation_data.action.name,'range':[s.frame_start,s.frame_end],'fps':s.render.fps,'camera':s.camera.name,'bone_count':len(rig.data.bones),'reusable_actions':actions,'packed_resources':True,'missing_external_resources':missing,'scene_objects':len(s.objects),'hair_curve_objects':sum(o.type=='CURVES' for o in s.objects)}
p=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an/outputs/resume');p.mkdir(parents=True,exist_ok=True);(p/'blender-checkpoint.json').write_text(json.dumps(report,indent=2))
print(json.dumps({'saved':bpy.data.filepath,'reusable_actions':len(actions),'missing_external_resources':missing,'saved_frame':s.frame_current}))
