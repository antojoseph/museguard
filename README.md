# 🛡️ Sentinel Pet

A cute 8-bit Claude-style desktop pet for macOS that doubles as a **security
buddy**. It sits in the corner of your screen and — once fully built — watches
what you're doing, reads on-screen text via the macOS Accessibility API, asks an
LLM (Kimi K2 on [Fireworks.ai](https://fireworks.ai)) to judge whether the
situation is risky, and pops up with friendly guidance before you do something
you'll regret (reply to a phishing email, log in to a fake site, click a sketchy
link, fall for a scam, etc.).

> ⚠️ Work in progress. See the roadmap below for what's implemented.

## Status

- ✅ **Milestone 1 — Scaffold + pet overlay.** A draggable, always-on-top,
  animated pixel-art pet that floats over your other windows, runs as a
  menu-bar agent (no Dock icon), remembers its position, and shows speech
  bubbles. Everything after this is wiring.
- ✅ **Milestone 2 — Accessibility reader + permission flow.** Menu-bar actions
  can request Accessibility access and run a one-shot local read of the focused
  window's accessible text. Continuous monitoring and remote analysis are still
  planned.
- ✅ **Milestone 3 — Fireworks/Kimi settings + manual risk analysis.** Settings
  stores the Fireworks API key in development preferences for now, lets you
  choose the model, and can send the currently focused window's text to
  Fireworks for a JSON risk verdict. Continuous monitoring and production-grade
  secret storage are still planned.
- ✅ **Milestone 4 — Continuous monitor loop.** Start monitoring from the menu
  to periodically sample the focused window, skip duplicate text, and surface
  only medium/high/unknown findings through the pet.
- ✅ **Milestone 5 — Privacy controls.** Settings includes continuous-monitoring
  consent, alert sensitivity, and a sensitive app/window deny list. Monitoring
  can be paused from the menu.

## Building & running

For local development, use the stable app bundle runner:

```sh
./run-dev.sh
```

It launches `build/Run/SentinelPet.app`. For Accessibility permissions during
development, add that exact app path in System Settings. The dev runner signs
with the first available Apple Development identity so Accessibility permissions
survive rebuilds. If no development identity is available, it falls back to
ad-hoc signing and you may need to re-grant Accessibility after rebuilds.

If Accessibility, signing, or local settings get confusing, see
[`docs/DEVELOPMENT_LEARNINGS.md`](docs/DEVELOPMENT_LEARNINGS.md).

The Xcode project is generated from `project.yml` using
[XcodeGen](https://github.com/yonyz/XcodeGen) so the repo stays clean and
diff-friendly.

```sh
# One-time: install XcodeGen
brew install xcodegen

# Generate SentinelPet.xcodeproj from project.yml
xcodegen generate

# Open and run (⌘R) in Xcode
open SentinelPet.xcodeproj
```

Requirements: macOS 13+ and Xcode 15+.

When you run it, the pet appears in the bottom-right corner and greets you.
Drag it anywhere; it remembers where you put it. Use the 🛡️ menu-bar item to
request Accessibility access, configure Fireworks, read or analyze the focused
window once, or quit.

## Architecture (target design)

| Component | Responsibility |
|-----------|----------------|
| `PetPanel` / `PetOverlayController` | Borderless floating panel hosting the pet; dragging + position persistence. |
| `PetView` / `PetSprite` | Procedural 8-bit Claude mascot (no image assets) with bob + blink animations. |
| `SpeechBubbleView` / `PetViewModel` | Mood-aware speech bubble for greetings and interventions. |
| `AccessibilityPermissionController` / `ScreenReader` | Requests Accessibility trust and reads focused-window text via the Accessibility API. |
| `FireworksRiskAnalyzer` / `RiskVerdict` | Sends focused-window text to Kimi K2 on Fireworks; parses a structured JSON verdict. |
| `MonitorLoop` | Debounced continuous sampling, duplicate suppression, and periodic risk checks. |
| `InterventionEngine` *(planned)* | Turns risk verdicts into pet alerts with guidance. |
| `SettingsView` / `DevCredentialStore` | Development API key storage, model selection, consent, sensitivity, and sensitive app/window deny list. |

## Roadmap

1. ✅ Scaffold + animated pet overlay.
2. ✅ Accessibility screen reader + permission flow.
3. ✅ Fireworks/Kimi K2 client + development API key settings.
4. ✅ Continuous monitor loop wired to interventions.
5. ✅ Privacy controls: app/window deny list, pause, sensitivity, onboarding/consent.
6. ⬜ Deepfake & media support — contextual warnings first; optional
   screenshot/image URL parts later. The current app sends accessible text only.
7. ⬜ Polish: refined art, edge-snapping, intervention history.

## Privacy

This app is designed to read on-screen text and send it to a third-party API,
which is inherently sensitive. Today, it only sends focused-window text when you
choose **Analyze focused window** from the menu, or when you explicitly start
continuous monitoring after enabling consent in Settings. Current safeguards:
monitoring consent, a sensitive app/window deny list, no persistence of raw
screen text, duplicate suppression, visible menu status, and one-click pause.
Planned safeguards before broader use: client-side redaction of obvious secrets
and a production secret-storage path.
