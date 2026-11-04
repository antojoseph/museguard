# Resume instructions for coding agents

Read `outputs/resume/RESUME.md` and `outputs/resume/blender-checkpoint.json` before editing. The current master is `outputs/plush-character/cream-mascot-locomotion.blend`; opening it resumes the finished scene without rebuilding.

Preserve the user's approved recessed curved face, hood outline, broad integrated leg stumps, long mitten arms, cream fur, and facial expression. Make future experiments in a separate Blender copy. Do not rerun historical build scripts against the current master: many expect earlier geometry, a particular active action, or an earlier file.

The latest scene has a 528-frame showcase at 24 fps, 17 reusable locomotion actions, 16 bones, facial shape-key drivers, and surface-bound strand fur. Keep `Coat_FurBindingSurface`, its UV atlas, and hair root data intact. Native Blender armature modifiers do not directly deform the hair curves; the existing Geometry Nodes surface binding does.

Use `python3 tools/resume.py check` to verify saved assets. The new launcher resolves the repository location dynamically. Historical `work/` scripts retain the original absolute workspace path; review or update their paths before using them after relocation.

Pi uses the committed non-secret templates under `config/pi/`, model `meta-models/muse-spark-open-1026`, provider `baseten-hackathon`, and thinking level `xhigh`. The provider's `max` mapping is null; do not silently substitute it for `xhigh`. Preserve the image-limit extension. Use the existing external credential helper or `BASETEN_API_KEY`; never read, print, copy, commit, or log authentication secrets. Raw transcripts, logs, and downloaded credentials are excluded from Git.

The intended product is an interactive 3D native SwiftUI/AppKit Mac app. The current work is Blender authoring and animation. Runtime fur optimization, RealityKit export validation, and the app itself are still future work; do not claim these are completed.
