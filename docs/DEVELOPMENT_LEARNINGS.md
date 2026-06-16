# Development Learnings

These notes capture the practical issues we hit while building Sentinel Pet.
Use this as the first stop when the app appears to be working in code but fails
locally on macOS.

## Local Run Path

- Use `./run-dev.sh` for local development.
- It builds and launches `build/Run/SentinelPet.app`.
- Grant Accessibility permission to that exact app bundle path:

```text
/Users/fork/pet/bot/build/Run/SentinelPet.app
```

Avoid running the bare executable directly for permission testing. It can start
the SwiftUI app, but macOS privacy permissions are tied to app identity, bundle,
path, and signing.

## Accessibility Permission

If Sentinel Pet is enabled in System Settings but the app still says
Accessibility is inactive, check these in order:

1. Restart the app after granting permission:

```sh
./run-dev.sh
```

2. Verify the running process is the expected bundle:

```sh
ps -axo pid,stat,etime,command | rg '/SentinelPet( |$)|SentinelPet.app'
```

3. Verify the signing requirement is stable:

```sh
codesign -dr - build/Run/SentinelPet.app
```

For development, the requirement should look like an identifier plus Apple
Development certificate, not only a `cdhash`.

4. If the grant is stale, reset only this app and add it again:

```sh
tccutil reset Accessibility com.sentinelpet.app
```

Then open System Settings > Privacy & Security > Accessibility, add:

```text
/Users/fork/pet/bot/build/Run/SentinelPet.app
```

Toggle it on, then run:

```sh
./run-dev.sh
```

## Signing And TCC

Ad-hoc signing was the main source of the confusing Accessibility failure.
With ad-hoc signing, macOS stored a code requirement based on a build-specific
`cdhash`. Each rebuild changed the hash, so System Settings could show
`SentinelPet` as enabled while `AXIsProcessTrusted()` returned false for the
newly rebuilt process.

The fix was to sign the dev bundle with a stable Apple Development identity in
`run-dev.sh`. If no Apple Development identity is available, the script falls
back to ad-hoc signing, and Accessibility may need to be re-granted after
rebuilds.

Useful checks:

```sh
security find-identity -v -p codesigning
codesign -dv --verbose=4 build/Run/SentinelPet.app
codesign -dr - build/Run/SentinelPet.app
```

## Keychain During Development

Keychain storage repeatedly prompted for the login keychain password during
local iteration. For now, the Fireworks API key is stored in development
preferences through `DevCredentialStore`.

This is intentionally a development tradeoff. Before shipping:

- Restore Keychain-backed secret storage.
- Make sure Keychain reads/writes do not prompt repeatedly.
- Revisit the app signing, hardened runtime, and entitlements through the
  generated Xcode project.

## Accessibility UX

Do not trigger the Accessibility permission prompt from `Analyze focused
window`. That made the app feel broken because clicking Analyze reopened System
Settings instead of explaining the current state.

Current behavior:

- `Enable accessibility access` requests the permission.
- `Open Accessibility Settings` opens the settings pane explicitly.
- `Analyze focused window` shows a pet message if Accessibility is not active.

## Screen Recording Permission

Manual screenshot analysis uses macOS Screen Recording permission. Keep it
separate from Accessibility:

- `Enable screen recording access` requests Screen Recording permission.
- `Open Screen Recording Settings` opens the settings pane explicitly.
- `Analyze screenshot` shows a pet message if Screen Recording is not active.
- After granting permission, restart with `./run-dev.sh` so the running process
  has the new TCC grant.

The dev bundle needs `NSScreenCaptureUsageDescription`. Keep that string in both
`project.yml` and the generated plist inside `run-dev.sh`; otherwise Xcode builds
and direct dev runs can behave differently.

Screenshots are captured for the manual `Analyze screenshot` action. If that
first screenshot verdict is medium/high risk, Sentinel Pet automatically tells
the user it is running high-detail verification, captures multiple higher-quality
frames, and sends them as a second Fireworks request.

Continuous monitoring is text-first. It can add a single downscaled screenshot
only when all of these are true:

- Monitoring consent is enabled.
- Meeting screenshot context is enabled in Settings.
- Screen Recording access is active.
- The focused app/window/text looks like a meeting or video-call context.
- The snapshot does not match the sensitive deny list.

