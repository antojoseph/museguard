#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/Run/SentinelPet.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
BIN="$MACOS/SentinelPet"
CACHE="${TMPDIR:-/tmp}/sentinelpet-module-cache"

mkdir -p "$MACOS" "$CACHE"
"$ROOT/scripts/build-renderer.sh"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>SentinelPet</string>
	<key>CFBundleIdentifier</key>
	<string>com.sentinelpet.app</string>
	<key>CFBundleName</key>
	<string>SentinelPet</string>
	<key>CFBundleDisplayName</key>
	<string>Muse Guard</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Sentinel Pet reads on-screen text to warn you about phishing, scams, and other risky situations.</string>
	<key>NSScreenCaptureUsageDescription</key>
	<string>Sentinel Pet captures screenshots only when you explicitly choose screenshot analysis, then analyzes that image locally on this Mac.</string>
</dict>
</plist>
PLIST

sources=()
while IFS= read -r -d '' source; do
	sources+=("$source")
done < <(find "$ROOT/Sources/SentinelPet" -name '*.swift' -print0)

CLANG_MODULE_CACHE_PATH="$CACHE" xcrun swiftc \
	-swift-version 5 \
	-target arm64-apple-macosx13.0 \
	-o "$BIN" \
	"${sources[@]}"

identity="${SENTINELPET_CODESIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
	identity="$(
		security find-identity -v -p codesigning |
		awk -F '"' '/Apple Development/ { print $2; exit }'
	)"
fi

if [[ -n "$identity" ]]; then
	codesign --force --deep --sign "$identity" "$APP"
else
	echo "warning: no Apple Development signing identity found; falling back to ad-hoc signing" >&2
	echo "warning: Accessibility permission may need to be re-granted after each rebuild" >&2
	codesign --force --deep --sign - "$APP"
fi

if [[ "${1:-}" == "--build-only" ]]; then
    echo "Built $APP"
    exit 0
fi

if pgrep -x SentinelPet >/dev/null 2>&1; then
	pkill -x SentinelPet || true
	sleep 0.5
fi

open "$APP" --args "$@"
echo "Launched $APP"
