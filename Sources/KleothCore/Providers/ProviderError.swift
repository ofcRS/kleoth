import Foundation

/// Every way a language-model backend can be unusable, with the exact copy
/// the app shows (design doc §6). `Equatable` so tests can match a case.
public enum ProviderError: Error, Equatable, Sendable {
    /// Nothing is configured or installed that can do the task.
    case noProvider
    case notInstalled(tool: String)
    case notSignedIn(tool: String)
    case unreachable(url: URL)
    /// `hint` is the command that fixes it (e.g. `ollama pull llama3`).
    case modelMissing(model: String, hint: String)
    /// The input exceeds the backend's context (Apple on-device: 4096 tokens).
    case inputTooLong
    /// The backend cannot do what was asked (e.g. Apple asked for a summary).
    case unsupported(String)
    /// The backend answered with an error of its own; `message` is verbatim.
    case backend(String)
    case timedOut
}

extension ProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noProvider:
            return "No AI provider available — open Settings → Accounts."
        case let .notInstalled(tool):
            return "\(tool) is not installed."
        case let .notSignedIn(tool):
            let command = tool == "Codex" ? "codex login" : "claude"
            return "\(tool) is not signed in. Open a terminal, run `\(command)`, and sign in."
        case let .unreachable(url):
            var origin = url.scheme.map { "\($0)://" } ?? ""
            origin += url.host ?? ""
            if let port = url.port { origin += ":\(port)" }
            return "No server at \(origin) — is Ollama running?"
        case let .modelMissing(model, hint):
            return "Model '\(model)' is not on the local server — run `\(hint)`."
        case .inputTooLong:
            return "Too long for the on-device model."
        case let .unsupported(what):
            return what
        case let .backend(message):
            return message
        case .timedOut:
            return "The AI provider did not answer in time."
        }
    }
}
