import Foundation

struct AppSettings {
    static let defaultModel = "accounts/fireworks/models/kimi-k2p7-code"
    static let legacyDefaultModels = [
        "accounts/fireworks/models/kimi-k2-instruct-0905"
    ]

    var fireworksModel: String
}

enum AppSettingsStore {
    private static let modelKey = "fireworksModel"

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
        return AppSettings(fireworksModel: model)
    }

    static func save(_ settings: AppSettings) {
        UserDefaults.standard.set(settings.fireworksModel, forKey: modelKey)
    }
}
