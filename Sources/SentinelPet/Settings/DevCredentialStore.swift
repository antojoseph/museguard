import Foundation

/// Development-only credential storage.
///
/// This avoids login-keychain prompts while the app is being iterated locally.
/// Replace this with Keychain storage before distributing Sentinel Pet.
enum DevCredentialStore {
    private static let fireworksAPIKeyKey = "devFireworksAPIKey"

    static func hasFireworksAPIKey() -> Bool {
        readFireworksAPIKey()?.isEmpty == false
    }

    static func readFireworksAPIKey() -> String? {
        UserDefaults.standard.string(forKey: fireworksAPIKeyKey)
    }

    static func saveFireworksAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: fireworksAPIKeyKey)
    }

    static func deleteFireworksAPIKey() {
        UserDefaults.standard.removeObject(forKey: fireworksAPIKeyKey)
    }
}
