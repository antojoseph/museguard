# Muse Guard

A native macOS desktop guardian with a live Unreal Engine 3D Muse character and local Muse Glimmer vision/text analysis. Risky findings make Muse jump toward the active window, raise both palms, explain the concern, and return home when dismissed.

The companion uses the approved avatar from the sibling `../museguard/Unreal/MuseGuard` project when available, with the same approved snapshot bundled in `Unreal/MuseGuard` for a standalone checkout. Its pinned source commit is recorded in [Unreal/AVATAR_SOURCE.md](Unreal/AVATAR_SOURCE.md). `MUSE_AVATAR_SOURCE` can select another copy of that avatar project. Default builds do not modify the separate avatar repository.

## Chrome: text checks and visual checks

`BrowserExtension/` is a Manifest V3 extension with two local analysis paths:

- **Text:** visible page text and public link/form metadata are checked proactively across normal HTTP/HTTPS tabs by default. Visible sensitive forms and likely link destinations are checked ahead of interaction. Ordinary actions proceed immediately; a supported action is stopped only when its exact public context has a fresh, model-confirmed high-risk result.
- **Visual:** **Check screenshot** in the popup explicitly captures the active tab and sends that image plus page text to the same local vision model. It does not turn on continuous screenshot monitoring.

Automatic protection interrupts only for confirmed high risk. Medium, unknown, unavailable and pending results do not pause ordinary browsing and are never described as safe. Exact action findings expire after 30 seconds and are invalidated when the document, public page content, destination, method, label or field types change. A page-level finding does not approve or block every action on that page. Model work uses a bounded, coalescing queue with foreground and likely-action priority, rather than starting an inference for every click or tab at once.

All security explanations belong to Muse's native speech/chat panel. The page receives no warning card, backdrop or injected controls, and the Chrome popup shows only setup, connection, check status and global pause controls. Confirmed high-risk actions cannot be continued from Muse's warning. A fresh cached high finding can show Muse again after an earlier warning was dismissed, without asking the model to repeat the same analysis.

High-risk warnings require **Got it** on Muse's speech bubble or chat. Muse stays in front until that exact warning is acknowledged; page navigation, routine updates, browser cleanup and expired action receipts cannot dismiss it or return Muse home. Acknowledging dismisses the explanation, and never approves a dangerous action. Explicit Hide still hides Muse; showing it again restores the pending warning. The warning is held in memory for the app session.

The warning card separates the finding from the next step and keeps **Got it** in a fixed footer. Placement reserves Muse's rendered silhouette and a 24-point gap, prefers a side position after landing, and falls back above or below on narrow displays. The card stays still while reading; long explanations scroll inside it.

Browser protection keeps Muse awake and wearing fitted 3D spy glasses across tabs and gaps between checks. A brief temple adjustment marks actual model work while already on duty. The extension renews a metadata-only protection lease every 30 seconds; Pause/Disable clears it immediately, and a missing connection expires after 90 seconds. The inference signal remains separate and covers browser checks, manual text/screenshot analysis, enabled desktop monitoring and follow-up answers. Heartbeats, queued data and cached results never claim that inference is running. When browser protection is off, a standalone model request still puts the glasses on and removes them after completion. Started gestures finish cleanly, and a new request during removal reverses the same path. Warnings, travel, explicit previews and Hide retain priority. Reduce Motion uses static fitted/stowed glasses. Only state flags reach the renderer; source evidence remains with the local analyzer.

