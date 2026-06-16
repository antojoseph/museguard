import SwiftUI

struct SettingsView: View {
    @ObservedObject var runtime: SentinelPetRuntime

    @State private var apiKey = ""
    @State private var model = AppSettings.defaultModel
    @State private var monitoringConsentGranted = false
    @State private var alertSensitivity: AlertSensitivity = .standard
    @State private var deniedAppsText = ""
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sentinel Pet Settings")
                    .font(.title2.weight(.semibold))
                Text("Configure Fireworks analysis and privacy controls. Screenshot monitoring runs only after you explicitly enable consent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("API Key")
                        .foregroundStyle(.secondary)
                    SecureField(
                        runtime.hasFireworksAPIKey ? "Saved in dev preferences" : "Fireworks API key",
                        text: $apiKey
                    )
                    .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Model")
                        .foregroundStyle(.secondary)
                    TextField("Fireworks model", text: $model)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Sensitivity")
                        .foregroundStyle(.secondary)
                    Picker("Sensitivity", selection: $alertSensitivity) {
                        ForEach(AlertSensitivity.allCases) { sensitivity in
                            Text(sensitivity.label).tag(sensitivity)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            Toggle(
                "Allow continuous monitoring to capture changed screenshots and send them to Fireworks",
                isOn: $monitoringConsentGranted
            )
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 6) {
                Text("Sensitive App Deny List")
                    .font(.headline)
                Text("One app or window-title keyword per line. Matching windows are skipped before screenshots are sent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $deniedAppsText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 90)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
            }

            HStack {
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)

                Button("Delete API Key", role: .destructive) {
                    deleteAPIKey()
                }
                .disabled(!runtime.hasFireworksAPIKey)

                Spacer()

                if let statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 540)
        .onAppear {
            model = runtime.settings.fireworksModel
            monitoringConsentGranted = runtime.settings.monitoringConsentGranted
            alertSensitivity = runtime.settings.alertSensitivity
            deniedAppsText = runtime.settings.deniedAppNames.joined(separator: "\n")
        }
    }

    private func save() {
        do {
            try runtime.saveSettings(
                model: model,
                apiKey: apiKey,
                monitoringConsentGranted: monitoringConsentGranted,
                alertSensitivity: alertSensitivity,
                deniedAppNames: parsedDeniedAppNames
            )
            apiKey = ""
            statusMessage = "Saved"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func deleteAPIKey() {
        do {
            try runtime.deleteFireworksAPIKey()
            apiKey = ""
            statusMessage = "API key deleted"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private var parsedDeniedAppNames: [String] {
        deniedAppsText
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
