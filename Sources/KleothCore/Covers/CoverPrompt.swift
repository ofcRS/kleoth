import Foundation

/// The prompt every image engine gets (design doc 2026-09-24 §3.4). The
/// wording is the look test's settled text (`.scratch/cover-spike/RESULTS.md`,
/// "Settled wording", approved 2026-09-25), which differs from §3.4 in one
/// clause: "generous margins" became an explicit edge-to-edge instruction,
/// because it invited a baked-in mat, card or border in 10 of 23 test images,
/// and a matted picture reads as a pale square at 56 pt. The shape changed on
/// 2026-09-28 (design §10, landscape addendum): a wide 16:9 picture for the
/// meeting page's full-width band, with the subject kept to the middle so the
/// 56 pt row tile, a square cut from the centre, still shows it.
public enum CoverPrompt {
    /// The prompt's last two sentences. Kept separate and public so the tests
    /// and every engine can check it is present word for word: it is what keeps
    /// lettering and people out of a picture.
    public static let guardrail = "Strictly no text, letters, numbers, logos, signs, watermarks or captions. No humans, human faces or hands."

    /// What a cover must be to work both as the page's band and as a 56 pt History tile.
    static let composition = "One clear focal scene: the characters close together in the centre of the picture, fully in view with their heads well clear of the top edge, and open, simple, uncluttered background on both sides that carries on to the left and right edges; it must read as a wide banner and as a small square thumbnail cut from its centre. The picture fills the whole frame edge to edge: no border, mat, card or vignette."

    /// "A wide 16:9 cover illustration for a meeting. ‹scene› Style: ‹style
    /// sentence› ‹composition› ‹guardrail›". `scene` is the sanitized scene
    /// (`CoverSceneWriter.sanitize`), exactly as `cover.json` records it.
    public static func imagePrompt(scene: String, style: CoverStyle) -> String {
        "A wide 16:9 cover illustration for a meeting. \(scene) Style: \(style.promptSentence) \(composition) \(guardrail)"
    }
}
