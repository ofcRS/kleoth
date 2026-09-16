// app/Sources/KleothOnDevice/AppleOnDeviceClient.swift
import Foundation
import KleothCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device language model behind ``ChatCompleting``. Dictation
/// polish only: the model's context is a fixed 4096 tokens, so a meeting
/// transcript never fits, and the only schema it answers is the polisher's
/// `dictation_text` (`{text, language}`), mirrored below as a `@Generable` type.
///
/// Nothing leaves the machine and no setup is needed beyond Apple
/// Intelligence being on — the "truly local" default for dictation on macOS 26.
public struct AppleOnDeviceClient: ChatCompleting {
    /// Roughly 3,500 tokens of Latin or ~1,700 of Cyrillic — refused up front
    /// rather than spending a call that `exceededContextWindowSize` would end.
    public static let maxPromptCharacters = 12_000

    public init() {}

    // MARK: - Availability

    public static func availability() -> ProviderAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available(detail: "Apple Intelligence on")
            case let .unavailable(reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable(reason: "This Mac does not support Apple Intelligence")
                case .appleIntelligenceNotEnabled:
                    return .unavailable(reason: "Apple Intelligence is off (System Settings → Apple Intelligence & Siri)")
                case .modelNotReady:
                    return .unavailable(reason: "The Apple model is still downloading")
                @unknown default:
                    return .unavailable(reason: "Apple Intelligence is unavailable")
                }
            }
        }
        #endif
        return .unavailable(reason: "Needs macOS 26")
    }

    // MARK: - ChatCompleting

    public func complete(
        messages: [ChatMessage], model: String, responseFormat: OpenRouterResponseFormat,
        maxTokens: Int, temperature: Double?, reasoning: OpenRouterReasoning?
    ) async throws -> ChatCompletion {
        guard case let .jsonSchema(name, _) = responseFormat, name == "dictation_text" else {
            throw ProviderError.unsupported("Apple on-device can only clean up dictations.")
        }
        let flat = ChatMessage.flattenForSingleTurn(messages)
        guard flat.prompt.count + (flat.system?.count ?? 0) <= Self.maxPromptCharacters else {
            throw ProviderError.inputTooLong
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: flat.system ?? "")
            let options = GenerationOptions(temperature: temperature ?? 0.2)
            do {
                let response = try await session.respond(to: flat.prompt, generating: PolishedText.self, options: options)
                let payload: [String: Any] = [
                    "text": response.content.text,
                    "language": response.content.language,
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                return ChatCompletion(content: String(decoding: data, as: UTF8.self), usage: nil, finishReason: "stop")
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error { throw ProviderError.inputTooLong }
                throw ProviderError.backend(error.localizedDescription)
            }
        }
        #endif
        throw ProviderError.unsupported("Apple on-device needs macOS 26.")
    }
}

#if canImport(FoundationModels)
/// The polisher's `dictation_text` schema (`DictationPrompt.schemaJSON`) as a
/// generable type. Keep the two in step: `text` + `language`.
@available(macOS 26, *)
@Generable
struct PolishedText {
    @Guide(description: "The cleaned-up text the speaker meant to type, in the same language they spoke.")
    var text: String
    @Guide(description: "BCP-47 code of the language the text is written in, e.g. en or ru.")
    var language: String
}
#endif
