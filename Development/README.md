# Development tools

These Swift sources are included only in `MUSE_DEVELOPMENT` builds. The release build compiles `Sources/SentinelPet/` without this directory.

```sh
./run-dev.sh --studio --mock-lab
./run-dev.sh --build-only
```

Studio previews the approved Guard/Focus/Just Muse accessories, poses, sleep sequence, and desktop jump. Mock Lab supplies synthetic phishing, legitimate sign-in, gift-card, ordinary-message, and prompt-injection cases. Both use the same runtime/analyzer as the app.

`--visual-test` enables capturable overlays and temporary motion-event records only in development builds. `--chat-corner-check --visual-test` opens the corner-layout fixture. Release builds ignore these testing flags.

## Asset checks and previews

The approved asset snapshot is pinned in `Unreal/AVATAR_SOURCE.md`; ordinary builds do not change it. Geometry/material regeneration is an explicit development action:

```sh
uv run --with numpy --with trimesh --with scipy --with shapely --with mapbox-earcut --with triangle --with scikit-image --with fast-simplification python scripts/prepare-muse-mesh.py
uv run --with numpy --with trimesh --with scipy --with networkx python scripts/prepare-guard-accessories.py
python3 scripts/check-muse-mesh.py
python3 scripts/check-guard-accessories.py
```

To rebuild derived Unreal assets, set `MUSE_REBUILD_ASSETS=1` for the build. This explicitly copies regenerated assets back to the bundled snapshot; review that diff before committing.

Offline preview tools launch their own renderer and save generated media under `build/`:

```sh
uv run --with pillow --with imageio-ffmpeg python scripts/preview-idle-sleep.py
uv run --with pillow --with imageio-ffmpeg --with numpy --with scipy python scripts/preview-locomotion.py
uv run --with pillow --with imageio-ffmpeg python scripts/preview-animations.py
uv run --with pillow --with imageio-ffmpeg python scripts/preview-desktop-jump.py
uv run --with pillow --with imageio-ffmpeg python scripts/preview-spy-glasses.py
```

Keep original-source attribution, the mesh metadata, and the matching preparation scripts when changing derived geometry. Generated binaries, downloaded models, credentials, dependency directories, captures, and benchmark output are excluded from the source release.
