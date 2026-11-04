import bpy,math,json
from mathutils import Matrix
from pathlib import Path
root=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an');s=bpy.context.scene;r=bpy.data.objects['Mascot Rig']
assert bpy.data.filepath.endswith('cream-mascot-showcase.blend')
for f in range(169,241):
 t=(f-1)/24.;angles={n:0. for n in ['Leg.L','Shin.L','Foot.L','Leg.R','Shin.R','Foot.R']}
 for side,a,b in [('L',7.05,7.65),('R',7.75,8.35),('L',8.45,9.05),('R',9.15,9.75)]:
  if a<=t<=b:
   lift=math.sin(math.pi*(t-a)/(b-a))**2;angles['Leg.'+side]=-10*lift;angles['Shin.'+side]=18*lift;angles['Foot.'+side]=-8*lift
 for name,deg in angles.items():
  p=r.pose.bones[name];rest=p.bone.matrix_local.to_3x3();p.rotation_euler=(rest.inverted()@Matrix.Rotation(math.radians(deg),3,'X')@rest).to_euler('XYZ');p.keyframe_insert('rotation_euler',frame=f,group=name)
s.frame_set(177);bpy.context.view_layer.update();path=root/'work/showcase/showcase-milder-steps.blend';bpy.ops.wm.save_as_mainfile(filepath=str(path),copy=True)
print(json.dumps({'candidate':str(path),'changed_frames':[169,240],'angles':[-10,18,-8]}))
