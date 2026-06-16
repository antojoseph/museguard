import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            return "Keychain returned status \(status)."
        case .invalidData:
            return "Keychain returned unreadable data."
        }
    }
}

enum KeychainStore {
    private static let service = "com.sentinelpet.fireworks"
    private static let apiKeyAccount = "api-key"

    static func hasFireworksAPIKey() -> Bool {
        (try? readFireworksAPIKey())?.isEmpty == false
    }

    static func readFireworksAPIKey() throws -> String? {
        var query = baseQuery(account: apiKeyAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }

        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }

        return value
    }

    static func saveFireworksAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)

        var addQuery = baseQuery(account: apiKeyAccount)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }

        guard addStatus == errSecDuplicateItem else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }

        let updateStatus = SecItemUpdate(
            baseQuery(account: apiKeyAccount) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        guard updateStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }
    }

    static func deleteFireworksAPIKey() throws {
        let status = SecItemDelete(baseQuery(account: apiKeyAccount) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
