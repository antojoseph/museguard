# Muse Guard — 3D avatar

A standalone, real-time 3D plush avatar and macOS preview studio. This repository contains the avatar renderer, source models, animation and deformation code, accessories, materials, asset preparation tools, and a native preview app.

The security-analysis application, browser/screen analysis, chat, local language model, and application logs are outside this repository.

## Run the studio

Requirements: Apple Silicon Mac, macOS 13 or later, Xcode command-line tools, and Unreal Engine 5.8 installed locally. The engine itself is not included. The default engine location is `/Users/Shared/Epic Games/UE_5.8`; override it with `MUSE_UNREAL_ROOT`.

```sh
./run-dev.sh
# Compile without opening the app:
./run-dev.sh --build-only
# Validate the runtime mesh and native renderer protocol:
./scripts/check.sh
```

The build creates `build/Run/MuseGuardStudio.app`. A separate renderer project is staged in `~/Library/Application Support/MuseGuardAvatar/Renderer` so this app does not overwrite the original companion project's renderer.

The studio previews the guard/focus/plain accessories and avatar states, including breathing, looking around, stretching, walking, climbing, yawning, sleeping, waking, blocking, explaining, and a jump sequence. All character pixels are rendered live in Unreal; there are no sprite sheets or prerecorded animations.

## Desktop tests

Muse also appears as a transparent avatar on the desktop. In Studio, use **Jump to center**, **Walk across screen**, **Climb edge**, and **Return home** to test real movement across your display. These use the renderer's fixed-camera 3D journeys at a constant avatar size.

Drag the desktop avatar to choose and save its home position. **Hide avatar** removes it completely; **Show avatar** brings it back. Transparent space remains clickable, and the overlay is click-through during travel. Studio keeps its last resting preview while a desktop test is playing.

## Contents

- `Unreal/MuseGuard/Source`: procedural mesh loading, twelve-bone deformation, dedicated sleeping shape, walking/climbing/jump poses, fur, magic wand/bed, lighting, and transparent frame export.
- `Unreal/MuseGuard/Content`: runtime mesh, materials, generated accessory geometry, empty stage, and attribution.
- `Unreal/MuseGuard/Config`: renderer and accessory configuration.
- `Sources/MuseGuardStudio`: standalone macOS preview app, renderer process/IPC bridge, frame decoder, and animation timing.
- `Assets/Source/MuseJolly`: original credited STL files and source metadata.
- `scripts`: asset generation, validation, build, and rendered motion previews.

The avatar has a peach plush coat with 40,000 finer curved fur tufts with a brushed groom and soft cloth sheen, a smooth pale face, rounded arms and paws, two sculpted cheeks with a soft central fold, and a separate round tail. Sleep blends into a low bed-space shape on upholstered bedding. Guard cap, badge and focus headphones are removable 3D accessories. The transparent home frame renders at 1280×1280 and resolves to 640×640; desktop journeys use a fixed camera and Retina-density cropped frames.

## Asset generation and visual checks

The committed runtime mesh loads without installing Python packages. Regenerate after editing the body or skinning:

```sh
uv run --with numpy --with trimesh --with scipy --with shapely --with mapbox-earcut --with triangle --with scikit-image --with fast-simplification python scripts/prepare-muse-mesh.py
uv run --with numpy --with trimesh --with scipy --with networkx python scripts/prepare-guard-accessories.py
MUSE_REBUILD_ASSETS=1 ./run-dev.sh --build-only
```

Visual checks require [uv](https://docs.astral.sh/uv/) and the built studio's renderer configuration:

```sh
uv run --with pillow --with imageio-ffmpeg python scripts/preview-idle-sleep.py
uv run --with pillow --with imageio-ffmpeg --with numpy --with scipy python scripts/preview-locomotion.py
uv run --with pillow --with imageio-ffmpeg python scripts/preview-desktop-jump.py
```

Preview images, motion diagnostics, and videos are written under ignored `build/` directories. The native bridge sends only avatar state commands and receives transparent pixels; it does not send screen captures or documents to the renderer. `GuardianDesktopScene` also exposes the fixed-camera journey format for integrating the avatar with another application.

## Source model and attribution

The original **Meta Muse — Jolly** printable model is by **MadDog2125**, downloaded from [MakerWorld](https://makerworld.com/en/models/3441016-meta-muse-jolly), under [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). Its original STL files remain unmodified. The derived mesh and its modification record are in `Unreal/MuseGuard/Content/Muse/Jolly.json`; attribution is preserved beside both the source and runtime assets. The model's noncommercial/share-alike terms continue to apply to those assets and their derivatives.

Unreal Engine is supplied separately under Epic's terms. This repository does not include the engine or change the source model's license.
