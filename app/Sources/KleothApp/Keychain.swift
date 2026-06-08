import Foundation
import Security

/// Thin wrapper over the macOS Keychain for storing API credentials and
/// app settings.
///
/// All values live in ONE consolidated generic-password item (service
/// `dev.kleoth`, account `settings`) holding a JSON dictionary, loaded once per
/// launch into an in-memory cache. One item + one read means the system's
/// keychain-permission dialog can appear at most ONCE per launch. (Each value
/// used to be its own item; the app reads six of them at startup, so any
/// signature/ACL mismatch — e.g. after re-installing a self-signed build —
/// produced a burst of 5–6 prompts on every start until each item was
/// individually "Always Allow"ed.)
///
/// When the one prompt does appear, click **Always Allow**: the ACL stores the
/// app's designated requirement, which is anchored to the stable
/// "Kleoth Self-Signed" certificate, so subsequent launches and rebuilds stay
/// silent.
///
/// Legacy per-value items are migrated into the consolidated item on first
/// load and deleted only after their values were read successfully — a denied
/// permission prompt never destroys a stored key (migration just retries on a
/// later launch). Values are never logged or printed.
public enum Keychain {
    /// The Keychain service identifier shared by every Kleoth item.
    public static let service = "dev.kleoth"

    /// Account name of the single consolidated settings item.
    static let consolidatedAccount = "settings"

    /// Well-known account names used by the app (now keys inside the
    /// consolidated item; previously each was its own keychain item).
    public enum Account {
        public static let elevenLabsKey = "elevenlabs_api_key"
        public static let openRouterKey = "openrouter_api_key"
        public static let outputDir = "output_dir"
        public static let defaultModel = "default_model"
        public static let transcriptionLanguage = "transcription_language"
        public static let consentAcknowledged = "consent_acknowledged"
        /// The user's display name — labels their own voice (`speaker_0`) in
        /// transcripts instead of the generic "You". Set during onboarding.
        public static let userName = "user_name"
        /// "true" once the first-run onboarding window has been completed (or
        /// skipped), so it never auto-opens again.
        public static let onboardingCompleted = "onboarding_completed"
    }

    /// Every legacy per-value account, for the one-time migration.
    private static let legacyAccounts: [String] = [
        Account.elevenLabsKey,
        Account.openRouterKey,
        Account.outputDir,
        Account.defaultModel,
        Account.transcriptionLanguage,
        Account.consentAcknowledged,
    ]

    /// Errors surfaced from Keychain operations.
    public enum KeychainError: Error, CustomStringConvertible, Sendable {
        /// A `SecItem*` call returned a non-success `OSStatus`.
        case unhandled(OSStatus)
        /// A stored item could not be decoded as UTF-8 text / JSON.
        case malformedData

        public var description: String {
            switch self {
            case .unhandled(let status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                return "Keychain error \(status): \(message ?? "unknown")"
            case .malformedData:
                return "Keychain item could not be decoded."
            }
        }
    }

    // MARK: - In-memory cache (one keychain read per launch)

    private static let lock = NSLock()
    /// Decoded contents of the consolidated item. `nil` until the first
    /// successful load; never set after a denied/failed read, so a later access
    /// retries instead of silently working from (and then writing back) an
    /// empty dictionary that would clobber stored values.
    nonisolated(unsafe) private static var cache: [String: String]?

    // MARK: - Labeled API (frozen skeleton contract)

    /// Stores `value` under `account`, updating the consolidated item in place.
    ///
    /// An empty `value` removes the entry instead, so callers can treat an
    /// empty field as "clear this secret".
    public static func set(_ value: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var values = try loadLocked()
        if value.isEmpty {
            values.removeValue(forKey: account)
        } else {
            values[account] = value
        }
        try writeLocked(values)
    }

    /// Reads the value stored under `account`, if any.
    public static func get(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()[account]
    }

    /// Removes any value stored under `account`. A missing entry is not an error.
    public static func remove(account: String) throws {
        try set("", account: account)
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

    // MARK: - Consolidated storage

    /// Returns the settings dictionary, reading the consolidated item once and
    /// caching it. A missing item (first run on this scheme) triggers the
    /// legacy migration; a *failed* read (e.g. the user denied the permission
    /// prompt) throws instead — deliberately NOT falling through to migration,
    /// which would replace one denied prompt with a burst of six.
    /// Assumes `lock` is held.
    private static func loadLocked() throws -> [String: String] {
        if let cache { return cache }

        if let data = try readItemData(account: consolidatedAccount) {
            guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                // Corrupted blob: fall back to migration (which also rebuilds
                // the item from any legacy values still present).
                let migrated = migrateLegacyLocked()
                cache = migrated
                return migrated
            }
            cache = decoded
            return decoded
        }

        // No consolidated item yet → first run on this scheme: migrate.
        let migrated = migrateLegacyLocked()
        cache = migrated
        return migrated
    }

    /// Persists the dictionary to the consolidated item and refreshes the cache.
    /// Assumes `lock` is held.
    private static func writeLocked(_ values: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(values) else {
            throw KeychainError.malformedData
        }
        try upsertItemData(data, account: consolidatedAccount)
        cache = values
    }

    /// One-time migration from the legacy one-item-per-value layout: reads each
    /// legacy item, folds the found values into the consolidated item, and only
    /// then deletes the legacy items it could read. If any read fails (denied
    /// prompt, transient error), nothing is written or deleted — the values
    /// found are still returned for this launch, and migration retries next
    /// launch. Assumes `lock` is held.
    private static func migrateLegacyLocked() -> [String: String] {
        var values: [String: String] = [:]
        var migrated: [String] = []
        var sawReadFailure = false

        for account in legacyAccounts {
            do {
                if let data = try readItemData(account: account),
                   let string = String(data: data, encoding: .utf8) {
                    values[account] = string
                    migrated.append(account)
                }
            } catch {
                sawReadFailure = true
            }
        }

        if !sawReadFailure {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = (try? encoder.encode(values)) ?? Data("{}".utf8)
                try upsertItemData(data, account: consolidatedAccount)
                // The blob now owns these values; remove the per-value items so
                // they can never prompt again.
                for account in migrated {
                    deleteItem(account: account)
                }
            } catch {
                // Couldn't write the consolidated item — keep the legacy items
                // untouched and retry next launch.
            }
        }
        return values
    }

    // MARK: - Raw item plumbing

    /// Reads the raw data of one keychain item. `nil` means the item does not
    /// exist; any other failure throws (so callers can tell "absent" from
    /// "denied").
    private static func readItemData(account: String) throws -> Data? {
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
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status)
        }
    }

    /// Creates or updates one keychain item with the given raw data.
    private static func upsertItemData(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

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

    /// Deletes one keychain item, ignoring failures (missing item, etc.).
    private static func deleteItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
