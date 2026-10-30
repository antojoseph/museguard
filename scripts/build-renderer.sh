#!/usr/bin/env bash
set -euo pipefail
MUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUSE_ENGINE="${MUSE_UNREAL_ROOT:-/Users/Shared/Epic Games/UE_5.8}"
MUSE_AVATAR_SOURCE="${MUSE_AVATAR_SOURCE:-$MUSE_ROOT/Unreal/MuseGuard}"
if [[ ! -f "$MUSE_AVATAR_SOURCE/MuseGuard.uproject" ]]; then
  echo 'Muse avatar source is missing. Set MUSE_AVATAR_SOURCE to the approved Unreal/MuseGuard project directory.' >&2
  exit 1
fi
MUSE_AVATAR_SOURCE="$(cd "$MUSE_AVATAR_SOURCE" && pwd)"
MUSE_PROJECT="$MUSE_AVATAR_SOURCE/MuseGuard.uproject"
if [[ ! -x "$MUSE_ENGINE/Engine/Binaries/Mac/UnrealEditor" ]]; then
  echo 'Unreal Engine 5.8 is required. Set MUSE_UNREAL_ROOT to its installation directory.' >&2
  exit 1
fi
mkdir -p "$MUSE_ROOT/build"
# Unreal resolves every parent directory of its project. Keep its build/runtime
# project in Application Support so it does not need Documents access.
MUSE_STAGE="$HOME/Library/Application Support/MuseGuard/Renderer"
mkdir -p "$MUSE_STAGE"
for item in Source Content Config Scripts; do
    mkdir -p "$MUSE_STAGE/$item"
    rsync -a --delete "$MUSE_AVATAR_SOURCE/$item/" "$MUSE_STAGE/$item/"
done
cp "$MUSE_PROJECT" "$MUSE_STAGE/MuseGuard.uproject"
MUSE_PROJECT="$MUSE_STAGE/MuseGuard.uproject"
"$MUSE_ENGINE/Engine/Build/BatchFiles/Mac/Build.sh" MuseGuardEditor Mac Development "$MUSE_PROJECT" -waitmutex -NoHotReload -architecture=arm64 > "$MUSE_ROOT/build/unreal-build.log" 2>&1 || { tail -60 "$MUSE_ROOT/build/unreal-build.log"; exit 1; }
if [[ "${MUSE_REBUILD_ASSETS:-0}" == "1" || ! -f "$MUSE_STAGE/Content/Muse/M_MuseFur.uasset" || ! -f "$MUSE_STAGE/Content/Muse/M_MusePlush.uasset" || ! -f "$MUSE_STAGE/Content/Muse/M_GuardMetal.uasset" || ! -f "$MUSE_STAGE/Content/Muse/M_ContactShadow.uasset" || ! -f "$MUSE_STAGE/Content/Muse/M_AccessorySatin.uasset" || ! -f "$MUSE_STAGE/Content/Muse/M_Guardian.uasset" || ! -f "$MUSE_STAGE/Content/Muse/M_MuseCloth.uasset" || ! -f "$MUSE_STAGE/Content/Maps/MuseStage.umap" ]]; then
  "$MUSE_ENGINE/Engine/Binaries/Mac/UnrealEditor-Cmd" "$MUSE_PROJECT" -run=pythonscript -script="$MUSE_STAGE/Scripts/prepare_assets.py" -unattended -nosound -nullrhi -abslog="$MUSE_ROOT/build/unreal-assets.log" > "$MUSE_ROOT/build/unreal-assets-stdout.log" 2>&1
  # Missing runtime assets can be prepared in staging without changing either
  # source tree. Only an explicit rebuild saves derived assets into this app.
  if [[ "${MUSE_REBUILD_ASSETS:-0}" == "1" ]]; then
    rsync -a "$MUSE_STAGE/Content/" "$MUSE_ROOT/Unreal/MuseGuard/Content/"
  fi
fi
MUSE_RESOURCES="${MUSE_APP_RESOURCES:-$MUSE_ROOT/build/Run/SentinelPet.app/Contents/Resources}"
mkdir -p "$MUSE_RESOURCES"
python3 - "$MUSE_ENGINE" "$MUSE_PROJECT" "$MUSE_RESOURCES" <<'PY'
import json,sys,pathlib
engine,project,resources=sys.argv[1:]
pathlib.Path(resources,'MuseRenderer.json').write_text(json.dumps({'executable':engine+'/Engine/Binaries/Mac/UnrealEditor-Cmd','project':project}))
PY
echo "Unreal Muse renderer built from $MUSE_AVATAR_SOURCE."
