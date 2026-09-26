import Foundation

/// Call detection as a pure machine (design §3.2, §4.1) — the
/// `ScreenRecordingSessionMachine` idiom: `handle` is total, never traps, and
/// its effects are the host's only instructions. Time comes from the events.
///
/// A SESSION is one app holding the mic (keyed by its bundle id; a browser's
/// tabs are one session whose class only ever goes up). A gap shorter than
/// `releaseGrace` keeps it. Offers are made from sessions; answers silence a
/// session and cool a source's key down; the meeting links to one source for
/// the stop suggestion and remembers who held the mic longest for the context.
public struct MeetingDetector: Sendable {
    public struct Environment: Sendable, Equatable {
        public var offersEnabled: Bool
        public var ignoredKeys: Set<String>
        public var pillHidden: Bool
        public var screenRecording: Bool
        public var meetingSince: Date?

        public init(offersEnabled: Bool = false, ignoredKeys: Set<String> = [], pillHidden: Bool = false,
                    screenRecording: Bool = false, meetingSince: Date? = nil) {
            self.offersEnabled = offersEnabled; self.ignoredKeys = ignoredKeys; self.pillHidden = pillHidden
            self.screenRecording = screenRecording; self.meetingSince = meetingSince
        }

        var suppressesOffers: Bool { !offersEnabled || pillHidden || screenRecording || meetingSince != nil }
    }

