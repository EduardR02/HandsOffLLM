import Foundation
import Security
import OSLog

/// Lightweight wrapper around the iOS keychain for storing sensitive user configuration
struct KeychainService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HandsOffLLM", category: "Keychain")
    static let shared = KeychainService()
    private init() {}

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case invalidData
    }

    func set(_ value: String?, for key: String) throws {
        let account = key
        let encodedKey = account.data(using: .utf8)!

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "HandsOffLLM",
            kSecAttrAccount as String: encodedKey
        ]

        if let value = value, !value.isEmpty {
            let data = Data(value.utf8)

            var status = SecItemCopyMatching(baseQuery as CFDictionary, nil)
            switch status {
            case errSecSuccess:
                let attributesToUpdate = [kSecValueData as String: data]
                status = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
            case errSecItemNotFound:
                var attributes = baseQuery
                attributes[kSecValueData as String] = data
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(attributes as CFDictionary, nil)
            default:
                break
            }

            guard status == errSecSuccess else {
                logger.error("Keychain set failed (\(key)): status \(status)")
                throw KeychainError.unexpectedStatus(status)
            }
        } else {
            try removeValue(for: key)
        }
    }

    func string(for key: String) throws -> String? {
        let encodedKey = key.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "HandsOffLLM",
            kSecAttrAccount as String: encodedKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            logger.error("Keychain fetch failed (\(key)): status \(status)")
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        return string
    }

    func removeValue(for key: String) throws {
        let encodedKey = key.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "HandsOffLLM",
            kSecAttrAccount as String: encodedKey
        ]
        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Keychain delete failed (\(key)): status \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
