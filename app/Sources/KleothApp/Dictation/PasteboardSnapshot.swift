import AppKit
import KleothCore
import os

/// A deep copy of everything on a pasteboard — every item, every type, raw
/// `Data` (design §3.20 / §5.5).
///
/// Why a copy and not the `NSPasteboardItem`s themselves: Apple's docs are
/// explicit that items returned by `pasteboardItems` are *bound to that
/// pasteboard*, that `writeObjects(_:)` on them throws, and that they go stale
/// as soon as ownership changes — which our own `clearContents()` guarantees.
/// So we read the bytes out per item (types read from the item, not from
/// `pasteboard.types`, which flattens multi-item clipboards) and rebuild fresh
/// items on restore.
///
/// Every judgement call — which types to skip, the size cap — lives in
/// `PasteboardPolicy` in KleothCore, where it is unit-tested.
struct PasteboardSnapshot: Sendable {
    /// One type/bytes pair. Kept as an ordered array rather than a dictionary:
    /// the order of an item's types is its preference order, and readers ask
    /// for the first type they understand.
    struct Payload: Sendable, Equatable {
        let type: String
        let data: Data
    }

    private(set) var items: [[Payload]]
    private(set) var byteCount: Int
    /// True when the clipboard was bigger than `PasteboardPolicy.maxBytes`.
    /// Such a snapshot holds nothing and must never be restored (it would wipe
    /// the user's data instead of putting it back).
    private(set) var exceededCap: Bool

    init(items: [[Payload]] = [], byteCount: Int = 0, exceededCap: Bool = false) {
        self.items = items
        self.byteCount = byteCount
        self.exceededCap = exceededCap
    }

    var isEmpty: Bool { items.isEmpty }

    /// "No snapshot to restore": the capture timed out (a beachballing owner
    /// never materialized its flavors) or was never taken. Shares the
    /// `exceededCap` semantics — never restored, the dictated text just stays
    /// on the clipboard — because that is exactly the safe outcome.
    static let unavailable = PasteboardSnapshot(exceededCap: true)

    /// Reads the bounded set of flavors off each item (see
    /// `PasteboardPolicy.typesToCapture` / `shouldRead`), skipping promise
    /// types and bailing out (with `exceededCap`) once the running total passes
    /// the cap. Synchronous: `item.data(forType:)` is an IPC to the owning app
    /// that makes it *materialize* the flavor, so call this through
    /// `capture(pasteboardNamed:timeout:)` from the main actor, never inline.
    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        var items: [[Payload]] = []
        var total = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var payloads: [Payload] = []
            for rawType in PasteboardPolicy.typesToCapture(from: item.types.map(\.rawValue)) {
                guard PasteboardPolicy.shouldRead(type: rawType, byteCountSoFar: total) else { continue }
                guard let data = item.data(forType: NSPasteboard.PasteboardType(rawType)) else { continue }
                total += data.count
                guard PasteboardPolicy.withinCap(byteCount: total) else {
                    return PasteboardSnapshot(items: [], byteCount: total, exceededCap: true)
                }
                payloads.append(Payload(type: rawType, data: data))
            }
            if !payloads.isEmpty {
                items.append(payloads)
            }
        }
        return PasteboardSnapshot(items: items, byteCount: total, exceededCap: false)
    }

    /// Off-main capture under a wall-clock budget. Returns nil when `timeout`
    /// elapses first — the caller treats that as `unavailable`.
    ///
    /// The synchronous read cannot be interrupted mid-`data(forType:)`, so on
    /// expiry the detached read is *abandoned*, not cancelled: it finishes on
    /// its own later and its result is dropped (the `PasteboardReader` actor
    /// serializes it against any later capture). This is what keeps the pill
    /// animating and Esc working while Photoshop renders a 40 MB TIFF.
    static func capture(pasteboardNamed name: String, timeout: TimeInterval) async -> PasteboardSnapshot? {
        await withCheckedContinuation { (continuation: CheckedContinuation<PasteboardSnapshot?, Never>) in
            let gate = ResumeGate(continuation)
            Task.detached(priority: .userInitiated) {
                let snapshot = await PasteboardReader.shared.capture(pasteboardNamed: name)
                gate.resume(with: snapshot)
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                gate.resume(with: nil)
            }
        }
    }

    /// Resumes a continuation exactly once, from whichever of the two racing
    /// tasks gets there first.
    private final class ResumeGate: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)
        private let continuation: CheckedContinuation<PasteboardSnapshot?, Never>

        init(_ continuation: CheckedContinuation<PasteboardSnapshot?, Never>) {
            self.continuation = continuation
        }

        func resume(with value: PasteboardSnapshot?) {
            let first = lock.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            if first { continuation.resume(returning: value) }
        }
    }

    /// Puts the captured contents back, replacing whatever is there now. The
    /// caller (`TextInserter`) must have asked `PasteboardPolicy.shouldRestore`
    /// first — this method does not re-check ownership, only the cap.
    ///
    /// An empty snapshot restores an empty pasteboard: "the clipboard was
    /// empty before" is a real state, and leaving our dictated text behind
    /// would be a different clipboard than the one the user had.
    @discardableResult
    func restore(to pasteboard: NSPasteboard) -> Bool {
        guard !exceededCap else { return false }
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        let rebuilt: [NSPasteboardItem] = items.map { payloads in
            let item = NSPasteboardItem()
            for payload in payloads {
                item.setData(payload.data, forType: NSPasteboard.PasteboardType(payload.type))
            }
            return item
        }
        return pasteboard.writeObjects(rebuilt)
    }
}

/// The one serial executor for pasteboard READS that leave the main actor.
/// AppKit does not promise `NSPasteboard` thread safety, so every off-main read
/// is confined here (what clipboard managers do in practice), and every WRITE
/// (`clearContents` / `writeObjects`) stays on the main actor in
/// `TextInserter`. The pasteboard is re-resolved by name inside the actor
/// because `NSPasteboard` is not `Sendable`; `NSPasteboard(name:)` returns the
/// same underlying pasteboard.
actor PasteboardReader {
    static let shared = PasteboardReader()

    func capture(pasteboardNamed name: String) -> PasteboardSnapshot {
        PasteboardSnapshot.capture(from: NSPasteboard(name: NSPasteboard.Name(name)))
    }
}
