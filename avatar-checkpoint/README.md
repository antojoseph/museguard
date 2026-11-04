# Cream mascot — saved project

The approved furry avatar, free Blender rig, animation showcases, references, source scripts, and Pi integration settings are saved here.

**Resume guide:** [outputs/resume/RESUME.md](outputs/resume/RESUME.md).

Start with `outputs/plush-character/cream-mascot-locomotion.blend`. It contains the latest shape, fur, rig, eight directions of walking, and a two-step climb. Open it in Blender and press Space to play frames 1–528.

```sh
python3 tools/resume.py check
python3 tools/resume.py blender
python3 tools/resume.py pi
```

The check verifies the saved deliverables against their SHA-256 manifest. The Pi command prepares an isolated local configuration from the committed templates and launches the existing Pi installation with the saved model and `xhigh` thinking level. Authentication stays outside Git.

The four main Blender files preserve successive milestones: approved visual master, rigged master, original animation showcase, and latest locomotion scene. Both completed videos are included. Earlier approved visual checkpoints are retained in `outputs/plush-character/checkpoints/`.

This folder preserves local checkpoint `8f25bfe` on a separate Museguard branch. Install Git LFS and run `git lfs pull --include="avatar-checkpoint/**"` from the Museguard repository root before opening the Blender files. Run the commands above from `avatar-checkpoint/`. Generated render frames, runtime downloads, logs, raw Pi transcripts, and automatic `.blend1` backups remain local and are ignored. They are not needed to reopen the saved scenes.
