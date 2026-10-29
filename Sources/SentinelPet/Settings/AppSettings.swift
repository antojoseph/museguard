import Foundation

struct AppSettings {
    static let defaultModel = LocalModelConfiguration.model
    static let defaultDeniedAppNames = ["1Password", "Bitwarden", "Passwords", "Keychain Access", "Bank", "Chase", "Wells Fargo", "PayPal", "Venmo"]
    var modelName: String
    var monitoringConsentGranted: Bool
    var alertSensitivity: AlertSensitivity
    var deniedAppNames: [String]
}
enum AppSettingsStore {
    static func load() -> AppSettings {
        let defaults = UserDefaults.standard
        return AppSettings(modelName: defaults.string(forKey: "localModelName") ?? AppSettings.defaultModel,
                           monitoringConsentGranted: defaults.bool(forKey: "localMonitoringConsentGranted"),
                           alertSensitivity: defaults.string(forKey: "alertSensitivity").flatMap(AlertSensitivity.init(rawValue:)) ?? .standard,
                           deniedAppNames: defaults.stringArray(forKey: "deniedAppNames") ?? AppSettings.defaultDeniedAppNames)
    }
    static func save(_ settings: AppSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.modelName, forKey: "localModelName")
        defaults.set(settings.monitoringConsentGranted, forKey: "localMonitoringConsentGranted")
        defaults.set(settings.alertSensitivity.rawValue, forKey: "alertSensitivity")
        defaults.set(settings.deniedAppNames, forKey: "deniedAppNames")
    }
}
