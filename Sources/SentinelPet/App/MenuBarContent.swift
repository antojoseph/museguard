import SwiftUI
import AppKit

/// Contents of the menu-bar dropdown. Most items are placeholders for now and
/// get wired up in later milestones (monitoring, settings, privacy controls).
struct MenuBarContent: View {
    @ObservedObject var runtime: SentinelPetRuntime = .shared

    var body: some View {
        Text("Sentinel Pet")
            .font(.headline)

        Label(
            runtime.accessibilityTrusted ? "Accessibility enabled" : "Accessibility required",
            systemImage: runtime.accessibilityTrusted ? "checkmark.shield" : "exclamationmark.triangle"
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

        Button("Read focused window") {
            runtime.scanFocusedContext()
        }
        .disabled(!runtime.accessibilityTrusted)

        Button("Analyze focused window") {
            runtime.analyzeFocusedContext()
        }

        Divider()

        Button(runtime.isMonitoring ? "Pause monitoring" : "Start monitoring") {
            runtime.toggleMonitoring()
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
