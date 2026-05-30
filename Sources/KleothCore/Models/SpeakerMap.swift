import Foundation

/// Maps Scribe speaker identifiers (e.g. `"speaker_0"`) to human-readable
/// display names (e.g. `"Alice"`).
public struct SpeakerMap: Codable, Sendable {
    public var names: [String: String]

    public init(names: [String: String] = [:]) {
        self.names = names
    }
}
