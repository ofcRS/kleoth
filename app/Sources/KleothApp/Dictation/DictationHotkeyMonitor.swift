import AppKit
import Foundation
import KleothCore
import os

/// Watches the fn+shift chord system-wide and turns it into
/// `DictationHotkeyEvent`s for `DictationController` (design §3.14 / §5.1).
///
/// Two `NSEvent` monitors — global (other apps) + local (Kleoth's own windows) —
/// feed a pure `DictationChordMachine`, which owns every timing decision. The
/// monitor itself only decides two things AppKit-level:
///
/// 1. **What "the chord" is.** The five real modifiers must equal *exactly*
///    `[.function, .shift]`, so fn+shift+⌘ / +⌥ / +⌃ are somebody else's
///    shortcut and never arm the mic (a superset test would start a capture on
///    every fn+shift+⌘, and a bare hold of it would have become a dictation).
/// 2. **Escape.** Only while the controller sets `escapeCancels`.
///
/// Why not a `CGEventTap`: the system "Press 🌐 key to" action is dispatched at
/// the IOHID level, so no tap placement could suppress it anyway, and a tap
/// needs Input Monitoring — a second TCC grant on top of the Accessibility one
/// the ⌘V post already requires. `NSEvent` key monitoring needs exactly
/// `AXIsProcessTrusted()`, and it is never in the synchronous input path.
///
/// Monitors installed while untrusted silently never fire, so `start()` refuses
/// to install any and a 30 s health timer tears them down if trust is revoked
/// (e.g. the bundle was replaced by a rebuild).
///
/// `stop()` (not `deinit`, which cannot hop to the main actor) is what removes
/// the `NSEvent` monitors; the controller calls it from `shutdown()`.
@MainActor
final class DictationHotkeyMonitor: DictationHotkeyMonitoring {
    /// The chord itself.
    static let chord: NSEvent.ModifierFlags = [.function, .shift]
    /// The modifiers that participate in the exact-match test (caps lock /
    /// numeric pad / help deliberately excluded — they are not shortcut keys).
    static let relevantModifiers: NSEvent.ModifierFlags = [.function, .shift, .command, .option, .control]
    private static let escapeKeyCode: UInt16 = 53
    /// Trust can go stale (bundle replaced, grant revoked) with no notification API.
    private static let healthInterval: TimeInterval = 30

    /// `log stream --predicate 'subsystem == "dev.kleoth" AND category == "DictationHotkey"'`
    /// is the hotkey probe — every chord transition and every emitted event lands here.
    private let log = Logger(subsystem: "dev.kleoth", category: "DictationHotkey")

    let events: AsyncStream<DictationHotkeyEvent>
    private let continuation: AsyncStream<DictationHotkeyEvent>.Continuation

    private var machine = DictationChordMachine()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var deadlineTask: Task<Void, Never>?
    private var healthTimer: Timer?
    /// Decides chord-down / chord-up edges from each `.flagsChanged` snapshot
    /// (debounce, exact match, and the "third modifier released off a
    /// superset" suppression) — pure and tested in KleothCore.
    private var edges = ChordEdgeDetector(chord: DictationHotkeyMonitor.chord)

    private(set) var isRunning = false
    var escapeCancels = false
    var onTrustLost: (() -> Void)?

    init() {
        (events, continuation) = AsyncStream.makeStream(
            of: DictationHotkeyEvent.self,
            bufferingPolicy: .bufferingNewest(16)
        )
    }

    // MARK: Lifecycle

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard AccessibilityPermission.isTrusted else {
            log.notice("start refused: not trusted for Accessibility")
            return false
        }

        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            // AppKit delivers these on the main run loop; assume, never hop —
            // a `Task` per event would reorder key-down/key-up.
            MainActor.assumeIsolated { self?.ingest(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.ingest(event) }
            return event   // never swallow: the host app keeps its keystrokes
        }

        // A fresh machine: a `stop()` mid-chord leaves the old one blocked
        // until a release it will now never see.
        machine = DictationChordMachine()
        edges.reset()
        isRunning = true
        startHealthTimer()
        log.notice("hotkey monitors installed (\(DictationDefaults.hotkeyDescription, privacy: .public))")
        return true
    }

    /// Removes the monitors and cancels the deadline task. Deliberately does
    /// NOT finish the `events` stream: a Settings off→on cycle calls `start()`
    /// again on the same instance, and the controller ends consumption by
    /// cancelling its own iterating task.
    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        healthTimer?.invalidate()
        healthTimer = nil
        edges.reset()
        isRunning = false
        // Cancel anything the machine still thinks is capturing so the
        // controller tears the session down.
        emit(machine.handle(.abort, at: Self.now()))
        log.notice("hotkey monitors removed")
    }

    func abort() {
        emit(machine.handle(.abort, at: Self.now()))
    }

    // MARK: Event ingestion

    private func ingest(_ event: NSEvent) {
        let now = Self.now()
        switch event.type {
        case .flagsChanged:
            // Derive from THIS event's flags, never from keyCode: order-independent
            // (fn-then-shift or shift-then-fn) and symmetric on release. The
            // exact match means adding ⌘/⌥/⌃ mid-hold reads as a chord *up* —
            // NOT the same as `.otherKey`: from `holding` the machine commits
            // (`.ended`, §8.2 #7b by design), from `pressed` it discards the
            // tap. Releasing that third modifier off fn+shift+⌘ is suppressed
            // by the detector: fn+shift never moved, so it must not arm.
            let relevant = event.modifierFlags.intersection(Self.relevantModifiers)
            guard let signal = edges.ingest(relevant) else { return }   // debounce + suppression
            log.debug("chord \(signal == .chordDown ? "down" : "up", privacy: .public) flags=\(relevant.rawValue, privacy: .public) t=\(now, privacy: .public)")
            emit(machine.handle(signal, at: now))
        case .keyDown:
            if edges.chordIsDown {
                // Only the FACT of a keypress matters: fn+shift+arrow is a real
                // system shortcut (shift+PageUp/Home) — yield to it.
                log.debug("otherKey while chord held keyCode=\(event.keyCode, privacy: .public)")
                emit(machine.handle(.otherKey, at: now))
            } else if escapeCancels, event.keyCode == Self.escapeKeyCode {
                log.debug("escape while session active")
                continuation.yield(.escapePressed)
            }
        default:
            break
        }
    }

    private func emit(_ produced: [DictationHotkeyEvent]) {
        for event in produced {
            log.debug("event \(String(describing: event), privacy: .public)")
            continuation.yield(event)
        }
        rescheduleDeadline()
    }

    /// Exactly one pending timer, always the one the machine last asked for.
    private func rescheduleDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let deadline = machine.deadline else { return }
        let delay = max(0, deadline - Self.now())
        deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.emit(self.machine.handle(.deadline, at: Self.now()))
        }
    }

    // MARK: Health

    private func startHealthTimer() {
        healthTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.healthInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, !AccessibilityPermission.isTrusted else { return }
                self.log.notice("Accessibility trust lost — removing monitors")
                self.stop()
                // The controller mirrors `isRunning` into its published flags
                // only on `refreshTrust()`; tell it now so the popover's
                // "needs access" line appears without waiting for activation.
                self.onTrustLost?()
            }
        }
        healthTimer = timer
        // Keep firing while a menu tracks or a window is dragged.
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Plumbing

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
