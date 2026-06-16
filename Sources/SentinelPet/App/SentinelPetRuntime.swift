import AppKit
import Foundation

/// Shared app coordinator for menu actions, permissions, and pet feedback.
@MainActor
final class SentinelPetRuntime: ObservableObject {
    static let shared = SentinelPetRuntime()

    let petViewModel = PetViewModel()

    @Published private(set) var accessibilityTrusted: Bool
    @Published private(set) var hasFireworksAPIKey: Bool
    @Published private(set) var settings: AppSettings
    @Published private(set) var isMonitoring = false
    @Published private(set) var monitorStatus = MonitorLoopStatus.idle.label

    private let screenReader = ScreenReader()
    private let riskAnalyzer = FireworksRiskAnalyzer()
    private lazy var monitorLoop = MonitorLoop(
        screenReader: screenReader,
        riskAnalyzer: riskAnalyzer
    )
    private let settingsWindowController = SettingsWindowController()
    private var analyzeTask: Task<Void, Never>?
    private var lastMonitorErrorMessage: String?

    private init() {
        settings = AppSettingsStore.load()
        accessibilityTrusted = AccessibilityPermissionController.isTrusted
        hasFireworksAPIKey = DevCredentialStore.hasFireworksAPIKey()
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

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func scanFocusedContext() {
        refreshAccessibilityStatus()

        guard accessibilityTrusted else {
            showAccessibilityRequiredMessage()
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
            showAccessibilityRequiredMessage()
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

    func toggleMonitoring() {
        if isMonitoring {
            stopMonitoring(showMessage: true)
        } else {
            startMonitoring()
        }
    }

    func startMonitoring() {
        refreshAccessibilityStatus()
        refreshFireworksAPIKeyStatus()

        guard settings.monitoringConsentGranted else {
            petViewModel.show(
                "Open Settings and enable monitoring consent before I watch continuously.",
                mood: .scanning,
                clearAfter: 8
            )
            showSettings()
            return
        }

        guard accessibilityTrusted else {
            showAccessibilityRequiredMessage()
            return
        }

        guard hasFireworksAPIKey else {
            petViewModel.show(
                "Add a Fireworks API key in Settings before I can monitor continuously.",
                mood: .scanning,
                clearAfter: 8
            )
            showSettings()
            return
        }

        guard let apiKey = DevCredentialStore.readFireworksAPIKey() else {
            refreshFireworksAPIKeyStatus()
            petViewModel.show(
                "Add a Fireworks API key in Settings before I can monitor continuously.",
                mood: .scanning,
                clearAfter: 8
            )
            showSettings()
            return
        }

        lastMonitorErrorMessage = nil
        monitorLoop.start(
            model: settings.fireworksModel,
            apiKey: apiKey,
            deniedAppNames: settings.deniedAppNames,
            onStatus: { [weak self] status in
                self?.handleMonitorStatus(status)
            },
            onVerdict: { [weak self] verdict in
                self?.handleMonitorVerdict(verdict)
            },
            onError: { [weak self] error in
                self?.handleMonitorError(error)
            }
        )

        isMonitoring = true
        monitorStatus = "Monitoring"
        petViewModel.show(
            "Monitoring started. I'll stay quiet unless I see something risky.",
            mood: .idle,
            clearAfter: 6
        )
    }

    func stopMonitoring(showMessage: Bool = false) {
        monitorLoop.stop()
        isMonitoring = false
        monitorStatus = MonitorLoopStatus.idle.label
        lastMonitorErrorMessage = nil

        if showMessage {
            petViewModel.show("Monitoring paused.", mood: .idle, clearAfter: 4)
        }
    }

    func showSettings() {
        settingsWindowController.show(runtime: self)
    }

    func saveSettings(
        model: String,
        apiKey: String,
        monitoringConsentGranted: Bool,
        alertSensitivity: AlertSensitivity,
        deniedAppNames: [String]
    ) throws {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        settings = AppSettings(
            fireworksModel: trimmedModel.isEmpty ? AppSettings.defaultModel : trimmedModel,
            monitoringConsentGranted: monitoringConsentGranted,
            alertSensitivity: alertSensitivity,
            deniedAppNames: deniedAppNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        AppSettingsStore.save(settings)

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            DevCredentialStore.saveFireworksAPIKey(trimmedKey)
        }

        refreshFireworksAPIKeyStatus()
        petViewModel.show("Settings saved.", mood: .idle, clearAfter: 4)

        if isMonitoring {
            startMonitoring()
        }
    }

    func deleteFireworksAPIKey() throws {
        DevCredentialStore.deleteFireworksAPIKey()
        refreshFireworksAPIKeyStatus()
        stopMonitoring()
        petViewModel.show("Fireworks API key deleted.", mood: .idle, clearAfter: 4)
    }

    func refreshFireworksAPIKeyStatus() {
        hasFireworksAPIKey = DevCredentialStore.hasFireworksAPIKey()
    }

    private func showAccessibilityRequiredMessage() {
        petViewModel.show(
            "Accessibility access is not active for this running app yet. Use Enable accessibility access or restart Sentinel Pet after granting access.",
            mood: .scanning,
            clearAfter: 10
        )
    }

    private func runFocusedAnalysis() async {
        do {
            let snapshot = try screenReader.readFocusedContext()
            guard !isDeniedByPrivacySettings(snapshot) else {
                showDeniedAppMessage(snapshot.appName)
                return
            }

            guard let apiKey = DevCredentialStore.readFireworksAPIKey() else {
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

    private func handleMonitorStatus(_ status: MonitorLoopStatus) {
        monitorStatus = status.label
    }

    private func handleMonitorVerdict(_ verdict: RiskVerdict) {
        monitorStatus = "Last check: \(verdict.riskLevel.rawValue)"

        guard settings.alertSensitivity.shouldInterrupt(for: verdict.riskLevel) else {
            return
        }

        petViewModel.show(
            message(for: verdict),
            mood: mood(for: verdict.riskLevel),
            clearAfter: clearDelay(for: verdict.riskLevel)
        )
    }

    private func handleMonitorError(_ error: Error) {
        let message = error.localizedDescription
        monitorStatus = "Monitor issue"

        if shouldStopMonitoring(after: error) {
            stopMonitoring()
            monitorStatus = "Monitoring stopped"
        }

        guard message != lastMonitorErrorMessage else {
            return
        }
        lastMonitorErrorMessage = message

        petViewModel.show(message, mood: .alert, clearAfter: 10)
    }

    private func shouldStopMonitoring(after error: Error) -> Bool {
        switch error {
        case ScreenReaderError.accessibilityPermissionRequired,
             FireworksRiskAnalyzerError.missingAPIKey:
            return true
        default:
            return false
        }
    }

    private func isDeniedByPrivacySettings(_ snapshot: ScreenSnapshot) -> Bool {
        PrivacyFilter.isDenied(snapshot: snapshot, deniedAppNames: settings.deniedAppNames)
    }

    private func showDeniedAppMessage(_ appName: String) {
        petViewModel.show(
            "I skipped \(appName) because it matches your sensitive-app deny list.",
            mood: .idle,
            clearAfter: 7
        )
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
