import Foundation

/// What the detector found for one provider. `detail` / `reason` are the
/// strings Settings shows under the provider's name.
public enum ProviderAvailability: Sendable, Equatable {
    /// `models` is filled only for the local server (its `/v1/models` ids),
    /// so an empty model pick can default to the first one it serves.
    case available(detail: String, models: [String] = [])
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

public typealias ProviderSnapshot = [AIProvider: ProviderAvailability]

/// Picks the provider for one task from the user's choice and a snapshot.
/// Pure — `ProviderDetector` produces the snapshot, the factory acts on the
/// resolution.
public enum ProviderResolver {
    public enum Resolution: Sendable, Equatable {
        /// Use this provider. `fellThroughFrom` names an explicit pick that
        /// cannot do the task (Apple on-device asked for a summary) — Settings
        /// says so in its footer.
        case provider(AIProvider, fellThroughFrom: AIProvider?)
        /// The user picked a provider that can do the task but is not usable
        /// right now (not installed, not signed in, server down). Surfaced as
        /// an error, never silently replaced.
        case unavailable(AIProvider, reason: String)
        /// Nothing can do the task.
        case none
    }

    public static func resolve(task: AIProvider.Task, pick: AIProvider?, snapshot: ProviderSnapshot) -> Resolution {
        if let pick {
            if pick.supports(task) {
                switch snapshot[pick] {
                case .available:
                    return .provider(pick, fellThroughFrom: nil)
                case let .unavailable(reason):
                    return .unavailable(pick, reason: reason)
                case nil:
                    return .unavailable(pick, reason: "Not detected")
                }
            }
            if let next = firstAvailable(task: task, snapshot: snapshot, excluding: pick) {
                return .provider(next, fellThroughFrom: pick)
            }
            return .none
        }
        if let first = firstAvailable(task: task, snapshot: snapshot, excluding: nil) {
            return .provider(first, fellThroughFrom: nil)
        }
        return .none
    }

    private static func firstAvailable(task: AIProvider.Task, snapshot: ProviderSnapshot, excluding: AIProvider?) -> AIProvider? {
        AIProvider.autoOrder.first { provider in
            provider != excluding && provider.supports(task) && (snapshot[provider]?.isAvailable ?? false)
        }
    }
}
