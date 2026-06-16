import Foundation

struct AppSettings {
    static let defaultModel = "accounts/fireworks/models/kimi-k2p7-code"
    static let legacyDefaultModels = [
        "accounts/fireworks/models/kimi-k2-instruct-0905"
    ]
    static let defaultDeniedAppNames = [
        "1Password",
        "Bitwarden",
        "Passwords",
        "Keychain Access",
        "Bank",
        "Chase",
        "Wells Fargo",
        "PayPal",
        "Venmo"
    ]

    var fireworksModel: String
    var monitoringConsentGranted: Bool
    var monitoringScreenshotContextEnabled: Bool
    var alertSensitivity: AlertSensitivity
    var deniedAppNames: [String]
}

enum AppSettingsStore {
    private static let modelKey = "fireworksModel"
    private static let monitoringConsentGrantedKey = "monitoringConsentGranted"
    private static let monitoringScreenshotContextEnabledKey = "monitoringScreenshotContextEnabled"
    private static let alertSensitivityKey = "alertSensitivity"
    private static let deniedAppNamesKey = "deniedAppNames"

    static func load() -> AppSettings {
        let savedModel = UserDefaults.standard.string(forKey: modelKey)
        let model: String
        if let savedModel,
           !AppSettings.legacyDefaultModels.contains(savedModel) {
            model = savedModel
        } else {
            model = AppSettings.defaultModel
            UserDefaults.standard.set(model, forKey: modelKey)
        }

        let sensitivity = UserDefaults.standard.string(forKey: alertSensitivityKey)
            .flatMap(AlertSensitivity.init(rawValue:)) ?? .standard
        let deniedAppNames = UserDefaults.standard.stringArray(forKey: deniedAppNamesKey)
            ?? AppSettings.defaultDeniedAppNames

        return AppSettings(
            fireworksModel: model,
            monitoringConsentGranted: UserDefaults.standard.bool(forKey: monitoringConsentGrantedKey),
            monitoringScreenshotContextEnabled: UserDefaults.standard.bool(
                forKey: monitoringScreenshotContextEnabledKey
            ),
            alertSensitivity: sensitivity,
            deniedAppNames: deniedAppNames
        )
    }

    static func save(_ settings: AppSettings) {
        UserDefaults.standard.set(settings.fireworksModel, forKey: modelKey)
        UserDefaults.standard.set(
            settings.monitoringConsentGranted,
            forKey: monitoringConsentGrantedKey
        )
        UserDefaults.standard.set(
            settings.monitoringScreenshotContextEnabled,
            forKey: monitoringScreenshotContextEnabledKey
        )
        UserDefaults.standard.set(settings.alertSensitivity.rawValue, forKey: alertSensitivityKey)
        UserDefaults.standard.set(settings.deniedAppNames, forKey: deniedAppNamesKey)
    }
}
