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
  current analyzer sends text parts only; the client shape can be extended with
  image URL parts when screenshot or media analysis is added.
- Response mode: JSON object parsed into `RiskVerdict`

Before continuous monitoring:

- Add explicit onboarding and consent.
- Add a sensitive-app deny list.
- Add pause controls and a visible scanning indicator.
- Avoid persisting raw screen text.

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
