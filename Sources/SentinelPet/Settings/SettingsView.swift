import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var runtime: SentinelPetRuntime
    @ObservedObject private var modelService = LocalModelService.shared
    @ObservedObject private var renderer = UnrealCharacterRenderer.shared
    @ObservedObject private var pet = SentinelPetRuntime.shared.petViewModel
    @State private var chromeSetupMessage: String?
    @State private var connectingChrome = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Muse Guard Settings").font(.title2.bold())
                Text("Muse watches the app you’re using and speaks up for serious risks. Everything is analyzed on this Mac.")
                    .foregroundStyle(.secondary)
                if modelService.supportsInstallation { setup }
                GroupBox("Monitoring") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(runtime.monitoringStatus, systemImage: runtime.monitoringPaused ? "pause.circle" : "shield.lefthalf.filled")
                        Text("Pause monitoring stops browser, desktop, download and secret-paste checks together. You can still ask Muse a question.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Chrome uses the extension. Other apps are watched automatically when screen access is available. Accessibility text is checked first; Screen Recording adds a closer look when needed.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(desktopStatus).font(.callout).foregroundStyle(.secondary)
                        Label(runtime.downloadStatus, systemImage: "arrow.down.doc").font(.callout).foregroundStyle(.secondary)
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

    private var setup: some View {
        GroupBox("Get started") {
            VStack(alignment: .leading, spacing: 12) {
                Label("1. Prepare the local model", systemImage: modelService.isReady ? "checkmark.circle.fill" : "cpu")
                    .font(.headline)
                Text(modelService.isReady ? "Muse Glimmer is ready on this Mac." : modelService.status)
                    .foregroundStyle(.secondary)
                if !modelService.isInstalled || modelService.isInstalling {
                    Text("The one-time download is 19.8 GB. Muse runs the model locally after setup. We recommend at least 32 GB of unified memory.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let progress = modelService.installationProgress {
                        ProgressView(value: progress)
                        Button("Pause download") { modelService.pauseInstallation() }
                    } else {
                        Button(modelService.installationMessage == nil ? "Download model" : "Resume download") {
                            modelService.installModel()
                        }.buttonStyle(.borderedProminent)
                    }
                    if let message = modelService.installationMessage {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                } else if !modelService.isReady {
                    Button("Retry local model") { modelService.start() }
                }
                Divider()
                Label("2. Connect Chrome", systemImage: runtime.chromeConnected ? "checkmark.circle.fill" : "globe")
                    .font(.headline)
                Text(runtime.chromeConnected ? "Chrome is connected." : "Connect Chrome, then turn on Developer mode and choose Load unpacked. Paste the extension folder path in the folder picker with ⌘⇧G.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(connectingChrome ? "Connecting…" : "Open Chrome setup") { connectChrome() }
                        .disabled(connectingChrome)
                    Button("Copy extension folder path") { copyExtensionPath() }
                        .disabled(extensionFolder == nil)
                }
                if let message = chromeSetupMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
                Text("Use Screen access below to add checks in other apps.")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var extensionFolder: URL? {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension", isDirectory: true),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else { return nil }
        return folder
    }

    private func copyExtensionPath() {
        guard let extensionFolder else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(extensionFolder.path, forType: .string)
        chromeSetupMessage = "Extension folder path copied."
    }

    private func connectChrome() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            chromeSetupMessage = "Install Google Chrome first, then return here."
            return
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/muse-guard-host")
        guard extensionFolder != nil, FileManager.default.isExecutableFile(atPath: helper.path) else {
            chromeSetupMessage = "The Chrome setup files are missing. Reinstall Muse Guard."
            return
        }
        connectingChrome = true
        Task {
            defer { connectingChrome = false }
            do {
                try await Task.detached {
                    let process = Process()
                    process.executableURL = helper
                    process.arguments = ["--register"]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                }.value
                copyExtensionPath()
                _ = try await NSWorkspace.shared.open([URL(string: "chrome://extensions/")!], withApplicationAt: chrome,
                                                      configuration: .init())
                chromeSetupMessage = "Extension folder path copied. In Chrome, choose Load unpacked."
            } catch {
                chromeSetupMessage = "Could not open Chrome setup. Try again with Muse Guard installed in Applications."
            }
        }
    }

    private var desktopStatus: String {
        if runtime.monitoringPaused { return "Desktop checks paused with monitoring." }
        if !runtime.accessibilityTrusted && !runtime.screenCaptureTrusted { return "Waiting for Accessibility or Screen Recording access." }
        if !modelService.isReady { return "Waiting for the local model." }
        return runtime.isMonitoring ? runtime.monitorStatus : "Desktop checks stopped."
    }
}
