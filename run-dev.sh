#!/usr/bin/env bash
set -euo pipefail
MUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$MUSE_ROOT/scripts/build-app.sh" --configuration development
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi
app="$MUSE_ROOT/build/Run/SentinelPet.app"
if pgrep -x SentinelPet >/dev/null 2>&1; then
    echo 'Quit the running Muse Guard app before launching the rebuilt development app.' >&2
    exit 1
fi
open "$app" --args "$@"
echo "Launched $app"