    public struct Offer: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case start, stop }
        public let id: String
        public let kind: Kind
        public let source: MeetingSource
    }

    public enum Answer: Sendable, Equatable { case accepted, dismissed, never, displaced, refused }

    public enum Event: Sendable {
        /// Everything holding the mic now (Kleoth excluded).
        case observed(Set<MeetingSource>, at: Date)
        case environment(Environment, at: Date)
        case answered(offerId: String, Answer, at: Date)
        case tick(at: Date, pointerOnPill: Bool)
    }

    public enum Effect: Sendable, Equatable {
        case show(Offer)
        case withdraw(offerId: String)
        /// The host persists "never" for this key.
        case ignore(key: String, name: String)
    }

    private struct Session: Sendable {
        var source: MeetingSource
        let startedAt: Date
        var releasedAt: Date?
        var offered = false
        var silenced = false

        /// The order every choice among sessions uses: class first, then the
        /// earlier session, then the key (and the app, when two browsers show
        /// the same site) — never Set/Dictionary iteration order (review M-1).
        static func precedes(_ a: Session, _ b: Session) -> Bool {
            (a.source.sourceClass.rank, a.startedAt, a.source.key, a.source.appBundleId)
                < (b.source.sourceClass.rank, b.startedAt, b.source.key, b.source.appBundleId)
        }

        /// A browser that has not named its call's site yet: `browser:` can
        /// still become `webcall:` or `site:`, and `webcall:` can become
        /// `site:` (`MeetingSource.make`). An app's key and a site's never change.
        var canStillChangeKey: Bool {
            (source.sourceClass == .browser || source.sourceClass == .browserCall) && source.windowTitle == nil
        }
    }

    private struct Visible: Sendable {
        var offer: Offer
        var deadline: Date
        var hoverHeld = false
    }

    private var environment = Environment()
    /// Keyed by `appBundleId`.
    private var sessions: [String: Session] = [:]
    /// Source key → no offer before this instant (✕ / expiry cooldown).
    private var dismissedUntil: [String: Date] = [:]
    private var visible: Visible?
    private var retryAt: Date?
    private var offerCounter = 0
    /// An accepted start offer's app, linked when the meeting actually starts.
    private var pendingAcceptedApp: String?
    private var linked: MeetingSource?
    private var linkedReleasedAt: Date?
    private var stopOfferedForRelease: Date?
    /// Mic seconds per app during the current meeting (valid until the next one starts).
    private var meetingSeconds: [String: (source: MeetingSource, seconds: Double)] = [:]
    private var lastObservedAt: Date?

    public init() {}

    public var visibleOffer: Offer? { visible?.offer }
    public var linkedSource: MeetingSource? { linked }

    // MARK: - Events

    public mutating func handle(_ event: Event) -> [Effect] {
        var effects: [Effect] = []
        switch event {
        case .observed(let sources, let now):
            accrueMeetingSeconds(until: now)
            lastObservedAt = now
            let seen = Set(sources.map(\.appBundleId))
            for source in sources {
                let app = source.appBundleId
                if app == linked?.appBundleId, linkedReleasedAt != nil {
                    // The linked source is back (its session may have expired): a pending stop suggestion is moot.
                    linkedReleasedAt = nil
                    stopOfferedForRelease = nil
                    effects += withdrawVisible(kind: .stop)
                }
                if var session = sessions[app] {
                    session.releasedAt = nil
                    if source.sourceClass.rank < session.source.sourceClass.rank
                        || (source.sourceClass == session.source.sourceClass && source.windowTitle != nil && session.source.windowTitle == nil) {
                        session.source = source   // the class only ever goes up
                    }
                    sessions[app] = session
                } else {
                    sessions[app] = Session(source: source, startedAt: now)
                }
                if environment.meetingSince != nil, meetingSeconds[app] == nil { meetingSeconds[app] = (source, 0) }
            }
            if environment.meetingSince != nil, linked == nil {
                // The first holder(s) seen during a meeting: link the best of the batch.
                linked = sources.compactMap { sessions[$0.appBundleId] }.min(by: Session.precedes)?.source
                linkedReleasedAt = nil
            }
            for (app, var session) in sessions where !seen.contains(app) && session.releasedAt == nil {
                session.releasedAt = now
                sessions[app] = session
                if app == linked?.appBundleId, linkedReleasedAt == nil { linkedReleasedAt = now }
            }
            effects += expireSessions(at: now)
            effects += evaluate(at: now)

        case .environment(let next, let now):
            let previous = environment
            // The ending (or replaced) meeting accrues its last stretch while
            // `environment` still says it runs — `accrueMeetingSeconds` guards on it.
            if previous.meetingSince != nil, next.meetingSince != previous.meetingSince {
                accrueMeetingSeconds(until: now)
            }
            environment = next
            if next.meetingSince != previous.meetingSince {
                if next.meetingSince != nil {
                    // A new meeting: fresh context, link the accepted offer's app or the best holder.
                    meetingSeconds = [:]
                    for session in sessions.values where session.releasedAt == nil {
                        meetingSeconds[session.source.appBundleId] = (session.source, 0)
                    }
                    let held = sessions.values.filter { $0.releasedAt == nil }
                    if let app = pendingAcceptedApp, let session = sessions[app] {
                        linked = session.source
                    } else {
                        linked = held.min(by: Session.precedes)?.source
                    }
                    pendingAcceptedApp = nil
                    linkedReleasedAt = nil
                    stopOfferedForRelease = nil
                    // Its mic seconds count from now, not from the last
                    // observation before it (up to one poll over-credited).
                    if lastObservedAt != nil { lastObservedAt = now }
                    effects += withdrawVisible(kind: .start)
                    // Straight from another meeting (no nil in between): that
                    // meeting's "stop recording?" must not stop this one (review M-3).
                    effects += withdrawVisible(kind: .stop)
                } else {
                    effects += withdrawVisible(kind: .stop)
                    // The user recorded the calls held during the meeting: no
                    // "record it?" for them now it ends ("the user evidently
                    // chose", §3.2.3; review M-4). A new session of the app is offered.
                    for app in meetingSeconds.keys { sessions[app]?.silenced = true }
                    linked = nil
                    linkedReleasedAt = nil
                    stopOfferedForRelease = nil
                }
            }
            effects += expireSessions(at: now)
            effects += evaluate(at: now)

        case .answered(let offerId, let answer, let now):
            guard let current = visible, current.offer.id == offerId else { return [] }
            visible = nil
            let app = current.offer.source.appBundleId
            let key = current.offer.source.key
            switch (current.offer.kind, answer) {
            case (.start, .accepted):
                pendingAcceptedApp = app
                sessions[app]?.silenced = true
                // The meeting it starts reaches the machine a turn later (the
                // host's environment hop): no next offer in the same breath
                // (Task 14 review M3).
                retryAt = now.addingTimeInterval(MeetingDetectionDefaults.busyRetry)
            case (.start, .dismissed):
                sessions[app]?.silenced = true
                dismissedUntil[key] = now.addingTimeInterval(MeetingDetectionDefaults.dismissCooldown)
            case (.start, .never):
                effects.append(.ignore(key: key, name: current.offer.source.name))
                environment.ignoredKeys.insert(key)
                sessions[app]?.silenced = true
            case (.start, .displaced):
                sessions[app]?.offered = false
                retryAt = now.addingTimeInterval(MeetingDetectionDefaults.busyRetry)
            case (.start, .refused):
                sessions[app]?.offered = false
                retryAt = now.addingTimeInterval(MeetingDetectionDefaults.busyRetry)
            case (.stop, .accepted), (.stop, .dismissed), (.stop, .never):
                break   // once per release: `stopOfferedForRelease` stays
            case (.stop, .displaced):
                stopOfferedForRelease = nil
            case (.stop, .refused):
                stopOfferedForRelease = nil
                retryAt = now.addingTimeInterval(MeetingDetectionDefaults.busyRetry)
            }
            effects += evaluate(at: now)

        case .tick(let now, let pointerOnPill):
            if var current = visible {
                if pointerOnPill {
                    // Held while hovered — with a deadline ahead, never one
                    // already passed (the host re-arms on it: review C-1).
                    current.hoverHeld = true
                    current.deadline = max(current.deadline, now.addingTimeInterval(MeetingDetectionDefaults.hoverLinger))
                } else if current.hoverHeld {
                    current.hoverHeld = false
                    current.deadline = max(current.deadline, now.addingTimeInterval(MeetingDetectionDefaults.hoverLinger))
                }
                if !pointerOnPill, now >= current.deadline {
                    visible = nil
                    effects.append(.withdraw(offerId: current.offer.id))
                    if current.offer.kind == .start {
                        sessions[current.offer.source.appBundleId]?.silenced = true
                        dismissedUntil[current.offer.source.key] = now.addingTimeInterval(MeetingDetectionDefaults.dismissCooldown)
                    }
                } else {
                    visible = current
                }
            }
            effects += expireSessions(at: now)
            effects += evaluate(at: now)
        }
        return effects
    }

    // MARK: - Queries

    /// When the host must send the next `.tick`: the earliest of a visible
    /// offer's deadline, a busy retry, a held session's dwell (no earlier than
    /// its cooldown or the retry; none while an offer is up or once the session
    /// is too old to offer), a released session's grace, the linked release's
    /// stop grace (detection on, no screen recording). Nil when nothing is
    /// pending. After a `.tick` at `now` it is never `<= now` — the host
    /// re-arms on it, so a past instant would be a hot loop
    /// (`MeetingDetectorDeadlineTests`).
    public var nextDeadline: Date? {
        var candidates: [Date] = []
        if let visible { candidates.append(visible.deadline) }
        if let retryAt { candidates.append(retryAt) }
        for session in sessions.values {
            if let releasedAt = session.releasedAt {
                candidates.append(releasedAt.addingTimeInterval(MeetingDetectionDefaults.releaseGrace))
            } else if visible == nil, !session.offered, !session.silenced, !environment.suppressesOffers,
                      !environment.ignoredKeys.contains(session.source.key) {
                // The first instant `evaluate` could offer it — never earlier
                // than what blocks it (a cooldown, a busy retry), and never
                // for a session that will be too old by then.
                var due = session.startedAt.addingTimeInterval(session.source.sourceClass.dwell)
                if let until = dismissedUntil[session.source.key] { due = max(due, until) }
                if let retryAt { due = max(due, retryAt) }
                if due <= session.startedAt.addingTimeInterval(MeetingDetectionDefaults.maxOfferAge) {
                    candidates.append(due)
                }
            }
        }
        // Gated exactly as `evaluate` gates the suggestion, or detection-off
        // would leave a past stop-grace deadline here (a hot loop in the host).
        if environment.meetingSince != nil, environment.offersEnabled, !environment.screenRecording,
           let releasedAt = linkedReleasedAt, stopOfferedForRelease != releasedAt {
            candidates.append(max(releasedAt.addingTimeInterval(MeetingDetectionDefaults.stopGrace), retryAt ?? .distantPast))
        }
        return candidates.min()
    }

    /// A session that could still be offered: held, not offered yet (or
    /// offered and displaced / refused), not silenced, no older than
    /// `maxOfferAge` — with offers enabled — and not "never", unless it is a
    /// browser that can still move to a key the user never refused ("Never
    /// for Chrome", then a tab joins a call: `webcall:` / `site:`). A
    /// suppression, a cooldown or a busy retry does not count against it:
    /// those lift while it is still young. The host keeps re-reading titles
    /// and web-call assertions only while this holds (or a meeting records),
    /// so its class can still go up before the offer; an app holding the mic
    /// all day stops that after `maxOfferAge`. False → true only through
    /// `handle`; with time, only true → false.
    public func hasOfferableSession(at now: Date) -> Bool {
        guard environment.offersEnabled else { return false }
        return sessions.values.contains { session in
            session.releasedAt == nil && !session.offered && !session.silenced
                && now.timeIntervalSince(session.startedAt) <= MeetingDetectionDefaults.maxOfferAge
                && (!environment.ignoredKeys.contains(session.source.key) || session.canStillChangeKey)
        }
    }

    /// The meeting's primary source: the longest holder ≥ `minContextSeconds`,
    /// else the linked one — with its seconds, counted to `now`.
    public func meetingSource(at now: Date) -> (source: MeetingSource, micSeconds: Double)? {
        var totals = meetingSeconds
        if environment.meetingSince != nil, let last = lastObservedAt, now > last {
            for session in sessions.values where session.releasedAt == nil {
                let app = session.source.appBundleId
                totals[app] = (session.source, (totals[app]?.seconds ?? 0) + now.timeIntervalSince(last))
            }
        }
        // The most seconds; a tie goes to the better class, then the key and
        // the app (never Dictionary order — review M-1).
        let best = totals.values.min { a, b in
            if a.seconds != b.seconds { return a.seconds > b.seconds }
            return (a.source.sourceClass.rank, a.source.key, a.source.appBundleId)
                < (b.source.sourceClass.rank, b.source.key, b.source.appBundleId)
        }
        if let best, best.seconds >= MeetingDetectionDefaults.minContextSeconds {
            return (best.source, best.seconds)
        }
        if let linked { return (linked, totals[linked.appBundleId]?.seconds ?? 0) }
        return nil
    }

    // MARK: - Internals

    private mutating func accrueMeetingSeconds(until now: Date) {
        guard environment.meetingSince != nil, let last = lastObservedAt, now > last else { return }
        let delta = now.timeIntervalSince(last)
        for session in sessions.values where session.releasedAt == nil {
            let app = session.source.appBundleId
            totalsAdd(app: app, source: session.source, delta)
        }
    }

    private mutating func totalsAdd(app: String, source: MeetingSource, _ delta: Double) {
        meetingSeconds[app] = (source, (meetingSeconds[app]?.seconds ?? 0) + delta)
    }

    /// Ends sessions released for `releaseGrace` or longer; withdraws a start
    /// offer whose source ended.
    private mutating func expireSessions(at now: Date) -> [Effect] {
        var effects: [Effect] = []
        for (app, session) in sessions {
            guard let releasedAt = session.releasedAt,
                  now.timeIntervalSince(releasedAt) >= MeetingDetectionDefaults.releaseGrace else { continue }
            sessions.removeValue(forKey: app)
            if let current = visible, current.offer.kind == .start, current.offer.source.appBundleId == app {
                visible = nil
                effects.append(.withdraw(offerId: current.offer.id))
            }
        }
        return effects
    }

    private mutating func withdrawVisible(kind: Offer.Kind) -> [Effect] {
        guard let current = visible, current.offer.kind == kind else { return [] }
        visible = nil
        if kind == .start { sessions[current.offer.source.appBundleId]?.offered = false }
        return [.withdraw(offerId: current.offer.id)]
    }

    private mutating func evaluate(at now: Date) -> [Effect] {
        var effects: [Effect] = []
        // A passed retry no longer blocks anything — drop it here, or a
        // suppressed / busy machine would report it as a past deadline forever.
        if let retry = retryAt, now >= retry { retryAt = nil }
        // A session older than `maxOfferAge` can never be offered again —
        // silence it, or its long-passed dwell stays a deadline for the rest of
        // the call once whatever blocked it lifts (review C-1).
        for (app, session) in sessions where !session.silenced
            && now.timeIntervalSince(session.startedAt) > MeetingDetectionDefaults.maxOfferAge {
            sessions[app]?.silenced = true
        }
        if environment.suppressesOffers {
            effects += withdrawVisible(kind: .start)
        } else if visible == nil, retryAt.map({ now >= $0 }) ?? true {
            retryAt = nil
            let due = sessions.values.filter { session in
                session.releasedAt == nil && !session.offered && !session.silenced
                    && now.timeIntervalSince(session.startedAt) >= session.source.sourceClass.dwell
                    && now.timeIntervalSince(session.startedAt) <= MeetingDetectionDefaults.maxOfferAge
                    && !environment.ignoredKeys.contains(session.source.key)
                    && (dismissedUntil[session.source.key] ?? .distantPast) <= now
            }
            if let best = due.min(by: Session.precedes) {
                offerCounter += 1
                let offer = Offer(id: "offer-\(offerCounter)", kind: .start, source: best.source)
                visible = Visible(offer: offer, deadline: now.addingTimeInterval(MeetingDetectionDefaults.offerLifetime))
                sessions[best.source.appBundleId]?.offered = true
                effects.append(.show(offer))
            }
        }
        // Detection off = no unasked prompts: a stop suggestion already up
        // goes too, and is not repeated for the same release (review M-2).
        if !environment.offersEnabled { effects += withdrawVisible(kind: .stop) }
        // The stop suggestion (§3.2.5) — only with call detection on (the
        // controller's ruling: detection off = no unasked prompts), and not
        // while a screen recording runs: the pill yields every prompt to the
        // screen bar, so it would be refused every second for the whole
        // recording (Task 14 review M1); it comes once that ends, if still
        // due. The relink runs either way: it keeps the meeting's context right.
        if environment.meetingSince != nil, let linkedNow = linked, let releasedAt = linkedReleasedAt {
            let otherCall = sessions.values.filter {
                $0.releasedAt == nil && $0.source.appBundleId != linkedNow.appBundleId
                    && ($0.source.sourceClass == .callApp || $0.source.sourceClass == .browserCall)
            }.min(by: Session.precedes)
            if let otherCall {
                linked = otherCall.source            // the call moved: relink silently
                linkedReleasedAt = nil
                stopOfferedForRelease = nil
                effects += withdrawVisible(kind: .stop)
            } else if environment.offersEnabled, !environment.screenRecording, visible == nil,
                      stopOfferedForRelease != releasedAt,
                      now.timeIntervalSince(releasedAt) >= MeetingDetectionDefaults.stopGrace,
                      retryAt.map({ now >= $0 }) ?? true {
                retryAt = nil
                offerCounter += 1
                let offer = Offer(id: "offer-\(offerCounter)", kind: .stop, source: linkedNow)
                visible = Visible(offer: offer, deadline: now.addingTimeInterval(MeetingDetectionDefaults.stopOfferLifetime))
                stopOfferedForRelease = releasedAt
                effects.append(.show(offer))
            }
        }
        return effects
    }
}
