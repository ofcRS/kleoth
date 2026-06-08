import SwiftUI
import AppKit
import AVFoundation
import KleothCore
import KleothCapture

/// First-run onboarding: a fixed-size, five-step welcome flow that introduces
/// Kleoth, captures the user's name, walks the three recording permissions,
/// surfaces the on-device model download, and ends on the first recording.
///
/// Built as an explicit step *machine* (`Step`) rather than a paged `TabView`:
/// `PageTabViewStyle` doesn't exist on macOS, and a hand-rolled machine also lets
/// each step own its footer (Skip on welcome, Back/Continue elsewhere) and keeps
/// the window a fixed 560×600 (the parent `Window` uses `.contentSize`
/// resizability, so this view's frame *is* the window size).
///
/// Closing the window at any point counts as finishing setup: `finalize()` is
/// idempotent and runs from both the explicit Done/Start paths and `onDisappear`,
/// so onboarding never re-opens after the user has seen it. Everything visual
/// pulls from `KleothTheme`, and motion is gated on Reduce Motion.
struct OnboardingView: View {
    @EnvironmentObject private var controller: RecordingController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The flow's ordered steps. `Int` raw values drive both the linear
    /// Back/Continue navigation and the footer's step-dot indicator.
    private enum Step: Int, CaseIterable {
        case welcome, name, permissions, model, finish
    }

    @State private var step: Step = .welcome

    /// The display name being captured. Pre-filled with the first word of the
    /// macOS full name as a friendly default; an empty value falls back to "You".
    @State private var name: String = OnboardingView.defaultFirstName()

    /// Preferred on-device transcription language ("auto" = detect), mirrored from
    /// the controller's setting and committed back on change.
    @State private var transcriptionLanguage: String = "auto"

    /// Live microphone authorization, refreshed after a prompt so the row reflects
    /// the real grant state without polling.
    @State private var micStatus: AVAuthorizationStatus = RecordingController.microphoneStatus()

    /// Set once the user has triggered the system-audio permission prompt. There's
    /// no API to query that permission, so we can only reflect that we asked.
    @State private var systemAudioRequested = false

    /// Whether the user advanced to (or past) the name step, or edited the field —
    /// gates whether `finalize()` should persist the name, so merely skipping from
    /// the welcome screen doesn't overwrite a previously-saved name with a default.
    @State private var nameTouched = false

    /// Guards `finalize()` so its work runs at most once even though it's invoked
    /// from several paths (Done, Start, and `onDisappear`).
    @State private var didFinalize = false

    /// True once `onAppear` has seeded `name` from any previously-saved value, so
    /// the one programmatic change `seeding` causes doesn't spuriously flip
    /// `nameTouched` (which would let a re-run from Settings persist a name the
    /// user never actually edited).
    @State private var didSeedName = false

