# Approved avatar snapshot

`MuseGuard/` contains the tracked Unreal project from the private [antojoseph/museguard repository](https://github.com/antojoseph/museguard) at commit `f42819d82280a133c243b542a58d85eb2d96c2ec`. The body and animation baseline is retained; the glasses have since been replaced with the fitted round-frame asset described below.

This snapshot includes fitted round black-metal glasses that stay on while browser or desktop protection is active, with a paw-driven put-on/removal gesture and a small temple adjustment when inference starts. The approved body geometry, materials and other poses are unchanged.

The companion builds this bundled snapshot by default, so a clean checkout uses the approved model without needing access to another repository. `MUSE_AVATAR_SOURCE` can select another project explicitly. Generated Unreal build products are excluded.

The original source STLs and attribution remain in `../Assets/Source/MuseJolly`. The mesh and accessory preparation scripts and their geometry checks in `../scripts` match this avatar revision. Companion preview scripts retain this app’s bundle paths and demonstration context.

The community source and derived mesh retain their CC BY-NC-SA 4.0 attribution; see `MuseGuard/Content/Muse/ATTRIBUTION.txt` and `Jolly.json`.

The round glasses derive from [Glasses by Coco Jinjo](https://sketchfab.com/3d-models/glasses-45bd43443daa4b65b5511aed74422338), under CC BY-NC 4.0. The unmodified GLB is in `../Assets/Source/CocoJinjoGlasses/`; `../scripts/prepare-round-glasses.py` produces `RoundGlasses.json`. `ROUND_GLASSES_ATTRIBUTION.txt` records the source and fitting changes. The glasses use dedicated black-metal and clear-lens materials, retaining the existing attachment animations.
