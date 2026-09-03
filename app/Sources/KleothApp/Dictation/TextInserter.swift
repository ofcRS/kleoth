import AppKit
// `kVK_ANSI_V` is a Carbon symbol (HIToolbox), not AppKit.
import Carbon.HIToolbox
import CoreGraphics
import KleothCore
import os

/// Pastes dictated text into whatever app has keyboard focus: snapshot the
/// pasteboard → write the text with nspasteboard.org transient markers →
/// synthesize ⌘V → put the user's clipboard back 0.5 s later, but only if they
/// have not copied anything in the meantime (design §3.20 / §5.5).
///
/// ⚠️ ENTITLEMENTS DEPENDENCY: `CGEvent.post` is blocked under the App Sandbox
/// and there is no entitlement that re-enables it. `app/bundle/Kleoth.entitlements`
/// must therefore stay un-sandboxed (it already is, for the Core Audio process
/// tap) — adding `com.apple.security.app-sandbox` there silently breaks every
/// paste on this path. Accessibility trust (`AXIsProcessTrusted`) is the other
/// hard requirement, and it is bound to the code signature: use the stable
/// "Kleoth Self-Signed" identity so the grant survives a rebuild.
///
/// This type never calls `NSApp.activate`: the paste goes to the app the user
/// chose, and stealing focus back seconds later would be worse than any
/// mis-targeted paste.
@MainActor
final class TextInserter: TextInserting {
    static let shared = TextInserter()

    /// NX_DEVICELCMDKEYMASK — the side-specific "left ⌘ is physically down"
    /// bit. Some apps (Electron/Chromium-based ones in particular) check the
    /// device bits and ignore a ⌘V that only carries `maskCommand`.
    private static let deviceLeftCommandBit: UInt64 = 0x8

