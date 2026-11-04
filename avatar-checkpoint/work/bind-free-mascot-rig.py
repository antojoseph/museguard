import bpy,numpy as np,json
from pathlib import Path
root=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an')
exec(compile((root/'work/bind-mascot-fur.py').read_text(),'furbind','exec'),globals())
rig=bpy.data.objects['Mascot Rig'];bpy.context.scene.frame_set(1)
assert all(p.matrix_basis.is_identity for p in rig.pose.bones),'Bind only in neutral pose.'
results=bind_all_fur(rig,use_coat_proxy=True)
errors={}
for o in list(bpy.context.scene.objects):
 if o.type!='CURVES':continue
 before=np.empty(len(o.data.points)*3,np.float32);o.data.position_data.foreach_get('vector',before)
 ev=o.evaluated_get(bpy.context.evaluated_depsgraph_get());after=np.empty(len(ev.data.points)*3,np.float32);ev.data.position_data.foreach_get('vector',after)
 d=np.linalg.norm((after-before).reshape(-1,3),axis=1);errors[o.name]={'max':float(d.max()),'mean':float(d.mean())}
assert max(e['max'] for e in errors.values())<.00005,'Unexpected neutral fur drift; investigate before saving.'
(root/'work/fur-rig-binding-report.json').write_text(json.dumps({'bindings':results,'rest_errors':errors},indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(root/'outputs/plush-character/cream-mascot-rigged.blend'))
print(json.dumps({'bindings':results,'neutral_fur_error':errors,'status':'Bound all existing fur and preserved neutral appearance.'}))
