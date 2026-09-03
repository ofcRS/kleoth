import Foundation

/// Every *decision* the dictation text inserter makes about the pasteboard,
/// as pure functions (design §3.20 / §5.5).
///
/// The app package has no test target, so the AppKit glue
/// (`PasteboardSnapshot`, `TextInserter`) delegates each judgement call here —
/// the same split as `PillGeometry` / `DictationChordMachine`. The single
/// data-loss-critical rule (`shouldRestore`) is therefore covered by
/// `PasteboardPolicyTests`.
public enum PasteboardPolicy {
    /// Upper bound on a captured snapshot. Past this we capture nothing and
    /// never restore — a 24 MB+ clipboard is a video/PSD the user would rather
    /// keep on their own clipboard than have us copy twice through memory.
    public static let maxBytes = 24 * 1024 * 1024

    /// UTIs (and their legacy pasteboard-type spellings) that are never
    /// captured: they are *promises* and handles, not data. Reading them
    /// yields a token that is meaningless once the promising app has moved
    /// on, so writing it back would restore a dangling reference rather than
    /// the user's clipboard.
    public static let skippedTypes: Set<String> = [
        // kPasteboardTypeFileURLPromise / kPasteboardTypeFilePromiseContent
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        // NSFilePromiseProvider's metadata sibling + the legacy promise type.
        "com.apple.NSFilePromiseItemMetaData",
        "Apple files promise pasteboard type",
        "NSFilesPromisePboardType",
        // Legacy NSFileContentsPboardType, both spellings.
        "NeXT file contents pasteboard type",
        "NSFileContentsPboardType",
    ]

    /// Whether one pasteboard type carries restorable bytes.
    public static func shouldCapture(type rawType: String) -> Bool {
        !skippedTypes.contains(rawType)
    }

    /// THE data-loss-critical decision. Put the user's clipboard back only when
    /// (a) we still own the pasteboard — nobody copied anything since our write,
    /// so `currentChangeCount == ownedChangeCount` — and (b) the snapshot we hold
    /// is complete (`!exceededCap`). A newer copy by the user always wins.
    public static func shouldRestore(ownedChangeCount: Int, currentChangeCount: Int, exceededCap: Bool) -> Bool {
        guard !exceededCap else { return false }
        return ownedChangeCount == currentChangeCount
    }

    /// Running-total cap check used while capturing item data. Inclusive at the
    /// boundary: exactly `maxBytes` is still captured.
    public static func withinCap(byteCount: Int) -> Bool {
        byteCount <= maxBytes
    }
}
