import Foundation

struct AppSettings {
    static let defaultModel = "accounts/fireworks/models/kimi-k2-instruct-0905"

    var fireworksModel: String
}

enum AppSettingsStore {
    private static let modelKey = "fireworksModel"

    static func load() -> AppSettings {
        let model = UserDefaults.standard.string(forKey: modelKey) ?? AppSettings.defaultModel
        return AppSettings(fireworksModel: model)
    }

    static func save(_ settings: AppSettings) {
        UserDefaults.standard.set(settings.fireworksModel, forKey: modelKey)
    }
}
