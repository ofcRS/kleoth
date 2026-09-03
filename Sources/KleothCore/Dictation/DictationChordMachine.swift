import Foundation

/// What the platform monitor observed. Timestamps are supplied by the caller
/// (monotonic `ProcessInfo.processInfo.systemUptime`), so the machine is a pure
/// function of (state, signal, now).
public enum ChordSignal: Sendable, Equatable {
    /// fn AND shift are both held (order-independent).
    case chordDown
    /// Either was released.
    case chordUp
    /// A non-modifier key went down while the chord was held.
    case otherKey
    /// The timer the machine asked for (`deadline`) elapsed.
    case deadline
    /// External cancel: Esc, capture failure, feature disabled.
    case abort
}

public enum DictationHotkeyEvent: Sendable, Equatable {
    /// Chord went down. Start the mic now; show NO UI (may be a discarded tap).
    case armed
    /// Push-to-talk confirmed (held ≥ minHold). Show the pill.
    case began
    /// Push-to-talk released after a real hold → transcribe + insert.
    case ended
    /// Double-tap: hands-free session started (a fresh capture; `armed` precedes it).
    case toggledOn
    /// Tap while hands-free → stop and transcribe + insert.
    case toggledOff
    /// Discard whatever was captured; never show (or hide) the pill.
    case cancelled(CancelReason)
    /// Emitted by the MONITOR (never by the machine) when Escape is pressed
    /// while `escapeCancels` is set. The controller cancels the live session.
    case escapePressed

    public enum CancelReason: Sendable, Equatable {
        /// Released under `minHold`; may still become a double-tap.
        case tooShort
        /// The user was typing a real fn+shift shortcut.
        case otherKey
        /// `abort()`.
        case external
    }
}

/// The pure fn+shift chord state machine (design §3.2 / §5.1). It owns all
/// dictation hotkey *timing* — the platform monitor only translates NSEvents
/// into `ChordSignal`s, feeds them in with a monotonic timestamp, and schedules
/// one timer for whatever `deadline` says.
///
/// Deliberately free of AppKit so it lives in KleothCore, where the transition
/// table (§5.1) is asserted by tests rather than by hand-testing a hotkey.
public struct DictationChordMachine: Sendable {
    public struct Config: Sendable {
        public var minHold: TimeInterval
        public var doubleTapWindow: TimeInterval

        public init(
            minHold: TimeInterval = DictationDefaults.minHold,
            doubleTapWindow: TimeInterval = DictationDefaults.doubleTapWindow
        ) {
            self.minHold = minHold
            self.doubleTapWindow = doubleTapWindow
        }

        public static let `default` = Config()
    }

    /// Internal state; the transition table in §5.1 is written in these terms.
    private enum State: Sendable, Equatable {
        /// Nothing held, nothing pending.
        case idle
        /// Chord down, still under `minHold` — may become a hold or a tap.
        case pressed(since: TimeInterval)
        /// Chord down past `minHold` — a confirmed push-to-talk.
        case holding
        /// A cancelled chord whose keys are still down; swallow until release.
        case blocked
        /// A tap just happened; a second chord-down before `until` is a double-tap.
        case tapWindow(until: TimeInterval)
        /// Hands-free started, the second tap's keys are still down.
        case handsFreeArming
        /// Hands-free listening; the user may type freely.
        case handsFree
        /// The ending tap's keys are still down.
        case handsFreeEnding
    }

    private let config: Config
    private var state: State = .idle

    public init(config: Config = .default) {
        self.config = config
        self.deadline = nil
    }

    /// When the caller must feed `.deadline` (absolute uptime), or nil.
    /// Recomputed after every `handle`; the monitor keeps exactly one timer Task.
    public private(set) var deadline: TimeInterval?

    /// True in pressed/holding/handsFreeArming/handsFree/handsFreeEnding —
    /// i.e. "the mic should be on".
    public var isCapturing: Bool {
        switch state {
        case .pressed, .holding, .handsFreeArming, .handsFree, .handsFreeEnding:
            return true
        case .idle, .blocked, .tapWindow:
            return false
        }
    }

    /// Applies one signal and returns the events to deliver, in order.
    public mutating func handle(_ signal: ChordSignal, at now: TimeInterval) -> [DictationHotkeyEvent] {
        let events = transition(signal, at: now)
        deadline = Self.deadline(for: state, config: config)
        return events
    }

    private mutating func transition(
        _ signal: ChordSignal,
        at now: TimeInterval
    ) -> [DictationHotkeyEvent] {
        // `abort` is state-independent: it cancels whatever is capturing and then
        // swallows the physical release, so a half-held chord can't resume.
        if case .abort = signal {
            if isCapturing {
                state = .blocked
                return [.cancelled(.external)]
            }
            // Non-capturing: stay blocked while the (cancelled) chord is still
            // down, otherwise settle in idle.
            if case .blocked = state {
                state = .blocked
            } else {
                state = .idle
            }
            return []
        }

        switch (state, signal) {
        case (.idle, .chordDown):
            state = .pressed(since: now)
            return [.armed]

        case (.pressed, .deadline):
            state = .holding
            return [.began]

        case (.pressed(let since), .chordUp):
            if now - since >= config.minHold {
                // The timer was missed (a busy main run loop) but the hold was
                // real — emit both events so the session still completes.
                state = .idle
                return [.began, .ended]
            }
            state = .tapWindow(until: now + config.doubleTapWindow)
            return [.cancelled(.tooShort)]

        case (.pressed, .otherKey):
            state = .blocked
            return [.cancelled(.otherKey)]

        case (.holding, .chordUp):
            state = .idle
            return [.ended]

        case (.holding, .otherKey):
            state = .blocked
            return [.cancelled(.otherKey)]

        case (.blocked, .chordUp):
            state = .idle
            return []

        case (.tapWindow, .chordDown):
            state = .handsFreeArming
            return [.armed, .toggledOn]

        case (.tapWindow, .deadline):
            state = .idle
            return []

        case (.handsFreeArming, .chordUp):
            state = .handsFree
            return []

        case (.handsFree, .chordDown):
            state = .handsFreeEnding
            return [.toggledOff]

        case (.handsFreeEnding, .chordUp):
            state = .idle
            return []

        default:
            // Everything else — a repeated chordDown, a stray key while
            // hands-free (the user is allowed to type), a late deadline — is a
            // no-op that leaves the state untouched.
            return []
        }
    }

    private static func deadline(for state: State, config: Config) -> TimeInterval? {
        switch state {
        case .pressed(let since): return since + config.minHold
        case .tapWindow(let until): return until
        case .idle, .holding, .blocked, .handsFreeArming, .handsFree, .handsFreeEnding: return nil
        }
    }
}
