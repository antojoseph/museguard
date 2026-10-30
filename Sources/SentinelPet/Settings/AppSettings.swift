import Foundation

struct AppSettings {
    var monitoringConsentGranted: Bool
}
enum AppSettingsStore {
    static func load() -> AppSettings {
        let defaults = UserDefaults.standard
        return AppSettings(monitoringConsentGranted: defaults.bool(forKey: "localMonitoringConsentGranted"))
    }
    static func save(_ settings: AppSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.monitoringConsentGranted, forKey: "localMonitoringConsentGranted")
        defaults.removeObject(forKey: "alertSensitivity")
        defaults.removeObject(forKey: "deniedAppNames")
    }
}
