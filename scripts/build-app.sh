#!/usr/bin/env bash
set -euo pipefail

MUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration=release
while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration)
            [[ $# -ge 2 ]] || { echo 'Missing build configuration.' >&2; exit 2; }
            configuration="$2"; shift 2 ;;
        --help)
            echo 'Usage: scripts/build-app.sh [--configuration release|development]'
            exit 0 ;;
        *) echo "Unknown build argument: $1" >&2; exit 2 ;;
    esac
done
case "$configuration" in
    release)
        app="$MUSE_ROOT/build/Release/MuseGuard.app"
        flags=(-O -whole-module-optimization) ;;
    development)
        app="$MUSE_ROOT/build/Run/SentinelPet.app"
        flags=(-Onone -D MUSE_DEVELOPMENT) ;;
    *) echo "Unknown build configuration: $configuration" >&2; exit 2 ;;
esac
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
    echo 'Muse Guard requires an Apple Silicon Mac.' >&2; exit 1;
}
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ]] || {
    echo 'Muse Guard and its Unreal renderer require macOS 14 or newer.' >&2; exit 1;
}

contents="$app/Contents"
binary="$contents/MacOS/SentinelPet"
cache="${TMPDIR:-/tmp}/muse-guard-module-cache"
mkdir -p "$contents/MacOS" "$contents/Resources" "$cache"
MUSE_APP_RESOURCES="$contents/Resources" "$MUSE_ROOT/scripts/build-renderer.sh"
cp "$MUSE_ROOT/Configuration/Info.plist" "$contents/Info.plist"

sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done < <(
    python3 - "$MUSE_ROOT" "$configuration" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
directories=[root/'Sources/SentinelPet']
if sys.argv[2]=='development':directories.append(root/'Development')
for path in sorted(p for directory in directories for p in directory.rglob('*.swift')):
    sys.stdout.buffer.write(str(path).encode()+b'\0')
PY
)
CLANG_MODULE_CACHE_PATH="$cache" xcrun swiftc \
    -swift-version 5 -target arm64-apple-macosx13.0 -warnings-as-errors \
    "${flags[@]}" -o "$binary" "${sources[@]}"

identity="${MUSE_CODESIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development/ { print $2; exit }')"
fi
if [[ -z "$identity" ]]; then
    identity=-
    echo 'Using local ad-hoc signing. Screen permissions may need renewal after a rebuild.' >&2
fi
codesign --force --options runtime --timestamp=none --sign "$identity" "$app"
codesign --verify --strict "$app"
echo "Built $configuration app: $app"
