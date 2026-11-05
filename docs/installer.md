# Muse Guard installer

The installer places Muse Guard in Applications on Apple Silicon Macs running macOS 14 or newer. It includes the cooked 3D renderer, the pinned llama.cpp server, and Chrome’s native host and unpacked extension. On first launch, **Get started** offers optional screen access for desktop checks, a resumable 19.8 GB model download, and Chrome setup. The installed app requests access when the user chooses a permission. Analysis runs on the Mac. [Installation steps](../README.md#install-muse-guard)

The package carries the avatar, glasses, Unreal Engine, and llama.cpp credits under `MuseGuard.app/Contents/Resources/Attribution`. The installer payload consists of the app bundle. Muse creates its local API credential on the destination Mac and registers the Chrome host when the user selects **Open Chrome setup**.

## Build a local installer

On the build Mac, install the [source build requirements](../README.md#build-from-source) and prepare the pinned inference runtime with `scripts/setup-local-model.sh` if it is missing. Then run:

```sh
./scripts/build-app.sh --configuration release
python3 scripts/build-installer.py
```

The package is written to `build/Installers/MuseGuard-0.1.0-arm64.pkg`. The builder uses the release app in `build/Release` and llama.cpp b11946 in the current user's Muse Guard model folder. Use `--app`, `--runtime`, or `--output-dir` to select other locations. The release build includes the renderer, so the packaging step can run without Unreal Editor when the release app has already been built.

The default package is unsigned and its app is ad-hoc signed. Use it for local testing. A downloaded copy can be blocked by Gatekeeper. For distribution, sign and notarize the package.

## Sign and notarize

Install both Developer ID identities in the build Mac’s keychain. Configure a `notarytool` keychain profile for the Apple Developer team. Then run:

```sh
python3 scripts/build-installer.py \
  --app-signing-identity 'Developer ID Application: Example (TEAMID)' \
  --installer-signing-identity 'Developer ID Installer: Example (TEAMID)' \
  --notary-profile 'MuseGuardNotary'
```

This signs the app and nested binaries, signs the package, submits it to Apple, and staples and validates the accepted ticket. Supply the two signing identities together. Omit `--notary-profile` to build a signed package for a separate notarization step. See [Apple’s Developer ID certificate guide](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) and [notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Verify the package

Installer preflight reads the package without installing it. Expand the payload to check its signatures and start the bundled server in version mode:

```sh
package='build/Installers/MuseGuard-0.1.0-arm64.pkg'
installer -pkg "$package" -target / -showChoicesXML
scratch="$(mktemp -d)"
pkgutil --expand-full "$package" "$scratch/expanded"
app="$scratch/expanded/MuseGuard-component.pkg/Payload/MuseGuard.app"
codesign --verify --deep --strict "$app"
"$app/Contents/Helpers/LocalInference/llama-server" --version
python3 Tests/PackagedRendererChecks.py \
  --app "$app/Contents/Helpers/MuseRenderer.app"
```

The renderer check denies access to Unreal Editor, the renderer source tree, and the network while the extracted helper renders frames. For a signed distribution, also run `pkgutil --check-signature "$package"` and `xcrun stapler validate "$package"`.
