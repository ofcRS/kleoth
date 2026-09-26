import AppKit
import Foundation
import KleothCore
import KleothPillUI
import os

/// The meeting side's face in front of the pill (meetings-in-the-pill design
/// §4.4): turns `MeetingCaptureEvent`s into pill phases and pill actions into
/// `RecordingController` calls. It knows nothing about who started the
/// meeting — the bar shows for every meeting (§3.1.3), the hot-mic rule.
///
/// Created once from `applicationDidFinishLaunching` (never on a `-KleothDemo`
/// launch, which has no `AppDelegate` and is gated here too).
@MainActor
final class MeetingPillBridge {
    private(set) static var shared: MeetingPillBridge?

    private let recording: RecordingController
    private let coordinator: PillCoordinator
    private let log = Logger(subsystem: "dev.kleoth", category: "MeetingPill")

    /// The 20 Hz `meetingLevels` → pill pump, alive only while a meeting records
    /// (`ScreenRecordingController.startLevelPump`).
    private var levelPumpTask: Task<Void, Never>?

    /// The folder of the last meeting that saved, for a click on "Meeting saved".
    private(set) var lastSavedDirectory: URL?

    /// The meeting the pill's bar belongs to, from its `.started` until its
    /// `.saved` / `.stopFailed`: its folder, and whether it still records
    /// (false once it is `.finalizing`). The folder is nil only for a meeting
    /// adopted in `init`, whose `.started` the bridge never saw.
    ///
    /// Events are matched by folder because meetings overlap: `stop()` frees the
    /// capture slot BEFORE it finalizes, so the next meeting's `.started` can
    /// land between this one's `.finalizing` and its `.saved` / `.stopFailed`.
    /// Only the current meeting's events may touch the bar — an earlier
    /// meeting's `.saved` must never clear the bar of the one recording now.
    private var current: (directory: URL?, isRecording: Bool)?

    static func install() {
        guard !DemoMode.isOn, shared == nil else { return }
        guard let recording = RecordingController.shared else {
            // Without the controller no meeting bar would ever rise — say so.
            Logger(subsystem: "dev.kleoth", category: "MeetingPill")
                .fault("RecordingController.shared is nil at launch — the meeting bar is not wired")
            return
        }
        shared = MeetingPillBridge(recording: recording, coordinator: PillCoordinator.shared)
    }

    init(recording: RecordingController, coordinator: PillCoordinator) {
        self.recording = recording
        self.coordinator = coordinator
        // `[weak self]` in both: the controller and the coordinator keep their
        // closures for the app's lifetime.
        coordinator.onMeetingAction = { [weak self] action in self?.handle(action) }
        coordinator.onMeetingDismiss = {
            // A dismissed fault leaves the History error card and the popover
            // line; there is nothing to cancel.
        }
        recording.addCaptureObserver { [weak self] event in self?.handle(event) }
        // A meeting already running when the bridge is made (never today — the
        // bridge is installed before any start path can run — but cheap): adopt
        // it; its first event with a folder claims the bar.
        if let since = recording.recordingSince {
            current = (directory: nil, isRecording: true)
            coordinator.setMeetingBackdrop(since: since)
            startLevelPump()
        }
    }

    // MARK: - Pill → controller

