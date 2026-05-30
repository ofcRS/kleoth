import Foundation
import Security

/// Thin wrapper over the macOS Keychain for storing API credentials.
public enum Keychain {
    /// Stores `value` under `account` in the generic-password keychain.
    public static func set(_ value: String, account: String) throws {
        fatalError("unimplemented")
    }

    /// Reads the value stored under `account`, if any.
    public static func get(account: String) throws -> String? {
        fatalError("unimplemented")
    }

    /// Removes any value stored under `account`.
    public static func remove(account: String) throws {
        fatalError("unimplemented")
    }
}
