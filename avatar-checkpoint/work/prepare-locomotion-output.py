import bpy,json
from pathlib import Path
R=Path('/Users/x/Documents/Codex/2026-10-30/referenced-chatgpt-conversation-this-is-an');s=bpy.context.scene
exec(compile((R/'work/create-locomotion-clips.py').read_text(),'clips','exec'),globals())
(R/'work/locomotion/individual-clips-validation.json').write_text(json.dumps(LOCOMOTION_CLIP_REPORT,indent=2))
s.frame_set(1);bpy.ops.wm.save_as_mainfile(filepath=str(R/'outputs/plush-character/cream-mascot-locomotion.blend'))
