import Testing
@testable import KleothCore

/// The image prompt (design doc 2026-09-24 §3.4, as settled by the look test):
/// the scene, the style sentence, the thumbnail framing and the no-text /
/// no-humans guardrail, in that order.
@Suite struct CoverPromptTests {
    @Test func everyStyleGetsSceneStyleSentenceAndGuardrail() {
        for style in CoverStyle.allCases {
            let prompt = CoverPrompt.imagePrompt(scene: "an otter naps", style: style)

            #expect(prompt.hasPrefix("A square cover illustration for a meeting. an otter naps "), "\(style)")
            #expect(prompt.contains("Style: \(style.promptSentence)"), "\(style)")
            #expect(prompt.contains("it must read as a small thumbnail."), "\(style)")
            #expect(prompt.hasSuffix(CoverPrompt.guardrail), "\(style)")
        }
    }

    @Test func guardrailIsVerbatim() {
        #expect(CoverPrompt.guardrail == "Strictly no text, letters, numbers, logos, signs, watermarks or captions. No humans, human faces or hands.")
    }
}
