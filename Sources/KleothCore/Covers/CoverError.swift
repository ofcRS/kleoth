import Foundation

/// Every way drawing a cover can fail that is the cover layer's own; the
/// provider layer's failures stay `ProviderError`. The copy is what follows
/// "Couldn't draw a cover — " on the History tile (design doc §5).
/// `Equatable` so tests can match a case.
public enum CoverError: Error, LocalizedError, Equatable, Sendable {
    /// The meeting has no `summary.json`: the scene is never written from the transcript.
    case noSummary
    /// The scene step's answer did not decode; the detail is for the log only.
    case sceneUnreadable(String)
    /// The image call succeeded but carried no picture.
    case noImage
    /// The bytes that came back are not a PNG, JPEG or WebP ImageIO can read.
    case unreadableImage
    /// A non-2xx answer from an image endpoint. The History wording per status
    /// (401, 402, …) lives with the drawing, which knows the engine.
    case http(status: Int, body: String)
    /// The model refused the prompt (moderation); the detail is for the log only.
    case refused(String)
    /// OpenRouter's 404 "no endpoints … data policy": the account's no-train/ZDR
    /// settings leave `model` without an endpoint. It names the model so the
    /// user knows which pick to change.
    case dataPolicy(model: String)

    public var errorDescription: String? {
        switch self {
        case .noSummary:
            return "Needs a summary"
        case .sceneUnreadable:
            return "The scene came back unreadable"
        case .noImage:
            return "The image model returned no image"
        case .unreadableImage:
            return "The image model returned an unreadable image"
        case let .http(status, _):
            return "HTTP \(status)"
        case .refused:
            return "The image model refused this scene — try New Cover"
        case let .dataPolicy(model):
            return "OpenRouter's data policy on this account allows no endpoint for \(model) — pick another image model in Settings → Meetings"
        }
    }
}
