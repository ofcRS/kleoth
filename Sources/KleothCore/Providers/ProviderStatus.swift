import Foundation

/// What Settings, the popover and onboarding show about the providers: the
/// snapshot plus the resolution for each task. Built by `AppConfig` /
/// `ProviderBootstrap`, displayed as `footerText`.
public struct ProviderStatus: Sendable, Equatable {
    public let snapshot: ProviderSnapshot
    public let summary: Result<ProviderFactory.Selection, ProviderError>
    public let dictation: Result<ProviderFactory.Selection, ProviderError>

    public init(snapshot: ProviderSnapshot,
                summary: Result<ProviderFactory.Selection, ProviderError>,
                dictation: Result<ProviderFactory.Selection, ProviderError>) {
        self.snapshot = snapshot
        self.summary = summary
        self.dictation = dictation
    }

    /// "Summaries via Claude Code (Apple on-device cannot summarize) · Dictation via Apple on-device"
    public var footerText: String {
        [Self.line("Summaries", summary, cannot: "summarize"),
         Self.line("Dictation", dictation, cannot: "clean up dictations")].joined(separator: " · ")
    }

    /// Display names of every available provider, in auto order (onboarding caption).
    public var detectedNames: [String] {
        AIProvider.autoOrder.filter { snapshot[$0]?.isAvailable ?? false }.map(\.displayName)
    }

    private static func line(_ task: String, _ result: Result<ProviderFactory.Selection, ProviderError>, cannot verb: String) -> String {
        switch result {
        case let .success(selection):
            var text = "\(task) via \(selection.provider.displayName)"
            if let from = selection.fellThroughFrom { text += " (\(from.displayName) cannot \(verb))" }
            return text
        case let .failure(error):
            return "\(task): \(error.localizedDescription)"
        }
    }
}
