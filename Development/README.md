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

### Harmless protection fixtures

`python3 Development/protection-demo.py` serves the local secret-paste, pointer and download fixtures at `http://127.0.0.1:8767/`. Its copy button uses a public BIP39 test vector, never a real wallet. The page counts delivered paste events and never retains submitted bodies. The antivirus fixture is the harmless standard EICAR test, not live malware. No fixture is executed.

`SecretPasteFixture.swift` is excluded from ordinary builds. Compile it with `-parse-as-library -D MUSE_SECRET_PASTE_FIXTURE` into a local AppKit test bundle to verify that native keyboard paste inserts the public test phrase and produces an exposure warning afterward. The fixture has no save or network path. Browser paste should instead be stopped before page delivery. Always verify the actual foreground app; selecting a tab through automation can leave the coding app foreground.
