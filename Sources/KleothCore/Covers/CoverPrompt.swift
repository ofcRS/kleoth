import Foundation

/// The prompt every image engine gets (design doc 2026-09-24 §3.4). The
/// wording is the look test's settled text (`.scratch/cover-spike/RESULTS.md`,
/// "Settled wording", approved 2026-09-25), which differs from §3.4 in one
/// clause: "generous margins" became an explicit edge-to-edge instruction,
/// because it invited a baked-in mat, card or border in 10 of 23 test images,
/// and a matted picture reads as a pale square at 56 pt.
public enum CoverPrompt {
    /// The prompt's last two sentences. Kept separate and public so the tests
    /// and every engine can check it is present word for word: it is what keeps
    /// lettering and people out of a picture.
    public static let guardrail = "Strictly no text, letters, numbers, logos, signs, watermarks or captions. No humans, human faces or hands."

    /// What a cover must be to work as a 56 pt History tile.
    static let composition = "One clear focal scene, centred, simple uncluttered background; it must read as a small thumbnail. The picture fills the whole square edge to edge: no border, frame, mat, card or vignette."

    /// "A square cover illustration for a meeting. ‹scene› Style: ‹style
    /// sentence› ‹composition› ‹guardrail›". `scene` is the sanitized scene
    /// (`CoverSceneWriter.sanitize`), exactly as `cover.json` records it.
    public static func imagePrompt(scene: String, style: CoverStyle) -> String {
        "A square cover illustration for a meeting. \(scene) Style: \(style.promptSentence) \(composition) \(guardrail)"
    }
}
