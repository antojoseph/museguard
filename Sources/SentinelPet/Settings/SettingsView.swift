import SwiftUI

struct SettingsView: View {
    @ObservedObject var runtime: SentinelPetRuntime

    @State private var apiKey = ""
    @State private var model = AppSettings.defaultModel
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sentinel Pet Settings")
                    .font(.title2.weight(.semibold))
                Text("Configure Fireworks analysis. Screen text is sent only when you choose an analysis action.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("API Key")
                        .foregroundStyle(.secondary)
                    SecureField(
                        runtime.hasFireworksAPIKey ? "Saved in Keychain" : "Fireworks API key",
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
        .frame(minWidth: 460, minHeight: 300)
        .onAppear {
            model = runtime.settings.fireworksModel
        }
    }

    private func save() {
        do {
            try runtime.saveFireworksSettings(model: model, apiKey: apiKey)
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
}
