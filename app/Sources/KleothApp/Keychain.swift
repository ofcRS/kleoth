import Foundation
import Security

/// Thin wrapper over the macOS Keychain for storing API credentials.
///
/// All items live under the generic-password class (`kSecClassGenericPassword`)
/// with the fixed service identifier `dev.kleoth`. Values are stored as UTF-8
/// data and are never logged or printed.
public enum Keychain {
    /// The Keychain service identifier shared by every Kleoth item.
    public static let service = "dev.kleoth"

    /// Well-known account names used by the app.
    public enum Account {
        public static let elevenLabsKey = "elevenlabs_api_key"
        public static let openRouterKey = "openrouter_api_key"
        public static let slackWebhook = "slack_webhook"
        public static let outputDir = "output_dir"
        public static let defaultModel = "default_model"
        public static let transcriptionLanguage = "transcription_language"
        public static let consentAcknowledged = "consent_acknowledged"
    }

    /// Errors surfaced from Keychain operations.
    public enum KeychainError: Error, CustomStringConvertible, Sendable {
        /// A `SecItem*` call returned a non-success `OSStatus`.
        case unhandled(OSStatus)
        /// A stored item could not be decoded as UTF-8 text.
        case malformedData

        public var description: String {
            switch self {
            case .unhandled(let status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                return "Keychain error \(status): \(message ?? "unknown")"
            case .malformedData:
                return "Keychain item could not be decoded as UTF-8."
            }
        }
    }

    // MARK: - Labeled API (frozen skeleton contract)

    /// Stores `value` under `account` in the generic-password keychain,
    /// updating any existing item in place.
    ///
    /// An empty `value` removes the item instead, so callers can treat an empty
    /// field as "clear this secret".
    public static func set(_ value: String, account: String) throws {
        guard !value.isEmpty else {
            try remove(account: account)
            return
        }

        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Try to update an existing item first.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(addStatus)
            }
        default:
            throw KeychainError.unhandled(updateStatus)
        }
    }

    /// Reads the value stored under `account`, if any.
    public static func get(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.malformedData }
            guard let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.malformedData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status)
        }
    }

    /// Removes any value stored under `account`. A missing item is not an error.
    public static func remove(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    // MARK: - Positional convenience API (spec ergonomics)
    //
    // The spec describes `get(_:)`, `set(_:_:)`, `delete(_:)`. These map onto the
    // labeled API above and never throw (they swallow errors and return nil/`false`),
    // which suits non-throwing SwiftUI call sites.

    /// Non-throwing read; returns `nil` if absent or on any Keychain error.
    public static func get(_ account: String) -> String? {
        (try? get(account: account)) ?? nil
    }

    /// Non-throwing write; returns `true` on success.
    @discardableResult
    public static func set(_ value: String, _ account: String) -> Bool {
        do {
            try set(value, account: account)
            return true
        } catch {
            return false
        }
    }

    /// Non-throwing delete; returns `true` on success (including no-op delete).
    @discardableResult
    public static func delete(_ account: String) -> Bool {
        do {
            try remove(account: account)
            return true
        } catch {
            return false
        }
    }
}
