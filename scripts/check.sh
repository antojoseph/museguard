#!/usr/bin/env bash
set -euo pipefail
MUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MUSE_ROOT"
mkdir -p build
python3 scripts/check-muse-mesh.py
python3 scripts/check-guard-accessories.py
sources=Sources/SentinelPet
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/character-checks Tests/CharacterChecks.swift "$sources/Character/GuardianMotion.swift" "$sources/Character/GuardianPlacement.swift" "$sources/Character/UnrealCharacterRenderer.swift"
./build/character-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/guardian-acknowledgment-checks Tests/GuardianAcknowledgmentChecks.swift "$sources/Overlay/PetViewModel.swift" "$sources/Character/GuardianMotion.swift"
./build/guardian-acknowledgment-checks
shared=("$sources/Risk/LocalRiskAnalyzer.swift" "$sources/Risk/LocalInferenceScheduler.swift" "$sources/Risk/LocalModelConfiguration.swift" "$sources/Risk/RiskVerdict.swift" "$sources/Accessibility/ScreenReader.swift" "$sources/Accessibility/AccessibilityPermissionController.swift")
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/response-checks Tests/ResponseChecks.swift "${shared[@]}"
./build/response-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/browser-assessment-checks Tests/BrowserAssessmentChecks.swift "$sources/Browser/BrowserProtocol.swift" "$sources/Browser/BrowserAssessmentCoordinator.swift" "${shared[@]}"
./build/browser-assessment-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/browser-bridge-checks Tests/BrowserBridgeChecks.swift "$sources/Browser/BrowserProtocol.swift" "$sources/Browser/BrowserBridgeServer.swift"
./build/browser-bridge-checks
python3 -m unittest discover -s BrowserNativeHost -p 'test_*.py'
if [[ "${1:-}" == "--local-model" ]]; then
    xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/local-model-checks Tests/LocalModelChecks.swift "$sources/Character/MockScenario.swift" "${shared[@]}"
    ./build/local-model-checks
fi
