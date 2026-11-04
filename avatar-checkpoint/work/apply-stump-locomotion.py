import bpy,json
from pathlib import Path
R=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an');exec(compile((R/'work/refine-stump-weights.py').read_text(),'stump_weights','exec'),globals())
report=refine_stump_weights(bpy.data.objects['Mascot Rig']);(R/'work/locomotion/stump-weight-validation.json').write_text(json.dumps(report,indent=2))
rig=bpy.data.objects['Mascot Rig'];action=rig.animation_data.action
old=bpy.data.actions.get('Showcase - eight directions and stair climb')
if old and old!=action:old.name='Earlier locomotion - original stride'
action.name='Showcase - eight directions and stair climb'
font=Path('/System/Library/Fonts/Supplemental/Arial Bold.ttf')
if font.exists():
 fontdata=bpy.data.fonts.load(str(font))
 for ob in bpy.data.collections['Locomotion stage'].objects:
  if ob.type=='FONT':ob.data.font=fontdata;ob.data.size=.10
bpy.context.scene.frame_set(1)
bpy.ops.wm.save_as_mainfile(filepath=str(R/'outputs/plush-character/cream-mascot-locomotion.blend'));print(json.dumps(report))
