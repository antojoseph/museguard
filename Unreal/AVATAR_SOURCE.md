# Approved avatar snapshot

`MuseGuard/` contains the tracked Unreal project from the private [antojoseph/museguard repository](https://github.com/antojoseph/museguard) at commit `f42819d82280a133c243b542a58d85eb2d96c2ec`. It matches the approved model and animations used by this companion.

This snapshot includes fitted 3D spy glasses that stay on while browser protection is active, with a paw-driven put-on/removal gesture and a small temple adjustment when inference starts. The source is mirrored in the sibling avatar project; the approved body geometry, materials and other poses are unchanged.

The companion build prefers a sibling `../museguard/Unreal/MuseGuard` checkout when present. Without that checkout, it uses this bundled snapshot. `MUSE_AVATAR_SOURCE` can select another project explicitly. Generated Unreal build products are excluded.

The original source STLs and attribution remain in `../Assets/Source/MuseJolly`. The mesh and accessory preparation scripts and their geometry checks in `../scripts` match this avatar revision. Companion preview scripts retain this app’s bundle paths and demonstration context.

The community source and derived mesh retain their CC BY-NC-SA 4.0 attribution; see `MuseGuard/Content/Muse/ATTRIBUTION.txt` and `Jolly.json`.
