#!/usr/bin/env bash
set -euo pipefail
MUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MUSE_ROOT"
mkdir -p build
python3 scripts/check-muse-mesh.py
python3 scripts/check-guard-accessories.py
sources=Sources/SentinelPet
browser_safety=("$sources/Browser/BrowserSafetyProtocol.swift" "$sources/Browser/BrowserElementTarget.swift" "$sources/Browser/BrowserContentEvidence.swift")
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/menu-bar-state-checks Tests/MenuBarStateChecks.swift "$sources/App/MenuBarState.swift"
./build/menu-bar-state-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/release-configuration-checks Tests/BuildConfigurationChecks.swift "$sources/App/BuildConfiguration.swift"
./build/release-configuration-checks --visual-test --expect-disabled
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -D MUSE_DEVELOPMENT -o build/development-configuration-checks Tests/BuildConfigurationChecks.swift "$sources/App/BuildConfiguration.swift"
./build/development-configuration-checks --visual-test --expect-enabled
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/local-model-configuration-checks Tests/LocalModelConfigurationChecks.swift "$sources/Risk/LocalModelConfiguration.swift"
./build/local-model-configuration-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/character-checks Tests/CharacterChecks.swift "$sources/Character/GuardianMotion.swift" "$sources/Character/GuardianPlacement.swift" "$sources/Character/GuardianWorkActivity.swift" "$sources/Character/UnrealCharacterRenderer.swift" "$sources/Character/RendererLaunchConfiguration.swift" "$sources/App/BuildConfiguration.swift"
./build/character-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/guardian-work-activity-checks Tests/GuardianWorkActivityChecks.swift "$sources/Character/GuardianWorkActivity.swift"
./build/guardian-work-activity-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/guardian-protection-checks Tests/GuardianProtectionChecks.swift "$sources/Character/GuardianProtectionActivity.swift" "$sources/Character/GuardianMotion.swift"
./build/guardian-protection-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/local-inference-activity-checks Tests/LocalInferenceActivityChecks.swift "$sources/Risk/LocalInferenceScheduler.swift"
./build/local-inference-activity-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/inference-metrics-checks Tests/InferenceMetricsChecks.swift "$sources/Risk/LocalInferenceScheduler.swift"
./build/inference-metrics-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/guardian-acknowledgment-checks Tests/GuardianAcknowledgmentChecks.swift "$sources/Overlay/PetViewModel.swift" "$sources/Character/GuardianMotion.swift" "$sources/Diagnostics/PredictionDebugState.swift" "$sources/Risk/RiskVerdict.swift"
./build/guardian-acknowledgment-checks
feedback=("$sources/Feedback/WarningFeedbackStore.swift" "$sources/Risk/RiskVerdict.swift")
xcrun swiftc -warnings-as-errors -swift-version 5 -target arm64-apple-macosx13.0 -o build/warning-feedback-checks Tests/WarningFeedbackChecks.swift "${feedback[@]}"
./build/warning-feedback-checks
xcrun swiftc -warnings-as-errors -swift-version 5 -target arm64-apple-macosx13.0 -o build/warning-feedback-session-checks Tests/WarningFeedbackSessionChecks.swift "$sources/Feedback/WarningFeedbackSession.swift" "${feedback[@]}"
./build/warning-feedback-session-checks
xcrun swiftc -warnings-as-errors -swift-version 5 -target arm64-apple-macosx13.0 -o build/prediction-debug-checks Tests/PredictionDebugChecks.swift "$sources/Diagnostics/PredictionDebugState.swift" "$sources/Risk/RiskVerdict.swift"
./build/prediction-debug-checks
shared=("$sources/Risk/LocalRiskAnalyzer.swift" "$sources/Risk/LocalInferenceScheduler.swift" "$sources/Risk/LocalModelConfiguration.swift" "$sources/Risk/RiskVerdict.swift" "$sources/Accessibility/ScreenReader.swift" "$sources/Accessibility/ContextEvidence.swift" "$sources/Accessibility/AccessibilityPermissionController.swift")
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/context-evidence-checks Tests/ContextEvidenceChecks.swift "$sources/Accessibility/ContextEvidence.swift"
./build/context-evidence-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/watched-application-policy-checks Tests/WatchedApplicationPolicyChecks.swift "$sources/Context/WatchedApplicationPolicy.swift"
./build/watched-application-policy-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/chat-capture-policy-checks Tests/ChatCapturePolicyChecks.swift "$sources/Context/ChatCapturePolicy.swift" "$sources/Accessibility/ScreenReader.swift" "$sources/Accessibility/ContextEvidence.swift" "$sources/Accessibility/AccessibilityPermissionController.swift"
./build/chat-capture-policy-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/monitor-loop-checks Tests/MonitorLoopChecks.swift "${shared[@]}" "$sources/Monitor/MonitorLoop.swift" "$sources/Monitor/MonitorEvidenceCache.swift" "$sources/Media/ScreenshotCapture.swift" "$sources/Media/ScreenCapturePermissionController.swift"
./build/monitor-loop-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/screenshot-capture-checks Tests/ScreenshotCaptureChecks.swift "$sources/Media/ScreenshotCapture.swift" "$sources/Media/ScreenCapturePermissionController.swift"
./build/screenshot-capture-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/screen-chat-checks Tests/ScreenChatChecks.swift "${shared[@]}"
./build/screen-chat-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/streaming-chat-checks Tests/StreamingChatChecks.swift "${shared[@]}" "$sources/Overlay/PetViewModel.swift" "$sources/Character/GuardianMotion.swift" "$sources/Diagnostics/PredictionDebugState.swift"
./build/streaming-chat-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/browser-chat-context-checks Tests/BrowserChatContextChecks.swift "$sources/Browser/BrowserProtocol.swift" "${browser_safety[@]}" "$sources/Browser/BrowserChatContextBroker.swift"
./build/browser-chat-context-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/monitoring-control-checks Tests/MonitoringControlChecks.swift "$sources/App/MonitoringControl.swift" "$sources/Browser/BrowserProtocol.swift" "${browser_safety[@]}"
./build/monitoring-control-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/response-checks Tests/ResponseChecks.swift "${shared[@]}"
./build/response-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/browser-assessment-checks Tests/BrowserAssessmentChecks.swift "$sources/Browser/BrowserProtocol.swift" "${browser_safety[@]}" "$sources/Browser/BrowserAssessmentCoordinator.swift" "${shared[@]}"
./build/browser-assessment-checks
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/browser-bridge-checks Tests/BrowserBridgeChecks.swift "$sources/Browser/BrowserProtocol.swift" "${browser_safety[@]}" "$sources/Browser/BrowserBridgeServer.swift"
./build/browser-bridge-checks
xcrun swiftc -warnings-as-errors -swift-version 5 -target arm64-apple-macosx13.0 -o build/browser-prediction-protocol-checks Tests/BrowserPredictionProtocolChecks.swift "$sources/Browser/BrowserProtocol.swift" "${browser_safety[@]}"
./build/browser-prediction-protocol-checks
python3 -m unittest discover -s BrowserNativeHost -p 'test_*.py'
if [[ "${1:-}" == "--local-model" ]]; then
    xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/local-model-checks Tests/LocalModelChecks.swift Development/MockScenario.swift "${shared[@]}"
    ./build/local-model-checks
    xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/desktop-risk-model-checks Tests/DesktopRiskModelChecks.swift "${shared[@]}"
    ./build/desktop-risk-model-checks
    xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -o build/browser-risk-model-checks Tests/BrowserRiskModelChecks.swift "$sources/Browser/BrowserProtocol.swift" "${browser_safety[@]}" "$sources/Browser/BrowserAssessmentCoordinator.swift" "${shared[@]}"
    ./build/browser-risk-model-checks