    private func handle(_ action: MeetingPillAction) {
        switch action {
        case .start:
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch await self.recording.start() {
                case .started, .alreadyRecording, .needsConsent:
                    // `.started`: the capture event puts the bar up.
                    // `.alreadyRecording`: the bar is already up.
                    // `.needsConsent`: the "Before you record" window is on its
                    // way (`consentRequest` → the menu-bar label) and the bar
                    // follows once it starts the recording. Nothing of our own.
                    break
                case .failed(let reason):
                    self.log.notice("meeting start from the pill failed: \(reason, privacy: .public)")
                    self.coordinator.showMeetingPhase(
                        .failed(.message("Couldn't start the meeting recording — \(reason)"))
                    )
                }
            }
        case .stop:
            Task { @MainActor [weak self] in await self?.recording.stop() }
        case .openLast:
            coordinator.dismissMeetingPhase()
            if let directory = lastSavedDirectory { recording.openInHistory(directory: directory) }
        }
    }

    // MARK: - Controller → pill

    private func handle(_ event: MeetingCaptureEvent) {
        switch event {
        case .started(let since, let directory):
            current = (directory: directory, isRecording: true)
            // A stale meeting phase (the previous meeting's `.saving`, its
            // confirmation or its fault) keeps `setBackdrop` from taking over —
            // it only takes a resting-family phase — so it has to go (the
            // `ScreenRecordingController.start(from:)` rule). Backdrop FIRST:
            // the coordinator's `clearCapturePhaseBlocking` then withdraws a
            // leftover phase and the pill collapses onto the new bar; the
            // dismissal after it only cancels a queued meeting confirmation.
            // The other order loses the bar: `dismiss()` springs to the OLD
            // backdrop, and the pill's `model.phase` only changes on the
            // transition's next main-queue turn, so a `setBackdrop` right after
            // still sees the stale phase and merely stores the new one — the
            // pill would settle on `.idle` (or the previous meeting's clock)
            // while this meeting records.
            coordinator.setMeetingBackdrop(since: since)
            coordinator.dismissMeetingPhase()
            startLevelPump()
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "Meeting recording started",
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )

        case .finalizing(let directory):
            guard isCurrent(directory), current?.isRecording == true else {
                log.notice("finalizing for a meeting the bar does not carry — ignored")
                return
            }
            current = (directory: directory, isRecording: false)
            stopLevelPump()
            // Over the still-`.meeting` backdrop, so the wave shows in the
            // meeting-sized bar. When it can't show (a dictation is up, or the
            // screen bar is on top), the meeting's backdrop goes now: the mic
            // is already off, and a live-looking clock with a Stop that answers
            // "Nothing is recording" must not come back after the dictation.
            if !coordinator.showMeetingPhase(.saving) {
                coordinator.setMeetingBackdrop(since: nil)
            }

        case .saved(let directory, let seconds, let transcribing):
            lastSavedDirectory = directory
            var text = "Meeting saved · \(ElapsedFormatter.string(seconds: Int(seconds.rounded())))"
            if transcribing { text += " · transcribing" }
            if isCurrent(directory) {
                current = nil
                stopLevelPump()
                // Backdrop FIRST, then the confirmation (the
                // `ScreenRecordingController.showSaved` order): on `.saving` the
                // change is only stored, and the confirmation owns the later
                // collapse onto it.
                coordinator.setMeetingBackdrop(since: nil)
                coordinator.showMeetingPhase(.meetingSaved(text))
            } else if current?.isRecording == false {
                // An earlier meeting saved while a later one is saving: that
                // one's `.saving` stays, and its own confirmation follows.
                // Showing ours would bring its bar back (still the backdrop)
                // with a running clock after 4 s. History has this one.
                log.notice("an earlier meeting saved while the next one is saving — no confirmation")
            } else {
                // An earlier meeting finished finalizing after the next one
                // started (or after nothing is left): its confirmation only,
                // 4 s, then the pill collapses back onto the current bar.
                coordinator.showMeetingPhase(.meetingSaved(text))
            }

        case .stopFailed(let message, let directory):
            log.notice("meeting stop failed: \(message, privacy: .public)")
            if isCurrent(directory) {
                current = nil
                stopLevelPump()
                coordinator.setMeetingBackdrop(since: nil)
            } else if current != nil {
                // An earlier meeting's finalize failed while a later one is up:
                // a sticky fault would hide the live bar (or its save) and read
                // as the new meeting failing. The History error card and the
                // popover line carry it.
                log.notice("the failed meeting is not the one on the bar — not shown in the pill")
                return
            }
            // No folder: `stop()` found no capture at all (a broken invariant),
            // so there is no audio to point at — the bar goes, nothing claims
            // otherwise. The popover line says what happened.
            guard directory != nil else { return }
            coordinator.showMeetingPhase(
                .failed(.message("The meeting stopped with an error — its audio is in History"))
            )
        }
    }

    /// Whether an event speaks for the meeting the bar carries (`current`).
    private func isCurrent(_ directory: URL?) -> Bool {
        guard let current else { return false }
        // A folder-less `stopFailed` is `stop()` finding no capture behind a
        // recording flag: it speaks for whatever records now.
        guard let directory else { return current.isRecording }
        // Adopted in `init`: the first event with a folder claims the bar.
        guard let known = current.directory else { return true }
        return known.standardizedFileURL == directory.standardizedFileURL
    }

    // MARK: - Level pump

    /// 20 Hz `RecordingController.meetingLevels` → the meeting bar's meters. A
    /// poll, not a callback, like the screen recording's: the meter only needs
    /// the latest value, and `meetingLevels` re-reads the recorder each tick.
    private func startLevelPump() {
        levelPumpTask?.cancel()
        levelPumpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.coordinator.setMeetingLevels(self.recording.meetingLevels)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Stops the pump and parks the meters at zero, so a stopped meeting never
    /// leaves the bar holding its last live level.
    private func stopLevelPump() {
        guard levelPumpTask != nil else { return }
        levelPumpTask?.cancel()
        levelPumpTask = nil
        coordinator.setMeetingLevels(.zero)
    }
}
