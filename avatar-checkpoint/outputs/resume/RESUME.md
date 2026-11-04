# Resume from this checkpoint

Saved on November 1, 2026. The avatar and its animations are complete in Blender at this milestone. The native Mac app has not been implemented.

## Open the latest scene

Open `outputs/plush-character/cream-mascot-locomotion.blend` in Blender. The project is saved at frame 1, with its camera view prepared and the complete showcase action active. Press Space to play. Required external assets are packed; the saved scene reports no missing resources.

The scene contains the approved cream furry body, a recessed face that follows the head's curves, glossy eyes, blush, smile, long rounded arms, broad short integrated legs, and the free native Blender rig. The original visual and rig masters remain separate.

| File | Purpose |
| --- | --- |
| `outputs/plush-character/cream-mascot.blend` | Approved visual master before rigging |
| `outputs/plush-character/cream-mascot-rigged.blend` | Rig and facial controls |
| `outputs/plush-character/cream-mascot-showcase.blend` | Original 15-second rig demonstration |
| `outputs/plush-character/cream-mascot-locomotion.blend` | Latest walking and climbing scene |
| `outputs/plush-character/cream-mascot-showcase.mp4` | Waves, small steps, head turns, bow, blink/wink, smile, bounce |
| `outputs/plush-character/cream-mascot-walk-and-climb.mp4` | New 22-second locomotion video |

Reference images and earlier approved shape checkpoints are under `outputs/plush-character/references/` and `outputs/plush-character/checkpoints/`. Final stills and close-ups are in the same character folder.

## Animation timeline and reusable actions

The current showcase spans frames 1–528 at 24 fps, rendered at 1080 × 1080. Each walking section lasts two seconds. The climb lasts six seconds.

| Frames | Movement |
| --- | --- |
| 1–48 | Forward |
| 49–96 | Backward |
| 97–144 | Left |
| 145–192 | Right |
| 193–240 | Forward left |
| 241–288 | Forward right |
| 289–336 | Back left |
| 337–384 | Back right |
| 385–528 | Climb two shallow steps |

The active action is `Showcase - eight directions and stair climb`. There are 17 additional reusable actions with Fake User enabled:

- Eight `Walk - …` actions: translated start/walk/stop clips, frames 1–48, 0.20 m travel each.
- Eight `Walk loop - …` actions: one-second in-place cycles, keys 1–25. Frame 25 repeats frame 1; sample frames 1–24 when wrapping discrete playback. Move the app's character entity at 0.10 m/s in the matching direction to maintain foot contact.
- `Climb - Two steps`: frames 1–144, 0.74 m forward and 0.11 m upward, onto two 5.5 cm treads.

The character faces forward during strafing/backward/diagonal motion. Blender coordinates are forward −Y, right +X, and up +Z. Convert these to the app's coordinate convention on export. Embedded Blender Text notes describe the clips and playback.

## Rig and fur details to preserve

The 16-bone native rig has Root, Body, Chest, Head, and Arm/Forearm/Hand plus Leg/Shin/Foot on each side. Head float properties control Blink, Blink Left, Blink Right, and Smile. Eye and smile drivers remain connected.

Walking uses analytically solved, baked foot contacts. The short integrated plush stumps now blend mostly between Body and Foot, with full Foot influence at the soles. This avoids dragging the deep belly into thigh rotations. The leg bones still contain the baked IK motion. The final front-stump mask transitions from Z 0.16–0.28, with Foot influence fading over Z 0.085–0.34 and full Foot below Z 0.075.

Nine surface-bound hair-curve objects contain about 1.19 million strands. A hidden `Coat_FurBindingSurface` preserves the neutral groom and drives deformation through Geometry Nodes. Keep its topology, `RigBindingUV`, vertex-group correspondence, and the hair root UV data intact. The viewport shows reduced strand density; renders retain the full fur.

## Pi and Blender MCP

The captured setup is Pi 1.4.0, Blender 5.2.4 LTS Release Candidate, and `mcp-for-blender==2.2.6`. Exact non-secret configuration and the installed addon source are committed under `config/` and `integrations/`.

Pi provider: `baseten-hackathon`. Model: `meta-models/muse-spark-open-1026`. Endpoint: `https://inference.baseten.co/v1`. Thinking level: `xhigh`, the highest configured supported level. The `max` mapping is null. Keep the image-limit extension, which limits image context to the endpoint's eight-image limit.

```sh
python3 tools/resume.py check
python3 tools/resume.py blender
python3 tools/resume.py pi
```

The Pi launcher creates an ignored `.local/pi-agent/` configuration and uses ignored `.local/pi-sessions/` session storage. It automatically references the existing credential helper at `~/.pi/agent/baseten-key.py` when available; otherwise it expects `BASETEN_API_KEY` in the environment. No credential values are included in this checkpoint. Existing private Pi configuration and raw sessions outside Git are left intact. A resumed Pi session receives this guide as context.

In Blender, the installed addon serves the local connection on `127.0.0.1:9876`. If it is not running after reopening Blender, enable the Blender MCP addon and start its server in Blender's sidebar. The committed addon copy is `integrations/blender/blender_mcp.py`; the installed copy on this Mac is under `~/Library/Application Support/Blender/5.2/scripts/addons/`.

`work/blender-request.py` is the direct local code-execution bridge. It takes a Python script filename and executes that script in the open Blender instance. It is a powerful editing operation; inspect scripts before running them.

## Rebuilding and verification

Reopening the saved `.blend` is the normal resume path. Historical scripts are preserved as source history, not as a single idempotent build. Their order and topology assumptions matter. Many still reference the original absolute workspace location.

The final locomotion edit sequence was: create the separate scene, bake movement, apply `refine-stump-weights.py` through `apply-stump-locomotion.py`, derive separate clips, add repeating loops, then save/verify the project. `prepare-locomotion-output.py` currently derives the clips and saves; the step riser material was assigned separately during refinement. Do not rerun this sequence on the finished master without making a copy and checking its current state.

`work/render-mascot-showcase.py` renders PNG frames with Cycles/Metal. `work/encode-locomotion-video.py` encodes the 528 frames using Blender's video sequencer. Render frames are regenerable and are ignored. A fresh render directory is appropriate for a changed scene; the worker skips existing frames. The encoder and frame-comparison check use the bundled Python/Pillow runtime recorded in the helper scripts.

Validation records are committed under `work/locomotion/` and `work/showcase/`. The final saved loops were checked through actual Blender action evaluation, and the deformed soles were checked against floor/tread heights. The exported locomotion video was decoded and compared with 17 source frames; it is 528 frames, 24 fps, 1080 × 1080, and 22 seconds long.

`outputs/resume/assets-manifest.json` contains file sizes and SHA-256 hashes for the saved deliverables. Run the check command after restoring or copying the repository. Git also preserves the source and configuration history.

## Where to continue

The product goal is a fully 3D interactive native SwiftUI/AppKit Mac app. Future work includes optimizing the strand fur into a real-time representation, validating the rig and facial animation export for RealityKit, building movement/animation blending and interactions, and implementing the app. The current `.blend` files and videos are authoring assets; they are not a completed app or a validated runtime package.

This branch preserves local checkpoint `8f25bfe`. From the Museguard repository root, run `git lfs pull --include="avatar-checkpoint/**"` to download the Blender files, then run the verification command from `avatar-checkpoint/`. Automatic `.blend1` backups, temporary render frames, downloads, logs, and raw transcripts remain on this Mac but are not needed to reopen and continue the saved scene.
