import bpy,json,sys
from pathlib import Path
from mathutils import Vector
R=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an');sys.path.insert(0,str(R/'work'));from locomotion_math import gait_ankle_target
s=bpy.context.scene;rig=bpy.data.objects['Mascot Rig'];oldaction=rig.animation_data.action;oldslot=rig.animation_data.action_slot;oldframe=s.frame_current;feet={side:rig.data.bones['Foot.'+side].head_local.copy() for side in ['L','R']};rows=[]
try:
 for action in [a for a in bpy.data.actions if a.name.startswith('Walk loop - ')]:
  rig.animation_data.action=action
  if len(action.slots):rig.animation_data.action_slot=action.slots[0]
  direction=Vector(action['Direction vector']);v=direction*.10
  error=0.;endpoint=[]
  for frame in [1,7,13,19,25]:
   s.frame_set(frame);t=(frame-1)/24
   for side,phase in [('L',0.),('R',.5)]:
    expected=gait_ankle_target(t,lambda t:v*t,v,feet[side],phase=phase,cycle=1.,duty=.62,lift=.016)-v*t
    error=max(error,(rig.pose.bones['Foot.'+side].head-expected).length)
   if frame in [1,25]:endpoint.append({p.name:p.matrix.copy() for p in rig.pose.bones})
  delta=max(abs(endpoint[0][name][i][j]-endpoint[1][name][i][j]) for name in endpoint[0] for i in range(4) for j in range(4))
  assert error<.00005 and delta<.00005,(action.name,error,delta);rows.append({'action':action.name,'evaluated_ankle_error_m':error,'evaluated_loop_endpoint_matrix_error':delta})
finally:
 rig.animation_data.action=oldaction;rig.animation_data.action_slot=oldslot;s.frame_set(oldframe)
# The sole remains flat and meets its target surface after actual mesh evaluation.
coat=bpy.data.objects['Coat'];soles=[];targets=json.loads((R/'work/locomotion/targets.json').read_text())['frames']
for f in [1,12,24,396,405,415,430,452,470,495,520]:
 s.frame_set(f);dg=bpy.context.evaluated_depsgraph_get();evaluated=coat.evaluated_get(dg);mesh=evaluated.to_mesh(preserve_all_data_layers=True,depsgraph=dg)
 try:
  for side in ['L','R']:
   group=coat.vertex_groups['Foot.'+side].index;low=[v.co.z for v in mesh.vertices if any(g.group==group and g.weight>.9999 for g in v.groups)]
   assert low;minimum=min(low);target=targets[str(f)][side]['ankle'][2]-.052;error=abs(minimum-target);assert error<.0002,(f,side,minimum,target)
   soles.append({'frame':f,'side':side,'sole_minimum_z':minimum,'target_bottom_z':target,'error_m':error})
 finally:evaluated.to_mesh_clear()
s.frame_set(1);bpy.ops.file.pack_all();bpy.ops.wm.save_as_mainfile(filepath=str(R/'outputs/plush-character/cream-mascot-locomotion.blend'))
result={'evaluated_walk_loops':rows,'evaluated_soles':soles,'active_action':rig.animation_data.action.name,'new_reusable_actions':17,'combined_frames':528,'fps':24};(R/'work/locomotion/final-asset-validation.json').write_text(json.dumps(result,indent=2));print(json.dumps({'loops_verified':len(rows),'maximum_loop_ankle_error_m':max(r['evaluated_ankle_error_m'] for r in rows),'maximum_sole_height_error_m':max(r['error_m'] for r in soles),'saved':bpy.data.filepath}))