Use **Pause for 30 minutes** for automatic resumption, or **Pause until resumed** for an indefinite pause. The deadline is saved and reconciled on worker startup, configuration reads and a [Chrome alarm](https://developer.chrome.com/docs/extensions/reference/api/alarms). A sleeping Mac resumes the overdue pause when it wakes. Screenshots remain an explicit button action; the native whole-screen monitor retains its separate consent and pause state.

On this Mac, initial synthetic text checks took about **8–14 seconds**, and a synthetic screenshot check took about **25 seconds**. These are observed development timings, not latency guarantees. Text inference runs ahead of interaction. An action taken before its verdict is available may proceed: this version favors uninterrupted browsing over guaranteed interception. Browser text uses bounded direct-answer JSON mode; visual checks keep full analysis.

The extension uses [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), not an open browser-to-model HTTP endpoint. Its native host forwards bounded, correlated messages over a same-user Unix socket. The local model's API key stays inside the native app. URLs lose credentials, query strings and fragments before analysis; text extraction excludes inputs, textareas, editable/private regions and hidden content. Raw page text and screenshots are transient; only protection and pause settings persist and popup results are session-only.

Build and prepare a reviewable install package:

```sh
./run-dev.sh --build-only
python3 scripts/install-browser-host.py
```

The second command writes **only** `build/BrowserInstall/`; it does not register Chrome access. Register its exact origin with `python3 scripts/install-browser-host.py --install`, then load the `BrowserExtension/` folder from Chrome's **Extensions → Developer mode → Load unpacked**. The stable extension ID is `omkmeoiobbgmdfhjbhbkjmmhcigkogka`. Open the companion and wait for the local model. Text monitoring starts automatically across normal web tabs; no per-site enable step is required. Existing installs preserve an explicit global-off preference. **Check text** and **Check screenshot** can also be run explicitly.

This guard does not intercept Chrome's address bar, redirects, browser downloads, cross-origin frames, hostile page scripts or every programmatic navigation. Unsupported or unassessed actions proceed without a safe verdict. LLM verdicts are fallible. The native avatar by itself cannot intercept browser input; enforcement is performed by the extension.

The character uses the downloaded **Meta Muse – Jolly** 3D mesh by [MadDog2125](https://makerworld.com/en/models/3441016-meta-muse-jolly). Its original geometry is rendered live in Unreal with a twelve-bone deformation rig, rounded subdivision surfaces, volume-preserving shoulder deformation, blinking, breathing, head tracking, scanning, anticipation, flight, landing, guard and explain poses. Continuous plush arms with softly rounded ends replace the printable hands. Guard cap, badge and focus headphones are separate removable 3D accessories. No sprite sheets or prerecorded character video are used.

Original STLs and attribution are in `Assets/Source/MuseJolly`. The source and derived mesh are **CC BY-NC-SA 4.0**; credit MadDog2125 and preserve the same license for mesh derivatives. The downloaded model is a community model of the Muse character, not an official Meta asset.

## Run

Development requirements: Apple Silicon Mac, Xcode command-line tools, Unreal Engine 5.8, Python 3, and the Hugging Face `hf` CLI. Tested on an M5 Max with 128 GB RAM and Unreal 5.8.4. The Q4_K_M model, vision projector and DFlash draft occupy about 20 GB; runtime memory is higher. The current renderer uses the installed Unreal editor runtime, so this is a development build, not a standalone distributable.

```sh
# One-time download from official llama.cpp and Meta model releases:
./scripts/setup-local-model.sh

# Build and open the character studio plus synthetic test lab:
./run-dev.sh --studio --mock-lab

# Normal menu-bar companion:
./run-dev.sh
```

The app starts the local model automatically. Wait for “Muse Glimmer · on this Mac,” then choose an example in Mock Lab and click **Analyze example**. Mock Lab needs no Accessibility or Screen Recording permission. It exercises the same analyzer, verdict presentation, logs, and jump/stop/return path used by real analysis. Studio switches **Guard / Focus / Just Muse**, offers **Live / Idle / Looking / Stretch / Sleep / Guard / Explain** animation previews, and runs the complete desktop jump-and-stop sequence. Real app events take priority over preview poses. Reduce Motion suppresses ambient body motion and shortens desktop travel.

Local launches retain the Q4_K_M target and vision projector, and use the matching DFlash draft from the same pinned model revision with at most three draft tokens. Both models run on Metal. Setup verifies the draft checksum; app readiness checks the running server's target path and live speculative slot, so an older non-DFlash server is not silently accepted. The launch arguments fix DFlash mode and the three-token limit. After upgrading, stop any separately started local server and reopen Muse Guard; the app only stops server processes it owns.

`MUSE_UNREAL_ROOT` can override `/Users/Shared/Epic Games/UE_5.8`. The approved renderer project is staged in `~/Library/Application Support/MuseGuard/Renderer`; weights and llama.cpp live in `~/Library/Application Support/MuseGuard/LocalModel`. Default builds do not alter the source avatar repository. Model weights, build products, and credentials are excluded from Git. The native bundle remains `build/Run/SentinelPet.app` to preserve its existing permission identity.

Drag the desktop avatar to pin its resting spot; a click opens chat. Placement is saved across launches and clamped to the visible character silhouette with a small edge margin, not the transparent render canvas. Speech/chat uses a separate, content-sized panel and chooses an above/below/side position without pushing the avatar away from a corner. Idle chatter is silent after the brief greeting.

Idle motion includes a gentle weight shift, curious head turn, and arm stretch. Walking adds a subtle, damped plush jiggle that settles after stopping; Reduce Motion disables it. Muse summons a small 3D star wand for creating and dismissing the bed, keeps it full size during the magic gesture, then stows it. The wand stays hidden during ordinary poses, sleep and travel. When browser protection is off, after 28 seconds without a companion interaction Muse gets drowsy; after 55 seconds it yawns with closed eyes and a hand over its mouth, walks to a quiet corner (walking across first and climbing hand-over-hand for an ascent), then reaches onto its bed and settles face-down with its head turned to the side. The corner is chosen once per nap from active-window overlap and the last 30 seconds of pointer activity; it stays put while sleeping. This is a placement heuristic, not an interpretation of the user's screen content. The camera orbits to a side view, and the back and pillow move subtly with breathing. Guard accessories tuck away during sleep. The plush body relaxes against the mattress, with the hands beside the pillow and the feet lowered; the standing rump volume softens in the prone pose. These timers track the companion's idle state, not the user's keyboard activity. Clicking, dragging, analysis, or an intervention wakes Muse; a sleeping guardian gets up before its warning jump. Studio's **Nap in a quiet corner** runs the whole sequence immediately; **Sleep** previews the yawn and bed locally, and **Live** restores automatic behavior. Reduce Motion skips the walk and animated settling. Monitoring is unchanged.

**Stay out of my way** (menu bar, Studio, or avatar context menu) enables automatic placement. It samples frontmost-window bounds and pointer positions once per second, scores eight screen-edge positions, and prefers exposed space away from the last eight seconds of pointer activity. It uses no screenshots, text extraction, keystroke monitoring, or new permission prompts. A minimum score improvement and a twelve-second cooldown limit repositioning; Muse fades between resting spots rather than repeatedly jumping. It stays still during clicks, hovering over Muse, dragging, chat, analysis messages, and interventions. Dragging pins the chosen spot and disables automatic placement until you turn it back on. On a full-screen app, this is a least-obstructive-edge heuristic, not semantic knowledge of every control or guarantee of zero overlap.

You can also drag the guardian after it lands; dismissal returns it to that newly chosen spot. Right-click the avatar and choose **Hide Muse**, or use **Hide Muse / Show Muse** in the menu bar or Studio. Hiding removes the avatar and messages immediately, cancels any jump/reposition, and persists across launches until explicitly shown. Incoming verdicts cannot make a hidden avatar reappear. Hiding changes presentation only; monitoring remains at its existing setting.

Chrome page context and browser protection use the installed extension and need no macOS Accessibility or Screen Recording permission. For other apps, grant Accessibility for focused text or Screen Recording for screenshots. Continuous desktop monitoring additionally requires consent in Settings and an explicit start from the menu. It samples at ten-second intervals, skips unchanged/denied windows, and allows only one monitoring inference at a time. The app uses an Apple Development signing identity when available, otherwise ad-hoc signing; macOS may require permission renewal after rebuilds.

## Local inference

Chat gathers fresh context for every question. For Chrome it requests bounded visible text from the extension's current tab, with tab/document/navigation checks before delivery. Other apps use their current window's accessible text; a window-only image is a fallback when text is insufficient and Screen Recording access already exists. A small chat label identifies the source. Secure text fields and denied apps/windows are skipped, page content is treated as untrusted evidence, and conversation history is scoped to the current source. Previous risk reports are optional historical context rather than a requirement to chat. Context replies expire after six seconds and are not logged or persisted.

Chat shows visible answer text as it arrives in one updating message. Text-only chat uses Muse's answer-channel continuation, avoiding a separate hidden-thinking pass without forcing any answer words. Image chat retains the full analysis path. Whitespace-only stream chunks do not create an answer bubble or count as first visible text. Hidden reasoning stays out of the transcript. An interrupted partial answer is marked incomplete and is not added to model history. Risk verdicts remain buffered until the complete structured response passes validation.

All tabs keep their document, route and viewport watchers, while successful unchanged pages no longer trigger periodic inference. Non-high evidence may be reused for up to five minutes; exact high-risk blocking receipts keep their separate thirty-second limit. Sensitive form intent takes precedence over routine scans without interrupting active chat. Navigation and replaced evidence cancel obsolete model work. A saturated queue makes room for user requests by dropping lower-priority queued work.

Local diagnostics retain at most 128 inference records in `~/Library/Application Support/MuseGuard/Diagnostics/inference-metrics.json`. Records separate native queue wait, request duration, first visible answer, server prompt/generation timing and token counts when available, plus completion/cancellation status. They contain no page text, URLs, titles, answers, screenshots or credentials. Diagnostic writes are private and coalesced; a logging failure never retries or prevents inference.

Run `python3 scripts/inference-timings.py` for median and p90 timings by operation. First-text timing begins when the model HTTP request starts; context collection and native queue wait are separate from that measurement. Only completed requests contribute latency percentiles, while cancellations and failures are counted separately.

- Official [Muse Glimmer 30B GGUF](https://huggingface.co/meta-models/Muse-Glimmer-30B-GGUF), Q4_K_M model plus multimodal projector, pinned revision in `scripts/setup-local-model.sh`.
- Official llama.cpp `b11946` Apple Silicon release, Metal acceleration, 16K context and one slot. Requests use low reasoning strength. The configured 256-token reasoning budget is not enforced by this version's specialized Muse parser because it omits thinking-end tags; text chat instead uses the supported answer-channel continuation. See the pinned [Muse parser](https://github.com/ggml-org/llama.cpp/blob/b11946/common/parsers/muse-glimmer.cpp) and [request-budget handling](https://github.com/ggml-org/llama.cpp/blob/b11946/tools/server/server-common.cpp).
- Authenticated HTTP on `127.0.0.1:8787` only. Requests reject redirects. No Fireworks client, cloud API key setting, or cloud fallback remains.
- Structured JSON risk verdicts; incomplete or malformed answers are errors, never automatic safe verdicts. Chat uses fresh screen context and bounded source-scoped history.
- The app stops server processes it started. A separately started matching local server can be reused and remains independently managed: `./scripts/start-local-model.sh`.

## Architecture

| Component | Responsibility |
| --- | --- |
| `Unreal/MuseGuard` | Imported Jolly mesh, weighted shoulders/head/feet, facial deformation, separate accessory meshes, lighting and transparent offscreen capture. |
| `UnrealCharacterRenderer` | Owns the Unreal process, validates RGBA frames and sends state/accessory/gaze commands through a private temporary directory. |
| `PetOverlayController` / `GuardianMotion` | Native home panel, stationary desktop scene, pointer hit testing, saved home position, and jump/stop/return lifecycle. |
| `SentinelPetRuntime` | Collects context, calls local inference, logs verdicts and emits intervention events. |
| `LocalModelService` / `LocalRiskAnalyzer` | Local server lifecycle, readiness checks, text/vision requests and report chat. |
| `MockScenario` / `MockLab` | Synthetic phishing, legitimate sign-in, gift-card, ordinary-message and prompt-injection cases. |
| `MonitorLoop` / `PrivacyFilter` | Consent-controlled periodic sampling, deny list and duplicate suppression. |

The committed `Content/Muse/Jolly.musemesh` loads without Python packages. The body is rebuilt on a uniform volumetric grid, smoothed and subdivided, with an elliptical torso replacing flat print panels and two broad rounded plush cheeks with a soft central fold and a continuous curve into the back and upper thighs. The deep printable face recess is filled into a shallow, gently convex panel; button eyes, the smile and yawn mouth are fitted to that surface. The guard outfit uses a fitted cap and chest insignia; the old intersecting cape placeholder has been removed. A matte plush material uses subtle, filtered fiber variation, with 40,000 finer curved, tapered 3D fur tufts with shaded roots, soft tips and a groom that follows the animated surface. The face stays smooth and the rounded soles use shorter plush fibers; fur follows the final corrected surface through bending and sleep poses. Sleep blends into a dedicated low bed-space shape with a rigid rounded head, tucked feet and horizontal forearms, rather than inheriting standing torso thickness. Peach fur, a pale smooth face panel, a round fur-covered tail, muted blue upholstered bedding and a rear three-quarter camera follow the plush reference; closing the eyes leaves the facial surface intact. Broader neck weights and corrective smoothing support the turned sleeping head; dual-quaternion skinning preserves the shoulders through large bends, smoothly blended pelvis weights keep the lower body continuous through a stride; hip/knee/ankle joints give the legs a planted crouch, toe push-off, airborne tuck and absorbing landing; continuous curved plush arms with broad forearms, rounded ends and subtle thumbs replace the print-derived limbs; broad wrist blending avoids a pinched cuff, and corrective smoothing softens the inside of bent joints. At home Unreal renders at 1280 × 1280 and resolves to a 640 × 640 transparent frame, so the 282-point Retina Studio preview never enlarges a smaller source. Intervention uses a stationary screen-sized transparent panel and a fixed perspective desktop camera. Screen anchors are unprojected at equal depths; the character stays at its resting size while travelling between the world points with a ballistic rise, knee tuck, early blocking palms, and an absorbing landing. An off-axis camera crop renders only the occupied 320 × 320 point region at 1280 × 1280, then resolves it to 640 × 640: two output pixels per desktop point throughout the journey, independent of desktop size. Version 2 frames carry the crop rectangle alongside the pixels; SwiftUI composites that region without stretching a low-resolution desktop image. The crop follows the projection of the real 3D trajectory; it does not supply the jump motion. Home frames retain version 1. Dismissal reverses the same world-space journey. The warning appears beside Muse after landing, rather than moving with it. Frame flags synchronize the home/desktop surface handoff. Jump phases share a clock with the desktop controller. Pose transitions use damped easing, and the preview recorder retains every transition at a constant 30 fps. To regenerate it after changing the rig weights or facial material regions:

```sh
uv run --with numpy --with trimesh --with scipy --with shapely --with mapbox-earcut --with triangle --with scikit-image --with fast-simplification python scripts/prepare-muse-mesh.py
python3 scripts/check-muse-mesh.py
```

This is a lightweight runtime deformation rig for the downloaded printable mesh, not a supplied skeletal/FBX animation package. The printable source’s fused underarms are separated and capped for articulation. Its arms are rebuilt as closed plush surfaces with subtle thumbs; independent finger articulation is not supported.

Accessories are separate components selected by entries in `Unreal/MuseGuard/Config/MuseAccessories.json`. Add new accessory geometry under its named group and a configuration entry; the base character and motion rig can remain unchanged.

Guard accessories are fitted meshes generated by `scripts/prepare-guard-accessories.py`: a structured navy cap with close headband, curved visor, gold braid and matching shield emblem; the larger chest shield has a beveled gold rim, navy enamel face and raised silver star. Meshes remain separate from the character rig and switch off with the Guard outfit. To regenerate them:

```sh
uv run --with numpy --with trimesh --with scipy --with networkx python scripts/prepare-guard-accessories.py
```

## Verification

```sh
./scripts/check.sh                  # Frame protocol, motion and response validation
uv run --with pillow --with imageio-ffmpeg python scripts/preview-idle-sleep.py # Render sleep/wake checks + video
uv run --with pillow --with imageio-ffmpeg --with numpy --with scipy python scripts/preview-locomotion.py # Walking/climbing + side/rear joint inspection
./scripts/check.sh --local-model    # Also run real local vision/text + follow-up cases
uv run --with pillow --with imageio-ffmpeg python scripts/preview-animations.py  # Check close-up rig poses and foot planting
uv run --with pillow --with imageio-ffmpeg python scripts/preview-desktop-jump.py  # Fixed-size Retina jump, world trajectory, crop bounds, endpoints, early stop pose and real-time MP4
```

The first command also checks source hashes, attribution, mesh topology, finite normals and normalized skin weights. The local model must be ready for the second command. Synthetic results are written to `build/local-model-results.json`. `--visual-test` additionally makes the overlay capturable and writes motion event coordinates to the system temporary directory for development verification. Normal mode excludes the overlay from screen captures.

The native companion warns and the optional paired Chrome extension holds supported browser actions. Neither guarantees that content is safe. The jump targets the active Chrome window center; precise form/button targeting is not implemented. Synthetic checks are a smoke test, not a detection benchmark. Local inference takes seconds, so the extension keeps a supported action paused during its check. Screenshot-only evidence cannot establish that media is a deepfake; the previous cloud multi-frame escalation is not automatically run.

## Privacy

Analysis stays on this Mac after installation. Monitoring starts paused; permission and local-monitoring consent are separate. Sensitive app/window names can be denied in Settings. Raw screen text and screenshots are not persisted by the application; verdict summaries exist in session-only logs and can themselves contain sensitive excerpts. Follow-up questions include verdict metadata rather than raw captures. The renderer receives only animation state, accessory selection, gaze and a heartbeat. The local API key is generated with mode `0600` in an application directory with mode `0700`.

`docs/DEVELOPMENT_LEARNINGS.md` records historical development notes for the original cloud-backed prototype; current setup and behavior are described here. `project.yml` still provides the native XcodeGen target, but use `run-dev.sh` to prepare the Unreal bridge resources and build both components.
