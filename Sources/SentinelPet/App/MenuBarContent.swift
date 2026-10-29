import SwiftUI
import AppKit

/// Contents of the menu-bar dropdown.
struct MenuBarContent: View {
    @ObservedObject private var pet = SentinelPetRuntime.shared.petViewModel
    @ObservedObject private var renderer = UnrealCharacterRenderer.shared
    @ObservedObject private var localModel = LocalModelService.shared
    @ObservedObject var runtime: SentinelPetRuntime = .shared

    var body: some View {
        Text("Muse Guard")
            .font(.headline)

        Label(renderer.status, systemImage: "cube.transparent")
        Button(pet.isAvatarHidden ? "Show Muse" : "Hide Muse") { runtime.toggleAvatarVisibility() }
        Toggle("Stay out of my way", isOn:$pet.automaticallyPositions)
        Button("Open Muse Studio…") { GuardianStudio.shared.show() }
        Button("Preview guard intervention") { runtime.previewGuardianIntervention() }
            .disabled(!renderer.isReady || pet.isAvatarHidden || pet.acknowledgment != nil)
        Picker("Accessory", selection: $renderer.accessory) {
            Text("Guard · cap & badge").tag("guard")
            Text("Focus · headphones").tag("focus")
            Text("Just Muse").tag("none")
        }
        Button("Return Muse home") { runtime.dismissPetBubble() }
            .disabled(pet.acknowledgment != nil)
        Menu("3D renderer") {
            Button("Restart 3D renderer") { renderer.restart() }
            Button("Open renderer logs") { renderer.showLogs() }
        }
        Divider()

        Label(
            runtime.accessibilityTrusted ? "Accessibility enabled" : "Accessibility optional",
            systemImage: runtime.accessibilityTrusted ? "checkmark.shield" : "accessibility"
        )

        Label(
            runtime.screenCaptureTrusted ? "Screen Recording enabled" : "Screen Recording required",
            systemImage: runtime.screenCaptureTrusted ? "checkmark.rectangle" : "camera.viewfinder"
        )

        Label(localModel.status, systemImage: "desktopcomputer")
        Label(runtime.browserStatus, systemImage: "globe")
        Button("Start local model") { localModel.start() }
        Button("Open model logs") { localModel.showLogs() }

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

        Button("Open mock lab…") { MockLab.shared.show() }

        Button("Settings…") {
            runtime.showSettings()
        }

        Divider()

        Button("Quit Muse Guard") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
