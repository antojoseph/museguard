# Muse Guard

Muse Guard is a macOS companion with a live 3D Muse avatar, local Muse Glimmer inference, and a Chrome extension. It watches the app you are using, checks browser content in the background, and brings the avatar forward to explain confirmed high-risk findings. Chat can also use fresh context from the current app.

This is a hackathon source release. Builds use an installed Unreal Engine 5.8 runtime; the app bundle is a local source build rather than a standalone installer. The approved avatar is included in this repository and does not require a second checkout.

## Build from source

Requirements:

- An Apple Silicon Mac running macOS 14 or newer, with Xcode command-line tools.
- Unreal Engine 5.8 (tested with 5.8.4), normally installed at `/Users/Shared/Epic Games/UE_5.8`. Set `MUSE_UNREAL_ROOT` for another location.
- Python 3 and the Hugging Face `hf` CLI for model installation.
- Node.js and npm for extension tests.

From this checkout:

```sh
./scripts/setup-local-model.sh
./scripts/build-app.sh --configuration release
open build/Release/MuseGuard.app
```

Setup downloads the pinned official llama.cpp runtime, Muse Glimmer Q4_K_M target, vision projector, and matching DFlash draft. The files occupy about 20 GB; inference needs additional memory. The current setup was tested on an M5 Max with 128 GB unified memory. DFlash uses at most three draft tokens and both models run on Metal. The installation verifies the draft checksum.

The release build uses Swift optimization and excludes Studio, Mock Lab, pose previews, motion recording, and the screenshot-test override. `MUSE_CODESIGN_IDENTITY` selects a signing identity; otherwise the builder uses an available Apple Development identity or local ad-hoc signing. Ad-hoc rebuilds can require renewal of macOS screen permissions: remove the old Muse Guard entry and add the rebuilt release app in both Accessibility and Screen Recording settings, then restart Muse. Switching an old entry off and on may retain the previous signature. This workflow does not notarize or distribute the app.

The renderer is staged under `~/Library/Application Support/MuseGuard/Renderer`; model files and the private local credential live under `~/Library/Application Support/MuseGuard/LocalModel`. The model listens only on `127.0.0.1:8787`. The existing `com.sentinelpet.app` bundle identity and `SentinelPet` executable name are retained for permission continuity.

Readiness checks the expected target path and the running server's actual speculative slot. The launch configuration fixes DFlash mode and the three-token limit. Stop any separately launched old model server before opening the updated app; Muse only terminates model processes it owns.

## Connect Chrome

Prepare the host package, review it, and register it for this user:

```sh
python3 scripts/install-browser-host.py
python3 scripts/install-browser-host.py --install
```

The first command writes only `build/BrowserInstall/`. The second registers the native host for Google Chrome. It records the selected Python interpreter; rerun the installer if that interpreter moves.

In `chrome://extensions`, enable Developer mode and load `BrowserExtension/` as an unpacked extension. Its stable development ID is `omkmeoiobbgmdfhjbhbkjmmhcigkogka`. Wait for the app's local model to be ready. After changing extension files, reload the extension once in Chrome. See [the extension guide](BrowserExtension/README.md) and [native host guide](BrowserNativeHost/README.md).

Protection starts on across supported HTTP/HTTPS tabs. Existing explicit pause/off preferences are preserved. The app menu and extension offer the same global pause: 30 minutes or until resumed. Pause stops automatic browser and desktop checks, cancels pending work, and clears tab blocking decisions. There are no manual scan buttons; the extension never captures screenshots.

## Supported behavior

- **Current-context chat:** Chrome supplies fresh bounded visible-page text through the extension, without requiring Screen Recording or Accessibility access. Other apps use bounded Accessibility reads off the UI thread. A question about a visible image, chart or layout, or a window without meaningful readable text, adds an image of that window when Screen Recording is available. Unavailable images are disclosed to the model rather than implied. Tab, document, route, and content checks reject stale evidence.
- **Proactive protection:** page content and likely link/form destinations are checked ahead of interaction. Ordinary actions proceed while unknown or pending. Only a fresh, exact high-risk action assessment can block that supported action.
- **Avatar warnings:** risk explanations and acknowledgment controls live beside Muse, not inside websites or extension popups. A high-risk warning remains until **Got it**. Hidden Muse returns for a serious warning, then restores the hidden preference after acknowledgment. Acknowledging never approves or replays a dangerous action. Back and Stop reply do not acknowledge a warning.
- **Placement:** drag Muse to choose **Keep here**, use **Automatic placement** for window/pointer-based edge placement, or hide the avatar. These choices live under Appearance; Guard, Headphones and Just Muse change the outfit only. A pinned avatar naps in place.
- **Activity:** spy glasses indicate active browser or desktop protection. A temple adjustment marks actual inference. User inactivity triggers the approved yawn, bed and sleep sequence independently of monitoring. Routine browser and desktop outcomes and failures appear in **Recent activity**. Closing chat preserves its history; **New chat** clears it.
- **Automatic desktop watch:** after Accessibility or Screen Recording access is granted and the model is ready, Muse checks the active app without opening chat or enabling a separate desktop switch. Meaningful Accessibility text uses the fast text-only path; fresh Chrome extension coverage skips duplicate native checks. Missing or predominantly visual evidence uses only an unambiguously identified current-window image, with no whole-desktop fallback. Changes of app trigger a fresh check, and routine checks run on a three-second cadence with one inference in flight. Visual attempts are limited to once per window every fifteen seconds. Unchanged assessed content is reused, and stale findings are discarded; small localized image changes are tolerated alongside exact text/source checks. Confirmed high risks include scams and concrete pending irreversible actions such as permanent deletion without recovery. Warnings remain beside Muse until acknowledged. Global Pause stops both browser and desktop checks; explicit chat remains available.

