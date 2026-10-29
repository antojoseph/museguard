import SwiftUI

struct SettingsView: View {
    @ObservedObject var runtime: SentinelPetRuntime
    @ObservedObject private var modelService = LocalModelService.shared
    @State private var consent = false
    @State private var sensitivity = AlertSensitivity.standard
    @State private var denied = ""
    @State private var saved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Muse Guard Settings").font(.title2.bold())
            Label(modelService.status, systemImage: "desktopcomputer")
            Text("Text, screenshots, and follow-up questions are analyzed by Muse Glimmer on this Mac. No cloud API key is needed.").foregroundStyle(.secondary)
            HStack {
                Button("Start local model") { modelService.start() }
                Button("Open model logs") { modelService.showLogs() }
            }
            Toggle("Allow continuous local screenshot monitoring", isOn: $consent)
            Picker("Alert sensitivity", selection: $sensitivity) {
                ForEach(AlertSensitivity.allCases) { level in Text(level.label).tag(level) }
            }.pickerStyle(.segmented)
            Text("Sensitive apps and window titles").font(.headline)
            Text("One keyword per line. Matching focused windows are skipped.").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $denied).font(.system(.body, design: .monospaced)).frame(height: 130)
            HStack {
                Button("Save") {
                    runtime.saveSettings(model: AppSettings.defaultModel, monitoringConsentGranted: consent, alertSensitivity: sensitivity,
                                         deniedAppNames: denied.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                    saved = true
                }.keyboardShortcut(.defaultAction)
                if saved { Text("Saved").foregroundStyle(.secondary) }
            }
        }.padding(24).frame(width: 560)
        .onAppear { consent = runtime.settings.monitoringConsentGranted; sensitivity = runtime.settings.alertSensitivity; denied = runtime.settings.deniedAppNames.joined(separator: "\n") }
    }
}
