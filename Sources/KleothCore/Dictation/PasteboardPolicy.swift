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

    // MARK: Work bounds

    /// Reading a flavor off a foreign pasteboard item is a synchronous IPC that
    /// makes the owning app *materialize* it (a layered image in Photoshop or
    /// Figma registers TIFF, PDF, PSD and PNG lazily and renders each on
    /// demand). There is no public API for a flavor's size without fetching
    /// it, so the only way to bound that work is to bound what we ask for:
    /// a per-item flavor budget, plus an early stop once the running total is
    /// already large. The capture also runs off the main actor under a
    /// wall-clock timeout (`captureTimeout`) for the owner that never answers.

    /// Flavors always read (they are small and they are what a restore most
    /// needs to put back). They do not count against `maxTypesPerItem`.
    public static let preferredTypes: [String] = [
        "public.utf8-plain-text",
        "public.rtf",
        "public.html",
        "public.file-url",
        "public.url",
    ]

    /// How many *non-preferred* flavors of one item are read, in the item's
    /// own preference order (the first types are the ones readers want).
    public static let maxTypesPerItem = 6

    /// Once the running total passes this, no further non-preferred flavor is
    /// read — a multi-flavor image clipboard then costs one materialization,
    /// not five, and the restore still holds the flavor readers ask for first.
    public static let earlyStopBytes = maxBytes / 2

    /// Wall-clock budget for the whole capture. Past it the snapshot is
    /// treated as unavailable (never restored; the dictated text simply stays
    /// on the clipboard) rather than stalling the paste on a beachballing
    /// owner.
    public static let captureTimeout: TimeInterval = 0.4

    /// The subset of an item's declared types to read: every capturable
    /// preferred type, plus the first `maxTypesPerItem` others, in declared
    /// order.
    public static func typesToCapture(from declared: [String]) -> [String] {
        var budget = maxTypesPerItem
        var result: [String] = []
        for type in declared where shouldCapture(type: type) {
            if preferredTypes.contains(type) {
                result.append(type)
            } else if budget > 0 {
                result.append(type)
                budget -= 1
            }
        }
        return result
    }

    /// Whether to read one more flavor given what has been read so far:
    /// preferred types always, others only while the total is under
    /// `earlyStopBytes`.
    public static func shouldRead(type: String, byteCountSoFar: Int) -> Bool {
        preferredTypes.contains(type) || byteCountSoFar < earlyStopBytes
    }
}
