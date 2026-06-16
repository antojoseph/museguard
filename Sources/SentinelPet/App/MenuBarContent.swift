import SwiftUI
import AppKit

/// Contents of the menu-bar dropdown.
struct MenuBarContent: View {
    @ObservedObject var runtime: SentinelPetRuntime = .shared

    var body: some View {
        Text("Sentinel Pet")
            .font(.headline)

        Label(
            runtime.accessibilityTrusted ? "Accessibility enabled" : "Accessibility optional",
            systemImage: runtime.accessibilityTrusted ? "checkmark.shield" : "accessibility"
        )

        Label(
            runtime.screenCaptureTrusted ? "Screen Recording enabled" : "Screen Recording required",
            systemImage: runtime.screenCaptureTrusted ? "checkmark.rectangle" : "camera.viewfinder"
        )

        Label(
            runtime.hasFireworksAPIKey ? "Fireworks configured" : "Fireworks API key required",
            systemImage: runtime.hasFireworksAPIKey ? "checkmark.circle" : "key"
        )

        Label(
            runtime.isMonitoring ? runtime.monitorStatus : "Monitoring paused",
            systemImage: runtime.isMonitoring ? "eye" : "pause.circle"
        )

        Button(runtime.accessibilityTrusted ? "Check accessibility access" : "Enable accessibility access") {
            runtime.requestAccessibilityPermission()
        }

        Button("Open Accessibility Settings") {
            runtime.openAccessibilitySettings()
        }

        Button(runtime.screenCaptureTrusted ? "Check screen recording access" : "Enable screen recording access") {
            runtime.requestScreenCapturePermission()
        }

        Button("Open Screen Recording Settings") {
            runtime.openScreenRecordingSettings()
        }

        Button("Read focused window") {
            runtime.scanFocusedContext()
        }
        .disabled(!runtime.accessibilityTrusted)

        Button("Analyze focused window") {
            runtime.analyzeFocusedContext()
        }

        Button("Analyze screenshot") {
            runtime.analyzeScreenshot()
        }

        Divider()

        Button(runtime.isMonitoring ? "Pause monitoring" : "Start monitoring") {
            runtime.toggleMonitoring()
        }

        Button("View logs…") {
            runtime.showAnalysisLogs()
        }

        Button("Settings…") {
            runtime.showSettings()
        }

        Divider()

        Button("Quit Sentinel Pet") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
