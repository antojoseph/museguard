import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var runtime: SentinelPetRuntime
    @ObservedObject private var modelService = LocalModelService.shared
    @ObservedObject private var renderer = UnrealCharacterRenderer.shared
    @ObservedObject private var pet = SentinelPetRuntime.shared.petViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Muse Guard Settings").font(.title2.bold())
                Text("Muse watches the app you’re using and speaks up for serious risks. Everything is analyzed on this Mac.")
                    .foregroundStyle(.secondary)
                GroupBox("Monitoring") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(runtime.monitoringStatus, systemImage: runtime.monitoringPaused ? "pause.circle" : "shield.lefthalf.filled")
                        Text("Pause monitoring stops automatic browser and desktop checks together. You can still ask Muse a question.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Chrome uses the extension. Other apps are watched automatically when screen access is available. Accessibility text is checked first; Screen Recording adds a closer look when needed.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(desktopStatus).font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("Appearance") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Outfit", selection: $renderer.accessory) {
                            Text("Guard").tag("guard")
                            Text("Headphones").tag("focus")
                            Text("Just Muse").tag("none")
                        }.pickerStyle(.segmented)
                        Picker("Placement", selection: $pet.automaticallyPositions) {
                            Text("Automatic placement").tag(true)
                            Text("Keep here").tag(false)
                        }.pickerStyle(.segmented)
                        Text("Drag Muse to choose a spot. Muse naps when you are inactive; monitoring continues.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Screen access") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Chrome text checks and browser chat work through the extension without screen access.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Label("Screen Recording", systemImage: "rectangle.dashed.badge.record")
                            Spacer()
                            if runtime.screenCaptureTrusted {
                                Text("Enabled").foregroundStyle(.secondary)
                            } else {
                                Button("Enable…") { runtime.requestScreenCapturePermission() }
                            }
                        }
                        HStack {
                            Label("Accessibility", systemImage: "accessibility")
                            Spacer()
                            if runtime.accessibilityTrusted {
                                Text("Enabled").foregroundStyle(.secondary)
                            } else {
                                Button("Enable…") { runtime.requestAccessibilityPermission() }
                            }
                        }
                        Text("Accessibility lets Muse read other apps’ window text. Screen Recording supplies visual context when text is missing or you ask for a closer look.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(8)
                }
                DisclosureGroup("Troubleshooting") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(modelService.status, systemImage: "desktopcomputer")
                        HStack {
                            if modelService.canRestart {
                                Button("Restart local model") { modelService.restart() }
                            } else if !modelService.isReady {
                                Button("Retry local model") { modelService.start() }
                            }
                            Button("Open model log") { modelService.showLogs() }
                        }
                        Label(renderer.status, systemImage: "cube.transparent")
                        HStack {
                            Button("Restart 3D renderer") { renderer.restart() }
                            Button("Open renderer logs") { renderer.showLogs() }
                        }
                        Label(runtime.browserStatus, systemImage: "globe")
                        HStack {
                            Button("Accessibility Settings…") { runtime.openAccessibilitySettings() }
                            Button("Screen Recording Settings…") { runtime.openScreenRecordingSettings() }
                        }
                    }.padding(.top, 10)
                }
            }.padding(24)
        }
        .frame(width: 560, height: 620)
        .onAppear {
            runtime.refreshAccessibilityStatus()
            runtime.refreshScreenCaptureStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            runtime.refreshAccessibilityStatus()
            runtime.refreshScreenCaptureStatus()
        }
    }

    private var desktopStatus: String {
        if runtime.monitoringPaused { return "Desktop checks paused with monitoring." }
        if !runtime.accessibilityTrusted && !runtime.screenCaptureTrusted { return "Waiting for Accessibility or Screen Recording access." }
        if !modelService.isReady { return "Waiting for the local model." }
        return runtime.isMonitoring ? runtime.monitorStatus : "Desktop checks stopped."
    }
}