    /// Drives the welcome step's staggered entrance animation; flipped true shortly
    /// after appear so the spring/slide plays. Always effectively "on" under Reduce
    /// Motion (content appears instantly).
    @State private var welcomeAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, KleothMetrics.spacingXL)
                .padding(.top, KleothMetrics.spacingXL)

            footer
                .padding(.horizontal, KleothMetrics.spacingXL)
                .padding(.vertical, KleothMetrics.spacingL)
        }
        .frame(width: 560, height: 600)
        .onAppear {
            // Pre-fill the field with a previously-saved name when replaying the
            // flow from Settings, so advancing past welcome doesn't overwrite it
            // with the macOS-account default. `didSeedName` lets the resulting
            // `onChange` pass without marking the field as user-touched.
            if !controller.userName.isEmpty { name = controller.userName }
            didSeedName = true
            transcriptionLanguage = controller.settings.transcriptionLanguage ?? "auto"
            micStatus = RecordingController.microphoneStatus()
            AppActivation.shared.windowOpened()
            Self.playWelcomeChime()
            // Kick the welcome entrance just after the window paints.
            if reduceMotion {
                welcomeAppeared = true
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    welcomeAppeared = true
                }
            }
        }
        .onDisappear {
            finalize()
            AppActivation.shared.windowClosed()
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        // A cross-fade + slide between steps, skipped under Reduce Motion. The
        // `.id(step)` makes SwiftUI treat each step as a distinct view so the
        // transition fires on change.
        ZStack {
            switch step {
            case .welcome: welcomeStep
            case .name: nameStep
            case .permissions: permissionsStep
            case .model: modelStep
            case .finish: finishStep
            }
        }
        .id(step)
        .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .trailing)),
            removal: .opacity.combined(with: .move(edge: .leading))
        ))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: step)
    }

    // MARK: 1 — Welcome

    private var welcomeStep: some View {
        VStack(spacing: KleothMetrics.spacingL) {
            Spacer(minLength: 0)

            brandMark
                .scaleEffect(welcomeAppeared || reduceMotion ? 1.0 : 0.85)
                .opacity(welcomeAppeared || reduceMotion ? 1.0 : 0.0)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.7),
                    value: welcomeAppeared
                )

            VStack(spacing: KleothMetrics.spacingM) {
                Text("Welcome to Kleoth")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .modifier(RisingReveal(visible: welcomeAppeared, reduceMotion: reduceMotion, delay: 0.12))

                Text("Records your meetings and transcribes them right on your Mac — nothing leaves your machine.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                    .modifier(RisingReveal(visible: welcomeAppeared, reduceMotion: reduceMotion, delay: 0.24))
            }

            VStack(alignment: .leading, spacing: KleothMetrics.spacingM) {
                bullet("cpu", "On-device transcription — free, private, offline", delay: 0.36)
                bullet("globe", "Works in any language", delay: 0.48)
                bullet("folder", "No account, no sign-up. Your files live in ~/Kleoth.", delay: 0.60)
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.top, KleothMetrics.spacingS)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// One quiet feature bullet on the welcome step, with its own staggered reveal.
    private func bullet(_ symbol: String, _ text: String, delay: Double) -> some View {
        Label {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 22)
        }
        .modifier(RisingReveal(visible: welcomeAppeared, reduceMotion: reduceMotion, delay: delay))
    }

    // MARK: 2 — Name

    private var nameStep: some View {
        stepScaffold(
            title: "What should we call you?",
            subtitle: "Your name labels your voice in transcripts and summaries. Everyone else shows up as “Them” — rename them after your first meeting."
        ) {
            VStack(alignment: .leading, spacing: KleothMetrics.spacingS) {
                TextField("Your name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .frame(width: 320)
                    .onChange(of: name) { _, _ in if didSeedName { nameTouched = true } }
                    .onSubmit { advance() }

                Text("Leave this blank and your voice is simply labeled “You”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 3 — Permissions

    private var permissionsStep: some View {
        stepScaffold(
            title: "Three quick permissions",
            subtitle: "Kleoth records and transcribes locally. Grant these so it can capture your call — you can change them anytime in System Settings."
        ) {
            VStack(spacing: KleothMetrics.spacingM) {
                consentRow
                microphoneRow
                systemAudioRow
            }
        }
    }

    /// Recording-consent acknowledgement (the same acknowledgement the popover's
    /// `ConsentView` records), shown as a permission-style row.
    private var consentRow: some View {
        permissionRow(
            symbol: "exclamationmark.shield",
            title: "Recording consent",
            caption: "Kleoth records system + microphone audio locally. Make sure everyone in the call consents to being recorded — laws vary by jurisdiction."
        ) {
            if controller.consentAcknowledged {
                grantedCheck
            } else {
                Button("I understand") { controller.acknowledgeConsent() }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// Microphone access, reflecting the live `AVCaptureDevice` status and offering
    /// the right action for each state (request, granted check, or a deep link to
    /// System Settings when denied/restricted).
    private var microphoneRow: some View {
        permissionRow(
            symbol: "mic",
            title: "Microphone",
            caption: micStatus == .denied || micStatus == .restricted
                ? "Captures your voice in the meeting. Relaunch Kleoth after granting."
                : "Captures your voice in the meeting."
        ) {
            switch micStatus {
            case .authorized:
                grantedCheck
            case .denied, .restricted:
                Button("Open System Settings") {
                    Self.openSettings(Self.micSettingsURL)
                }
                .buttonStyle(.bordered)
            default: // .notDetermined (and any future case)
                Button("Allow") {
                    Task {
                        _ = await controller.requestMicrophoneAccess()
                        micStatus = RecordingController.microphoneStatus()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// System-audio capture. There's no API to query this permission, so the row
    /// can only trigger the one-time prompt and then nudge toward System Settings
    /// if it was denied.
    private var systemAudioRow: some View {
        permissionRow(
            symbol: "speaker.wave.2",
            title: "System audio",
            caption: systemAudioRequested
                ? "Click Allow when macOS asks. Denied it? Enable Kleoth under Screen & System Audio Recording."
                : "Captures what the other participants say — audio only."
        ) {
            VStack(alignment: .trailing, spacing: KleothMetrics.spacingXS) {
                Button("Allow") {
                    controller.primeSystemAudioPermission()
                    systemAudioRequested = true
                }
                .buttonStyle(.bordered)

                if systemAudioRequested {
                    Button("Open System Settings") {
                        Self.openSettings(Self.screenCaptureSettingsURL)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    // MARK: 4 — Model

    private var modelStep: some View {
        stepScaffold(
            title: "On-device transcription",
            subtitle: "Kleoth is downloading the speech model (~626 MB, Whisper Large v3 Turbo). It runs on the Apple Neural Engine — free, private, offline. You can keep going while it finishes."
        ) {
            VStack(alignment: .leading, spacing: KleothMetrics.spacingL) {
                modelStatus
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .kleothCard(padding: KleothMetrics.spacingM)

                VStack(alignment: .leading, spacing: KleothMetrics.spacingS) {
                    Picker("Language", selection: $transcriptionLanguage) {
                        ForEach(SettingsView.transcriptionLanguages, id: \.code) { lang in
                            Text(lang.label).tag(lang.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320, alignment: .leading)
                    .onChange(of: transcriptionLanguage) { _, newValue in
                        controller.updateTranscriptionLanguage(newValue)
                    }

                    Text("Leave on Auto-detect, or pin a language if detection ever guesses wrong.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The model's live download / ready / not-yet state, mirroring the Settings
    /// section but trimmed to the onboarding context.
    @ViewBuilder
    private var modelStatus: some View {
        if let progress = controller.modelDownloadProgress {
            VStack(alignment: .leading, spacing: KleothMetrics.spacingS) {
                ProgressView(value: progress)
                Text("Downloading speech model… \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if LocalTranscriber.cachedModelInfo().downloaded {
            Label("Speech model ready", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(KleothPalette.successTint)
                .labelStyle(.titleAndIcon)
        } else {
            VStack(alignment: .leading, spacing: KleothMetrics.spacingS) {
                Button("Download now") {
                    Task { await controller.prewarmTranscriptionModel() }
                }
                .buttonStyle(.bordered)
                Text("Or it downloads automatically on your first recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 5 — Finish

    private var finishStep: some View {
        VStack(spacing: KleothMetrics.spacingL) {
            Spacer(minLength: 0)

            brandMark

            VStack(spacing: KleothMetrics.spacingM) {
                Text("Ready? Start recording.")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Kleoth lives up in your menu bar — click the lyre anytime to start or stop. Every meeting is saved to ~/Kleoth as audio, transcript, and summary — files you own.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 430)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer (navigation)

    /// The persistent footer: a Skip affordance on welcome, the step-dot indicator,
    /// and the Back/Continue (or finish) controls. The primary action is the single
    /// glass/prominent element per step.
    private var footer: some View {
        HStack(spacing: KleothMetrics.spacingM) {
            leadingFooterControl
                .frame(minWidth: 120, alignment: .leading)

            Spacer(minLength: 0)

            stepIndicator

            Spacer(minLength: 0)

            trailingFooterControls
                .frame(minWidth: 120, alignment: .trailing)
        }
    }

    /// Leading control: "Skip setup" jumps straight to the finish step on welcome;
    /// "Back" steps backward everywhere else (hidden on the finish step, which uses
    /// its own Done button on the trailing side).
    @ViewBuilder
    private var leadingFooterControl: some View {
        switch step {
        case .welcome:
            Button("Skip setup") { goTo(.finish) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        case .name, .permissions, .model:
            Button("Back") { goBack() }
                .buttonStyle(.plain)
        case .finish:
            Color.clear.frame(width: 1, height: 1)
        }
    }

    /// Trailing control(s): a single prominent advance button on most steps; on the
    /// finish step, a quiet "Done" plus the prominent "Start your first recording".
    @ViewBuilder
    private var trailingFooterControls: some View {
        switch step {
        case .welcome:
            Button("Get Started") { advance() }
                .kleothProminentButton()
                .controlSize(.large)
        case .name, .permissions, .model:
            Button("Continue") { advance() }
                .kleothProminentButton()
                .controlSize(.large)
        case .finish:
            HStack(spacing: KleothMetrics.spacingM) {
                Button("Done") {
                    finalize()
                    dismiss()
                }
                .buttonStyle(.plain)

                Button("Start your first recording") {
                    // "Skip setup" jumps here without ever acknowledging consent;
                    // start() hard-guards on consent and would silently no-op
                    // after the window is dismissed. Route the user to the
                    // permissions step instead so the headline CTA always does
                    // something visible.
                    guard controller.consentAcknowledged else {
                        goTo(.permissions)
                        return
                    }
                    finalize()
                    Task { await controller.start() }
                    dismiss()
                }
                .kleothProminentButton()
                .controlSize(.large)
            }
        }
    }

    /// Five dots tracking progress through the flow; the current step is accent,
    /// the rest a quiet tint.
    private var stepIndicator: some View {
        HStack(spacing: KleothMetrics.spacingS) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s == step ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    // MARK: - Shared pieces

    /// The lyre brand mark on a soft accent tile — the same template glyph the
    /// menu bar and popover header use, tinted with the system accent. Falls back
    /// to an SF Symbol so it never renders empty.
    private var brandMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusCard, style: .continuous)
                .fill(Color.accentColor.opacity(0.22))
                .frame(width: 96, height: 96)
            if let glyph = KleothAssets.menuBarGlyph() {
                Image(nsImage: glyph)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 52)
                    .foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .accessibilityHidden(true)
    }

    /// Standard header + body layout for the middle steps: a large title, a quiet
    /// subline, then the step's content, top-aligned with generous breathing room.
    private func stepScaffold<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingL) {
            VStack(alignment: .leading, spacing: KleothMetrics.spacingS) {
                Text(title)
                    .font(.title.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, KleothMetrics.spacingM)
    }

    /// One permission row in the Kleoth card style: an accent icon, a title and
    /// caption, and a trailing control (button or granted check).
    private func permissionRow<Trailing: View>(
        symbol: String,
        title: String,
        caption: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: KleothMetrics.spacingM) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: KleothMetrics.spacingM)

            trailing()
        }
        .kleothCard(padding: KleothMetrics.spacingM)
    }

    /// A green granted indicator reused by the consent and microphone rows.
    private var grantedCheck: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.title3)
            .foregroundStyle(KleothPalette.successTint)
            .accessibilityLabel("Granted")
    }

    // MARK: - Navigation helpers

    /// Advances one step (or finalizes-and-dismisses past the last step, though the
    /// finish step uses its own buttons so this is just a safety net).
    private func advance() {
        if step == .name { nameTouched = true }
        guard let next = Step(rawValue: step.rawValue + 1) else {
            finalize(); dismiss(); return
        }
        // Reaching the name step (or beyond) means a blank field is a deliberate
        // "call me You", so the name should persist on finalize.
        if next.rawValue >= Step.name.rawValue { nameTouched = true }
        goTo(next)
    }

    /// Steps backward one step (no-op at the first step).
    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        goTo(previous)
    }

    private func goTo(_ target: Step) {
        if reduceMotion {
            step = target
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { step = target }
        }
    }

    /// Commits onboarding state exactly once, regardless of how the flow ends
    /// (Done, Start, Skip-then-close, or closing the window mid-flow): persist the
    /// name when it was reached/edited, and mark onboarding complete so it never
    /// auto-opens again. Both controller calls are themselves idempotent; the
    /// `didFinalize` guard simply avoids redundant Keychain writes.
    private func finalize() {
        guard !didFinalize else { return }
        didFinalize = true
        if nameTouched {
            controller.updateUserName(name)
        }
        controller.completeOnboarding()
    }

    // MARK: - System Settings deep links

    private static let micSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    private static let screenCaptureSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    private static func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Defaults

    /// The first word of the macOS full name ("Anna Smith" → "Anna"), used as a
    /// friendly default for the name field. Empty if the system name is unset.
    private static func defaultFirstName() -> String {
        String(NSFullUserName().split(separator: " ").first ?? "")
    }

    // MARK: - Welcome chime

    /// Retains the welcome chime player for its lifetime so playback isn't cut off
    /// by deallocation mid-sound. Main-actor confined (UI / single-shot).
    @MainActor private static var chimePlayer: AVAudioPlayer?

    /// Plays the bundled welcome chime once at a gentle volume. Fails silently when
    /// the resource is absent (it's produced by a separate asset step and may not
    /// be on disk yet), so onboarding never depends on it.
    @MainActor
    private static func playWelcomeChime() {
        guard let url = Bundle.module.url(forResource: "WelcomeChime", withExtension: "m4a") else {
            return
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = 0.5
        player.prepareToPlay()
        player.play()
        chimePlayer = player
    }
}

// MARK: - Staggered reveal modifier

/// A small entrance animation for the welcome step: fades in and rises 8pt into
/// place after a per-element `delay`, so the title, value line, and bullets stagger
/// in roughly in time with the chime. A no-op under Reduce Motion (content is shown
/// instantly), matching the app's existing motion discipline.
private struct RisingReveal: ViewModifier {
    let visible: Bool
    let reduceMotion: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(visible || reduceMotion ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 8)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.45).delay(delay),
                value: visible
            )
    }
}
