import AppKit
import KleothCore

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

    /// Reads every item and type off `pasteboard`, skipping promise types and
    /// bailing out (with `exceededCap`) once the running total passes the cap.
    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        var items: [[Payload]] = []
        var total = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var payloads: [Payload] = []
            for type in item.types {
                guard PasteboardPolicy.shouldCapture(type: type.rawValue) else { continue }
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                guard PasteboardPolicy.withinCap(byteCount: total) else {
                    return PasteboardSnapshot(items: [], byteCount: total, exceededCap: true)
                }
                payloads.append(Payload(type: type.rawValue, data: data))
            }
            if !payloads.isEmpty {
                items.append(payloads)
            }
        }
        return PasteboardSnapshot(items: items, byteCount: total, exceededCap: false)
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
