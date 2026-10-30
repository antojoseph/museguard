#!/usr/bin/env bash
set -euo pipefail
fixture_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_app="$fixture_root/build/ContextFixture.app"
mkdir -p "$fixture_app/Contents/MacOS"
cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ContextFixture</string>
  <key>CFBundleIdentifier</key><string>com.museguard.contextfixture</string>
  <key>CFBundleName</key><string>Muse Context Fixture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -warnings-as-errors \
    -parse-as-library "$fixture_root/Tests/Fixtures/ContextFixtureApp.swift" \
    -o "$fixture_app/Contents/MacOS/ContextFixture"
codesign --force --timestamp=none --sign - "$fixture_app"
printf 'Built context fixture: %s\n' "$fixture_app"