    /// Modifiers that would corrupt the synthetic ⌘V if still physically held
    /// (a held fn+shift turns it into ⌘⇧V). Caps Lock is deliberately absent —
    /// it is a latch, not a chord, and waiting for it would always time out.
    private static let blockingModifiers: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn,
    ]

    /// Never wait longer than this for the user's fingers to leave the chord;
    /// after that we post anyway (a wrong-modifier paste is recoverable from
    /// History, a dropped dictation is not). §5.5 fixes both numbers.
    private static let modifierWaitTimeout: TimeInterval = 0.4
    private static let modifierPollInterval: Duration = .milliseconds(15)

    private let pasteboard: NSPasteboard
    private let log = Logger(subsystem: "dev.kleoth", category: "TextInserter")

    /// The user's clipboard, held while a restore is pending. A second
    /// dictation that starts inside the 0.5 s window inherits THIS snapshot
    /// (the user's data) instead of capturing our own just-pasted text.
    private var pendingSnapshot: PasteboardSnapshot?
    private var restoreTask: Task<Void, Never>?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    // MARK: TextInserting

    @discardableResult
    func insert(_ text: String, pressTimeTarget: DictationTarget) async throws -> DictationTarget {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextInsertionError.emptyText
        }

        // Whoever is frontmost NOW gets the keystroke — we never activate
        // ourselves or the press-time app.
        let target = DictationTarget.frontmost()
        if target != pressTimeTarget {
            log.info(
                "Focus moved between chord-down and paste: \(pressTimeTarget.bundleIdentifier ?? "unknown", privacy: .public) → \(target.bundleIdentifier ?? "unknown", privacy: .public)"
            )
        }

        // Both refusal paths leave the text on the clipboard UNMARKED so the
        // user can paste it by hand and their clipboard manager keeps it.
        guard InsertionEnvironment.isAccessibilityTrusted else {
            log.error("Accessibility trust missing at paste time — leaving text on the clipboard.")
            writeUnmarked(text)
            throw TextInsertionError.accessibilityNotTrusted
        }
        guard !InsertionEnvironment.isSecureInputActive else {
            log.error("Secure input active at paste time — leaving text on the clipboard.")
            writeUnmarked(text)
            throw TextInsertionError.secureInputActive
        }

        // The snapshot is read off the main actor under a wall-clock budget:
        // reading a foreign item's flavors makes the owning app materialize
        // them (seconds for a layered image, unbounded for a beachballing
        // owner). A timeout means "no snapshot to restore" — the text simply
        // stays on the clipboard, which is the safe outcome.
        let snapshot: PasteboardSnapshot
        if let pending = pendingSnapshot {
            snapshot = pending
        } else if let captured = await PasteboardSnapshot.capture(
            pasteboardNamed: pasteboard.name.rawValue,
            timeout: PasteboardPolicy.captureTimeout
        ) {
            snapshot = captured
        } else {
            log.notice("Clipboard snapshot timed out after \(PasteboardPolicy.captureTimeout, privacy: .public) s — not restoring.")
            snapshot = .unavailable
        }
        cancelPendingRestore()

        let owned = writeMarked(text)
        await waitForPhysicalModifiersToClear()

        do {
            try postPasteKeystroke()
        } catch {
            // Nothing was pasted: drop the markers so the text survives in the
            // clipboard manager, and schedule no restore (which would delete it).
            writeUnmarked(text)
            pendingSnapshot = nil
            throw error
        }

        scheduleRestore(snapshot, ownedChangeCount: owned)
        // No attempt to verify the paste landed: `changeCount` is a read that
        // proves nothing, and diffing the target app's text via AX would mean
        // reading other apps' contents. The recovery net is the log + History → Copy.
        return target
    }

    // MARK: Pasteboard writes

    /// Writes the dictated text with the transient markers and returns the
    /// change count we own afterwards.
    ///
    /// (§5.5 describes taking `clearContents()`'s return value; we read
    /// `changeCount` back after the write instead, so the owned value is
    /// correct even if a future AppKit bumps the counter on `writeObjects`.)
    @discardableResult
    private func writeMarked(_ text: String) -> Int {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: .transient)
        item.setString("", forType: .autoGenerated)
        item.setString(Self.sourceIdentifier, forType: .nsPasteboardSource)
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    /// Refusal path: the text is the user's only copy of what they said, so it
    /// goes on the clipboard plainly — no transient markers, no restore.
    private func writeUnmarked(_ text: String) {
        cancelPendingRestore()
        pendingSnapshot = nil
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(Self.sourceIdentifier, forType: .nsPasteboardSource)
        pasteboard.writeObjects([item])
    }

    private static var sourceIdentifier: String {
        Bundle.main.bundleIdentifier ?? "dev.kleoth.app"
    }

    // MARK: Restore

    private func scheduleRestore(_ snapshot: PasteboardSnapshot, ownedChangeCount owned: Int) {
        guard !snapshot.exceededCap else {
            // Oversized clipboard: we hold nothing, so there is nothing to put
            // back. The dictated text simply stays on the clipboard.
            log.info("Clipboard exceeded the snapshot cap — not restoring.")
            pendingSnapshot = nil
            return
        }
        pendingSnapshot = snapshot
        restoreTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DictationDefaults.pasteboardRestoreDelay))
            guard !Task.isCancelled else { return }
            self?.performRestore(snapshot, ownedChangeCount: owned)
        }
    }

    private func performRestore(_ snapshot: PasteboardSnapshot, ownedChangeCount owned: Int) {
        restoreTask = nil
        pendingSnapshot = nil
        guard PasteboardPolicy.shouldRestore(
            ownedChangeCount: owned,
            currentChangeCount: pasteboard.changeCount,
            exceededCap: snapshot.exceededCap
        ) else {
            log.debug("Clipboard changed since our paste — leaving the newer contents alone.")
            return
        }
        snapshot.restore(to: pasteboard)
    }

    private func cancelPendingRestore() {
        restoreTask?.cancel()
        restoreTask = nil
        pendingSnapshot = nil
    }

    // MARK: Keystroke

    /// Polls the physical modifier state until the user's fingers are off the
    /// chord, or `modifierWaitTimeout` elapses.
    private func waitForPhysicalModifiersToClear() async {
        let deadline = Date().addingTimeInterval(Self.modifierWaitTimeout)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(Self.blockingModifiers).isEmpty { return }
            do {
                try await Task.sleep(for: Self.modifierPollInterval)
            } catch {
                return  // cancelled — post immediately rather than spin
            }
        }
        log.debug("Modifiers still held after \(Self.modifierWaitTimeout, privacy: .public) s — posting ⌘V anyway.")
    }

    private func postPasteKeystroke() throws(TextInsertionError) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw .eventCreationFailed
        }
        // `.permitLocalKeyboardEvents` is REQUIRED: without it the user's own
        // keystrokes are filtered for the default 0.25 s suppression interval
        // after our synthetic ⌘V, i.e. the first characters they type right
        // after a dictation vanish.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | Self.deviceLeftCommandBit)
        // Physical key position 9. Correct under RU/HE/AR (the ⌘ layer switches
        // to Latin — Apple DTS 729242) and the "… ⌘" Dvorak/bépo variants;
        // WRONG for plain Dvorak/Colemak (documented v1 limit — the fix is a
        // UCKeyTranslate reverse lookup, as Clipy/Sauce do).
        let key = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else {
            throw .eventCreationFailed
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
