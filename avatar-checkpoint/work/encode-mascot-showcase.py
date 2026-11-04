import bpy,json,time
from pathlib import Path
root=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an');folder=root/'work/showcase/frames';out=root/'outputs/plush-character';target=out/'cream-mascot-showcase.mp4'
frames=[folder/f'frame_{f:04d}.png' for f in range(1,361)]
assert all(p.is_file() and p.stat().st_size>10000 for p in frames),'Render frames missing or incomplete.'
s=bpy.data.scenes.new('Encode Mascot Showcase');ed=s.sequence_editor_create();strip=ed.strips.new_image('Rendered mascot',filepath=str(frames[0]),channel=1,frame_start=1)
for p in frames[1:]:strip.elements.append(p.name)
s.frame_start=1;s.frame_end=360;s.render.fps=24;s.render.fps_base=1;s.render.resolution_x=1080;s.render.resolution_y=1080;s.render.resolution_percentage=100;s.render.use_sequencer=True;s.render.use_compositing=False
s.view_settings.view_transform='Standard';s.view_settings.look='None';s.view_settings.exposure=0;s.view_settings.gamma=1
s.render.image_settings.media_type='VIDEO';s.render.image_settings.file_format='FFMPEG';s.render.ffmpeg.format='MPEG4';s.render.ffmpeg.codec='H264';s.render.ffmpeg.constant_rate_factor='HIGH';s.render.ffmpeg.ffmpeg_preset='GOOD';s.render.ffmpeg.audio_codec='NONE';s.render.filepath=str(target)
bpy.context.window.scene=s
t=time.time();bpy.ops.render.render(animation=True,scene=s.name)
if not target.exists():
 candidates=sorted(out.glob('cream-mascot-showcase*.mp4'),key=lambda p:p.stat().st_mtime,reverse=True)
 assert candidates,'Encoder did not produce an MP4.';candidates[0].rename(target)
assert target.stat().st_size>100000,'Encoded video is unexpectedly small.'
clip=bpy.data.movieclips.load(str(target));meta={'path':str(target),'size':list(clip.size),'frames':clip.frame_duration,'fps':clip.fps,'duration_seconds':clip.frame_duration/clip.fps,'bytes':target.stat().st_size,'encode_seconds':round(time.time()-t,2)}
assert list(clip.size)==[1080,1080] and clip.frame_duration==360 and abs(clip.fps-24)<.01,'Unexpected encoded video properties.'
(root/'work/showcase/video-metadata.json').write_text(json.dumps(meta,indent=2));print('VIDEO_METADATA '+json.dumps(meta),flush=True)
# Decode the actual MP4 through Blender, verifying the deliverable instead of just source PNGs.
v=bpy.data.scenes.new('Verify Encoded Showcase');ve=v.sequence_editor_create();movie=ve.strips.new_movie('Encoded video',filepath=str(target),channel=1,frame_start=1)
v.frame_start=1;v.frame_end=360;v.render.fps=24;v.render.fps_base=1;v.render.resolution_x=1080;v.render.resolution_y=1080;v.render.resolution_percentage=100;v.render.use_sequencer=True;v.render.use_compositing=False
v.view_settings.view_transform='Standard';v.view_settings.look='None';v.view_settings.exposure=0;v.view_settings.gamma=1;v.render.image_settings.file_format='PNG';v.render.image_settings.color_mode='RGB'
qa=root/'work/showcase/decoded';qa.mkdir(parents=True,exist_ok=True)
bpy.context.window.scene=v
for f in [16,37,61,96,144,177,194,213,232,251,273,301,325,347]:
 v.frame_set(f);v.render.filepath=str(qa/f'decoded_{f:04d}.png');bpy.ops.render.render(write_still=True,scene=v.name)
print('VIDEO_QA_DECODED',flush=True)
