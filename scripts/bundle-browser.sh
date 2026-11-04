#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 || ! -f "$1/Contents/Info.plist" ]]; then
    echo 'Usage: scripts/bundle-browser.sh <MuseGuard.app> <codesign identity or ->' >&2
    exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
contents="$1/Contents"
identity="$2"
helper="$contents/Helpers/muse-guard-host"
extension="$contents/Resources/ChromeExtension"
mkdir -p "$contents/Helpers" "$extension"

for file in manifest.json background.js content.js downloads.js popup.css popup.html popup.js secrets.js shared.js targets.js; do
    install -m 644 "$root/BrowserExtension/$file" "$extension/$file"
done

xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -warnings-as-errors \
    -parse-as-library -O -o "$helper" "$root/BrowserNativeHost/MuseGuardHost.swift"
timestamp=--timestamp
if [[ "$identity" == - ]]; then timestamp=--timestamp=none; fi
codesign --force --options runtime "$timestamp" --sign "$identity" "$helper"
codesign --verify --strict "$helper"
