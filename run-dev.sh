#!/usr/bin/env bash
set -euo pipefail
MUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUSE_APP="$MUSE_ROOT/build/Run/MuseGuardStudio.app"
MUSE_CONTENTS="$MUSE_APP/Contents"
MUSE_CACHE="${TMPDIR:-/tmp}/museguardstudio-module-cache"
mkdir -p "$MUSE_CONTENTS/MacOS" "$MUSE_CACHE"
"$MUSE_ROOT/scripts/build-renderer.sh"
cat > "$MUSE_CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MuseGuardStudio</string>
<key>CFBundleIdentifier</key><string>com.antojoseph.museguardstudio</string>
<key>CFBundleName</key><string>MuseGuardStudio</string>
<key>CFBundleDisplayName</key><string>Muse Guard Studio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
MUSE_SOURCES=()
while IFS= read -r -d '' MUSE_SOURCE; do MUSE_SOURCES+=("$MUSE_SOURCE"); done < <(find "$MUSE_ROOT/Sources/MuseGuardStudio" -name '*.swift' -print0)
CLANG_MODULE_CACHE_PATH="$MUSE_CACHE" xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o "$MUSE_CONTENTS/MacOS/MuseGuardStudio" "${MUSE_SOURCES[@]}"
codesign --force --deep --sign "${MUSE_CODESIGN_IDENTITY:--}" "$MUSE_APP"
if [[ "${1:-}" == "--build-only" ]]; then echo "Built $MUSE_APP"; exit 0; fi
open "$MUSE_APP" --args "$@"
echo "Launched $MUSE_APP"
