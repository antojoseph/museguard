import Foundation

/// Shared app coordinator for menu actions, permissions, and pet feedback.
@MainActor
final class SentinelPetRuntime: ObservableObject {
    static let shared = SentinelPetRuntime()

    let petViewModel = PetViewModel()

    @Published private(set) var accessibilityTrusted: Bool
    @Published private(set) var hasFireworksAPIKey: Bool
    @Published private(set) var settings: AppSettings

    private let screenReader = ScreenReader()
    private let riskAnalyzer = FireworksRiskAnalyzer()
    private let settingsWindowController = SettingsWindowController()
    private var analyzeTask: Task<Void, Never>?

    private init() {
        settings = AppSettingsStore.load()
        accessibilityTrusted = AccessibilityPermissionController.isTrusted
        hasFireworksAPIKey = KeychainStore.hasFireworksAPIKey()
    }

    func refreshAccessibilityStatus() {
        accessibilityTrusted = AccessibilityPermissionController.isTrusted
    }

    func requestAccessibilityPermission() {
        accessibilityTrusted = AccessibilityPermissionController.requestAccess()

        if accessibilityTrusted {
            petViewModel.show(
                "Accessibility access is enabled. I can read focused-window text now.",
                mood: .idle,
                clearAfter: 6
            )
        } else {
            petViewModel.show(
                "Please enable Sentinel Pet in Privacy & Security > Accessibility, then check again.",
                mood: .scanning,
                clearAfter: 10
            )
        }
    }

    func scanFocusedContext() {
        refreshAccessibilityStatus()

        guard accessibilityTrusted else {
            requestAccessibilityPermission()
            return
        }

        petViewModel.show("Reading the focused window...", mood: .scanning)

        do {
            let snapshot = try screenReader.readFocusedContext()
            petViewModel.show(
                previewMessage(for: snapshot),
                mood: .idle,
                clearAfter: 10
            )
        } catch {
            petViewModel.show(error.localizedDescription, mood: .alert, clearAfter: 8)
        }
    }

    func analyzeFocusedContext() {
        refreshAccessibilityStatus()
        refreshFireworksAPIKeyStatus()

        guard accessibilityTrusted else {
            requestAccessibilityPermission()
            return
        }

        guard hasFireworksAPIKey else {
            petViewModel.show(
                "Add a Fireworks API key in Settings before I analyze screen text.",
                mood: .scanning,
                clearAfter: 8
            )
            showSettings()
            return
        }

        petViewModel.show("Reading and analyzing the focused window...", mood: .scanning)
        analyzeTask?.cancel()
        analyzeTask = Task { [weak self] in
            guard let self else { return }
            await self.runFocusedAnalysis()
        }
    }

    func showSettings() {
        settingsWindowController.show(runtime: self)
    }

    func saveFireworksSettings(model: String, apiKey: String) throws {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        settings = AppSettings(
            fireworksModel: trimmedModel.isEmpty ? AppSettings.defaultModel : trimmedModel
        )
        AppSettingsStore.save(settings)

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            try KeychainStore.saveFireworksAPIKey(trimmedKey)
        }

        refreshFireworksAPIKeyStatus()
        petViewModel.show("Settings saved.", mood: .idle, clearAfter: 4)
    }

    func deleteFireworksAPIKey() throws {
        try KeychainStore.deleteFireworksAPIKey()
        refreshFireworksAPIKeyStatus()
        petViewModel.show("Fireworks API key deleted.", mood: .idle, clearAfter: 4)
    }

    func refreshFireworksAPIKeyStatus() {
        hasFireworksAPIKey = KeychainStore.hasFireworksAPIKey()
    }

    private func runFocusedAnalysis() async {
        do {
            let snapshot = try screenReader.readFocusedContext()
            guard let apiKey = try KeychainStore.readFireworksAPIKey() else {
                refreshFireworksAPIKeyStatus()
                throw FireworksRiskAnalyzerError.missingAPIKey
            }

            let verdict = try await riskAnalyzer.analyze(
                snapshot: snapshot,
                model: settings.fireworksModel,
                apiKey: apiKey
            )

            guard !Task.isCancelled else { return }
            petViewModel.show(
                message(for: verdict),
                mood: mood(for: verdict.riskLevel),
                clearAfter: clearDelay(for: verdict.riskLevel)
            )
        } catch {
            guard !Task.isCancelled else { return }
            petViewModel.show(error.localizedDescription, mood: .alert, clearAfter: 10)
        }
    }

    private func previewMessage(for snapshot: ScreenSnapshot) -> String {
        let preview = snapshot.text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .prefix(160)

        if preview.isEmpty {
            return "I can access \(snapshot.appName), but I did not find readable text there."
        }
        return "I can read \(snapshot.appName): \(preview)"
    }

    private func message(for verdict: RiskVerdict) -> String {
        let prefix: String
        switch verdict.riskLevel {
        case .safe:
            prefix = "Looks safe."
        case .low:
            prefix = "Low risk."
        case .medium:
            prefix = "Be careful."
        case .high:
            prefix = "High risk."
        case .unknown:
            prefix = "I am not sure."
        }

        return "\(prefix) \(verdict.summary) \(verdict.guidance)"
    }

    private func mood(for riskLevel: RiskLevel) -> PetMood {
        switch riskLevel {
        case .safe, .low:
            return .idle
        case .medium, .unknown:
            return .scanning
        case .high:
            return .alert
        }
    }

    private func clearDelay(for riskLevel: RiskLevel) -> Double? {
        riskLevel == .high ? nil : 14
    }
}
