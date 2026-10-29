#!/usr/bin/env bash
set -euo pipefail
MUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MUSE_ROOT"
mkdir -p build
python3 scripts/check-muse-mesh.py
python3 scripts/check-guard-accessories.py
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/avatar-checks Tests/AvatarChecks.swift Sources/MuseGuardStudio/GuardianMotion.swift Sources/MuseGuardStudio/UnrealCharacterRenderer.swift
./build/avatar-checks