The extension covers supported main-frame clicks and form submissions. It cannot guarantee interception of redirects, browser UI actions, downloads, hostile page scripts, cross-origin frames, or every programmatic request. A user action can proceed before its verdict is ready. Desktop watch warns about visible risk; it does not intercept other apps’ clicks or keystrokes and cannot guarantee detection before an action. Unknown/unavailable content is not described as safe. Placement is a window/pointer heuristic, not semantic understanding of every control.

## Privacy and local operation

After installation, analysis runs on this Mac. The extension excludes entered field values, editable/private/hidden regions, cookies, and embedded frames from text extraction. Analysis URLs lose credentials, query strings, and fragments; complete navigation URLs stay inside Chrome. Native visual checks and chat capture only the selected window when needed and permission already exists; other desktop windows are excluded.

Raw page text and images are transient. Protection/pause preferences persist; verdict logs remain in app-session memory and may contain sensitive excerpts. Bounded inference diagnostics contain timing/count metadata, not prompts, URLs, images, answers, or credentials. `scripts/inference-timings.py` summarizes those measurements.

Chrome communicates through native messaging and a same-user private Unix socket. The extension never receives the model credential. The local API key is mode `0600` inside a mode `0700` model directory. Release builds exclude the avatar from screen capture; the capture-test override is available only in development builds.

## Verify

```sh
./scripts/check.sh
(cd BrowserExtension && npm ci --ignore-scripts && npm test)
./scripts/check.sh --local-model
```

The first command checks avatar provenance/geometry, model configuration, motion, warning acknowledgment, streaming, privacy, context freshness, scheduling/cancellation, the browser protocol, and native host. The last command additionally runs synthetic text/vision cases through the installed local model. It needs a running ready model; the other checks do not start inference. Results and generated products stay under ignored `build/`.

Development tools remain in [Development/](Development/README.md):

```sh
./run-dev.sh --studio --mock-lab
```

Quit an already running Muse instance before launching a rebuilt one. `run-dev.sh --build-only` compiles without opening the app. The development build uses the existing `build/Run/SentinelPet.app` path.

## Avatar source and attribution

[Unreal/AVATAR_SOURCE.md](Unreal/AVATAR_SOURCE.md) pins the bundled approved model and animations. `MUSE_AVATAR_SOURCE` can explicitly select another Unreal project; a sibling checkout is never selected implicitly. Builds stage derived/generated files outside the tracked source tree.

The community **Meta Muse – Jolly** mesh is by [MadDog2125](https://makerworld.com/en/models/3441016-meta-muse-jolly), rather than an official Meta asset. Original STLs are retained under `Assets/Source/MuseJolly`. The source and mesh derivatives retain **CC BY-NC-SA 4.0** attribution and licensing; see `Unreal/MuseGuard/Content/Muse/ATTRIBUTION.txt` and `Jolly.json`. Required runtime materials, geometry inputs, and preparation scripts are retained for reproducibility.

### Round glasses

Muse wears fitted round black-metal frames with clear lenses, derived from [Coco Jinjo’s free glasses](https://sketchfab.com/3d-models/glasses-45bd43443daa4b65b5511aed74422338). The source and glasses derivatives are CC BY-NC 4.0; see `Assets/Source/CocoJinjoGlasses/ATTRIBUTION.txt`. Put-on, removal and temple-adjustment animations use the existing attachment.

Regenerate the fitted mesh with `uv run --with trimesh --with numpy --with scipy --with fast-simplification python scripts/prepare-round-glasses.py`. The renderer build prepares missing glasses materials using `Unreal/MuseGuard/Scripts/prepare_glasses_materials.py`.