fi

xcrun swiftc -warnings-as-errors -swift-version 5 -target arm64-apple-macosx13.0 -o build/secret-detection-checks Tests/SecretDetectionChecks.swift "$sources/Secrets/SecretDetector.swift" "$sources/Secrets/NativeSecretPasteMonitor.swift"
./build/secret-detection-checks
xcrun swiftc -warnings-as-errors -swift-version 5 -target arm64-apple-macosx13.0 -o build/browser-target-checks Tests/BrowserElementTargetChecks.swift "$sources/Browser/BrowserElementTarget.swift"
./build/browser-target-checks
xcrun swiftc -warnings-as-errors -swift-version 5 -target arm64-apple-macosx13.0 -o build/download-inspection-checks Tests/DownloadInspectionChecks.swift "$sources/Downloads/DownloadInspection.swift" "$sources/Downloads/DownloadZipInspection.swift" "$sources/Downloads/DownloadScannerMaintenance.swift" "$sources/Risk/RiskVerdict.swift"
./build/download-inspection-checks
xcrun swiftc -warnings-as-errors -swift-version 5 -target arm64-apple-macosx13.0 -o build/renderer-launch-checks Tests/RendererLaunchChecks.swift "$sources/Character/RendererLaunchConfiguration.swift"
./build/renderer-launch-checks

xcrun swiftc -warnings-as-errors -swift-version 5 -target arm64-apple-macosx13.0 -o build/browser-safety-protocol-checks Tests/BrowserSafetyProtocolChecks.swift "$sources/Browser/BrowserProtocol.swift" "${browser_safety[@]}"
./build/browser-safety-protocol-checks
xcrun swiftc -warnings-as-errors -swift-version 5 -target arm64-apple-macosx13.0 -o build/browser-pointing-window-checks Tests/BrowserPointingWindowChecks.swift "$sources/Browser/BrowserPointingController.swift" "$sources/Browser/BrowserElementTarget.swift"
./build/browser-pointing-window-checks