## Build And Typecheck

When XcodeGen is not installed, the sources can still be checked with `swiftc`.
Redirect the module cache to a writable location if the compiler tries to use a
blocked cache path:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/pet-run/ModuleCache xcrun swiftc -swift-version 5 -typecheck ...
```

The repo still uses `project.yml` as the intended project source. For a full
Xcode workflow, install XcodeGen and generate the project.

## Fireworks Analysis

Manual risk analysis sends focused-window text to Fireworks only when the user
chooses `Analyze focused window`.

Current development defaults:

- Model: `accounts/fireworks/models/kimi-k2p7-code`
- API key storage: `DevCredentialStore` in `UserDefaults`
- Endpoint: `https://api.fireworks.ai/inference/v1/chat/completions`
- Request shape: OpenAI-compatible messages with typed content parts. The
  focused-window analyzer sends text parts. Manual screenshot analysis sends the
  same context plus an `image_url` part containing a downscaled JPEG data URL.
  Medium/high screenshot verdicts trigger a second high-detail verification
  request with multiple chronological `image_url` frames.
  Monitoring can optionally use one `image_url` part for detected meeting/call
  contexts; it falls back to text-only if screenshot capture fails.
- Response mode: JSON object parsed into `RiskVerdict`
- Follow-up chat uses the same Fireworks endpoint, returns plain text, and is
  grounded in the latest verdict metadata: source, app/window name, risk level,
  categories, summary, and guidance. It does not include raw screen text or
  screenshot bytes.
- Logs: verdicts and model errors are kept in a session-only scrollable logs
  window. Raw screen text and screenshots are not stored in the log.

Before continuous monitoring:

- Add explicit onboarding and consent.
- Add a sensitive-app deny list.
- Add pause controls and a visible scanning indicator.
- Avoid persisting raw screen text.

## Continuous Monitoring

Continuous monitoring is opt-in from the menu. It does not start automatically
on launch.

Current behavior:

- `Start monitoring` requires Accessibility and a Fireworks API key.
- `Start monitoring` also requires the monitoring consent checkbox in Settings.
- The loop samples the focused window every 45 seconds.
- It fingerprints normalized focused-window text and skips duplicate screens.
- It skips app/window names that match the sensitive deny list before sending
  text to Fireworks.
- If meeting screenshot context is enabled and Screen Recording is active, the
  loop can send one downscaled screenshot with detected meeting/video-call
  contexts.
- Safe and low-risk verdicts update status silently.
- The sensitivity setting controls which risk levels show a pet intervention
  bubble.
- Accessibility or missing-key failures stop the loop.
- Transient read/model errors are shown once and then de-duplicated.

## Privacy Controls

Current privacy controls are deliberately simple:

- Monitoring consent is required before continuous monitoring starts.
- Meeting screenshot context requires separate settings consent and Screen
  Recording access.
- Manual and continuous analysis both skip snapshots matching the deny list.
- Deny-list matching checks the focused app name and focused window title.
- Manual screenshot analysis applies the deny list when focused-window context
  is available through Accessibility. If Accessibility is unavailable, the app
  can still analyze a manually requested screenshot, but it cannot identify the
  foreground app for deny-list matching.
- Sensitivity changes which risk levels interrupt the user:
  - Low sensitivity: high risk only.
  - Standard sensitivity: medium, high, and unknown.
  - High sensitivity: low, medium, high, and unknown.
- Fireworks API keys are still stored in development preferences, not Keychain.
- Session logs record app/window metadata, model, source, verdict, and errors.
  They intentionally do not store raw focused-window text or screenshot bytes.
- High-detail verification frames are sent to Fireworks but are not persisted.
  The pet displays a message while that verification is happening.
- Medium, high, and unknown verdict bubbles stay pinned until dismissed. After a
  pinned bubble is dismissed, idle thoughts may resume.

## Known Good Recovery Sequence

When the app gets stuck in an Accessibility mismatch:

```sh
cd /Users/fork/pet/bot
tccutil reset Accessibility com.sentinelpet.app
./run-dev.sh
```

Then add this exact app in Accessibility settings:

```text
/Users/fork/pet/bot/build/Run/SentinelPet.app
```

Toggle it on and run `./run-dev.sh` once more.
