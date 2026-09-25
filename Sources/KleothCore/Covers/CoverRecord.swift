import Foundation

/// What `cover.json` says about a meeting's cover (design doc 2026-09-24 §4.1).
/// The record, not the picture, decides whether a cover is drawn automatically:
/// any record — even `removed` or `skipped` — means the meeting has been
/// decided on, while a picture with no record is one the user dropped in.
///
/// Encoded with `MeetingStore.makeEncoder()` / `makeDecoder()`. There are no
/// custom `CodingKeys`: every property name is acronym-free, so the snake_case
/// strategies round-trip it (`sceneProvider` ↔ `scene_provider`).
public struct CoverRecord: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// A picture was drawn and installed as `cover.jpg`.
        case drawn
        /// The scene step judged the meeting personal; no image call was made.
        case skipped
        /// The user removed the cover; nothing is drawn automatically again.
        case removed
    }

    public var state: State
    /// Why a cover was skipped: `"sensitive"`.
    public var reason: String?
    /// The `CoverEngine` raw value that drew the picture.
    public var engine: String?
    /// The image model, as sent (empty for Codex, which uses its own tool).
    public var model: String?
    /// The `CoverStyle` raw value the picture was drawn in.
    public var style: String?
    /// Exactly the scene that was sent to the image model (the History tooltip).
    public var scene: String?
    /// The `AIProvider` raw value that wrote the scene.
    public var sceneProvider: String?
    public var sceneModel: String?
    /// ISO-8601 with time (`CoverRecord.timestamp`); the Usage tally's window reads it.
    public var createdAt: String
    /// USD as reported (image + scene); nil = free or unreported (Codex, a local server).
    public var cost: Double?
    /// Wall clock of the image call, for diagnostics.
    public var seconds: Double?

    public init(
        state: State,
        reason: String? = nil,
        engine: String? = nil,
        model: String? = nil,
        style: String? = nil,
        scene: String? = nil,
        sceneProvider: String? = nil,
        sceneModel: String? = nil,
        createdAt: String,
        cost: Double? = nil,
        seconds: Double? = nil
    ) {
        self.state = state
        self.reason = reason
        self.engine = engine
        self.model = model
        self.style = style
        self.scene = scene
        self.sceneProvider = sceneProvider
        self.sceneModel = sceneModel
        self.createdAt = createdAt
        self.cost = cost
        self.seconds = seconds
    }

    /// The canonical `createdAt` stamp: ISO-8601 with time, in UTC, whole seconds.
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The parsed `createdAt`, or nil when it isn't the `timestamp` format (a
    /// hand-edited file); such a record falls outside every Usage window.
    public var createdDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: createdAt)
    }
}
