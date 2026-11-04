import bpy,numpy as np,json
from pathlib import Path
root=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an')
exec(compile((root/'work/bind-mascot-fur.py').read_text(),'furbind','exec'),globals())
coat=bpy.data.objects['Coat'];make_binding_uv(coat);bpy.context.view_layer.update();sample=surface_sampling_data(coat)
fur=bpy.data.objects['FaceEdge_PlushGroom'];before=np.empty(len(fur.data.points)*3,np.float32);fur.data.position_data.foreach_get('vector',before)
result=bind_one_fur(fur,coat,sample);bpy.context.view_layer.update();ev=fur.evaluated_get(bpy.context.evaluated_depsgraph_get());after=np.empty(len(ev.data.points)*3,np.float32);ev.data.position_data.foreach_get('vector',after)
d=np.linalg.norm((after-before).reshape(-1,3),axis=1)
print(json.dumps({'stats':result,'neutral_drift_max':float(d.max()),'neutral_drift_mean':float(d.mean()),'evaluatedpoints':len(ev.data.points)}))
