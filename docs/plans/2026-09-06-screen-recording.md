# FINAL DESIGN — Loom-style screen recording from the dictation pill

_Synthesizer pass, 2026-09-06. Base = Design B (robustness-first, the judges' winner 8 / 7.5), with the
grafts both judges asked for from Design A and every listed factual error fixed against the working tree at
`06b60d0` (HEAD; `git status` shows no changes under `app/Sources` — see §3.0). Repo =
`/Users/shck/projects/kleoth-app`, paths repo-relative. SDK header refs are in
a local scratch research note, uncommitted (SDK 26.5; this Mac runs 26.6.2)._

**What changed versus Design B (graft log — each item is the judges' call, with the data):**
1. **Bitrate 3 Mbps at 1080p, area-scaled down to a 1 Mbps floor** (`CaptureGeometry.videoBitRate`), peak cap
   kept at 2× (from A). Screen content is low-motion; file size is the user's #1 pain: ≈ 23 MB/min ceiling at
   1080p instead of 31. §8 #12 measures a real 5-minute file and says when to drop to 2.5 Mbps.
2. **`shouldOptimizeForNetworkUse = true` on the writer** (from A) — matters the moment §8 #16 flips
   `fragmentInterval` to nil (moov at the front for Slack/browser previews).
3. **TCC spike runs INSIDE the signed bundle** (from A): a bare `screenrec` launched from a terminal is
   attributed to the terminal's Screen Recording grant (TCC "responsible process") and proves nothing about the
   "Kleoth Self-Signed" identity. B's `screenrec 10` from the shell would have given a false green.
4. **Whole-application exclusion (`SCContentFilter(display:excludingApplications:exceptingWindows:)`) is the
   v1 default** (from A). B's per-window exclusion had a hole: the pill panel is created lazily by
   `ensurePanel()` inside the first `show()` (`DictationPillController.swift:121, :326-343`), so a recording
   started from the popover with the pill hidden has no window number to exclude and the indicator WOULD land
   in the video. Per-window exclusion (demoing Kleoth's own windows) is deferred (§9). Consequence: the
   `windowNumber` protocol addition is gone.
5. **No new `Settings` field / Keychain key / `AppConfig` line / Settings toggle in v1** (from A). The popover
   "Record screen…" row plus "a recording forces the pill on" already covers the dictation-off user. B's "Keep
   the pill on screen" toggle ships only if a user asks (§9, user decision).
6. **`.recording → .armed` blink handled**: `.armed` on a `.recording` backdrop lays out at the recording
   capsule's size (mic glyph replaces dot + digits) instead of shrinking to 68×22 for `minHold` 0.2 s. Filmed
   in the sandbox (§6.5); if it reads worse than the shrink, revert to the shrink and note it.
7. **Thickness discipline on stop**: `.recording` 28 → `.saving` 28 (same capsule, content-only swap) →
   `.saved(text)` 32 (the motion thickness, ONE morph) → `.idle` 22 (the sink). B's 28→32→38→22 staircase is
   gone.
8. **`.quitKleoth` pill action dropped** (from A's restraint): a pill button that quits the app on a false
   positive of the first-frame detector is worse than a sticky "quit and reopen" message. The stale-grant
   fault keeps `.openScreenRecordingSettings` as its action.
9. **Elapsed time = `.recording(since: Date)` payload + `TimelineView(.periodic(from: since, by: 1))` in the
   view** (from A, judge 2's graft). `since` is fixed per session, so every re-show compares equal (no spurious
   `reshapes`/beat/announce), and there is no `setElapsed` protocol method, no 1 Hz main-actor push through
   every dictation phase, no cross-controller timer traffic. B's fixed 56 pt monospaced digit box is kept so
   `1:02:34` never re-measures.
10. **Keepalive frames are OFF by default; the retained last frame is re-appended only at stop** (from A, judge
    2). B's 1 s keepalive stamped a copy at `now` on `videoQueue` while a real frame stamped slightly earlier
    could still be in flight → non-monotonic video PTS → `AVAssetWriterInput` failure. `VideoFrameGate` now
    guards EVERY append on `pts > lastAppendedPTS` (drop otherwise); `keepaliveInterval` stays a constant
    (nil) that §8 #19 may turn on if a 60 s static stretch scrubs badly.
11. **`ScreenRecorderError.nothingCaptured`** (from A): zero video frames appended at `stop()` is an explicit
    failure (`.failed(.message("Nothing was recorded."))`, file deleted) — never a `.saved` for an empty file.
12. **Mic `.notDetermined`**: the silent stretch lasts as long as the system dialog is up, not "~1 s";
    `MicrophoneSource` attaches late when the grant lands (B's design, wording fixed).

**Factual errors fixed (verified against the tree):**
- `kill -TERM` does NOT reach `applicationShouldTerminate(_:)` — AppKit installs no SIGTERM handler; the
  default disposition kills the process at once and neither delegate method runs. Only ⌘Q / popover Quit /
  logout / Apple-Event quit / `NSApp.terminate` do. fMP4 fragments are what rescue a SIGTERM/SIGKILL (§2.7).
- `DictationPillState.isSticky` is an `if case .failed` (`DictationPillController.swift:921-924`), not an
  exhaustive switch — it compiles unchanged; it is NOT in the list of switches that gain cases (§6.1).
- `.saved(String)` (≈ 140 pt capsule) is LONGER than the hands-free listening reference (≈ 110 pt), so
  `activeOrigin` (`:678-683`) can nudge it per phase near a corner — the same accepted nudge every existing
  `.warning` text gets. Stated honestly in §6.1; not "no creep".
- `ScreenRecorder` is **`@MainActor`** (§3.2). Every target in `app/Package.swift` is
  `.swiftLanguageMode(.v6)` with no `NonisolatedNonsendingByDefault`; a non-Sendable, non-isolated class whose
  `async` methods are called from a `@MainActor` stored property is a compile error ("sending 'self' risks
  causing data races") — the reason `RecordingController.stop()` resorts to `nonisolated(unsafe) let capture`
  + `Task.detached` (`RecordingController.swift:587-598`). The SCK/mic/writer callbacks live on
  `@unchecked Sendable` sink objects with their own serial queues; only results hop back to the main actor.
- `DictationController.handlePillAction` spans `:812-827`; its unconditional `pill.dismiss()` is at **`:826`**.
  Implementers: anchor edits on the code, never on a line number.
- "macOS 14.4 has no system purple screen-recording indicator (15+ only)" is UNVERIFIED (knowledge-pack
  Chromium note, not checked on a 14.x machine or an SDK header). The menu-bar glyph decision (§2.3) does not
  depend on it: the pill can be on a display the user is not looking at.

---

## 1 Goal + non-goals

**Goal.** From the resting pill (hover → record glyph) or the popover, record **one display or a dragged region
of it**, with **system audio + microphone mixed into ONE stereo AAC track on the video's clock**,
hardware-encoded to a **small H.264 `.mp4`** (long edge ≤ 1920 px, 30 fps, 3 Mbps average at 1080p / 6 Mbps
peak ⇒ ≈ 23 MB/min ceiling, §5.4), written to `<outputDir>/screen-recordings/`, and **never lost**: quit,
crash, display disconnect, mic disconnect and Bluetooth profile flips all end in a playable file or an honest
error. While recording, the pill is a persistent indicator with elapsed time; stop from the pill. Recording
is independent of dictation and of meeting recording; all three coexist and the pill returns to the recording
indicator after a dictation.

**Non-goals (v1).** Camera bubble, trim/edit, upload/share links, per-window capture, pause/resume, HEVC,
transcription of recordings, a History scope (§9), a Settings toggle, remembered regions, keyboard shortcut,
countdown, per-window exclusion of Kleoth's own windows.

**Working assumptions — kept, one extended with data:**
- `~/Kleoth/screen-recordings/<timestamp>.mp4`, not a meeting folder — kept (§2.5).
- H.264 + AAC `.mp4`, capped resolution, ~30 fps — kept (§5).
- Mic + system mixed to one track — kept (§4).
- Three-way independence — kept (§4.6, §6.3).
- **Extended:** the pill is on screen only while the fn+shift monitors run
  (`app/Sources/KleothApp/Dictation/DictationController.swift:27-31` mirrors `isMonitoring` into
  `pill.setResting(_:)`; `DictationPillController.setResting(false)` → `hideCompletely()`,
  `app/Sources/KleothPillUI/DictationPillController.swift:176-186`). A user with dictation off or untrusted
  has **no pill to hover**, and a hot mic + screen capture with no on-screen indicator is unacceptable. So the
  pill gains a **backdrop** (§6.1): visible when dictation is armed **OR** a screen recording is in flight.
  Dictation's own behavior is unchanged when nothing records; the dictation-off user starts from the popover
  and the pill appears for the recording's duration.

---

## 2 User-facing behavior

### 2.1 Start from the pill
1. Hover the resting sliver → it peeks fully out (existing: `DictationPillController.handleHover`
   `:362-376` → `setPeeking(true)` `:378-383`). While peeking the capsule shows the mic glyph (existing,
   `app/Sources/KleothPillUI/DictationPillView.swift:217-224`) **and a red `record.circle.fill` glyph** to its
   right. Capsule stays 68×22 (`PillStyle.restingWidth/restingHeight`, `DictationPillView.swift:409-410`).
2. Click the record glyph (a `Button`) **or anywhere on the peeking capsule** →
   `DictationPillAction.startScreenRecording` → `PillCoordinator` → `ScreenRecordingController.start(from: .pill)`.
3. **Preflight** (§2.6, §7 rows 1–7): permission, disk space, not already active, display present, output
   folder writable.
4. **Region picker**: a full-screen, transparent, `.screenSaver`-level overlay window on **every** display
   (so a second display is chosen by simply dragging on it), dimmed 30 %, crosshair cursor, hint at the
   bottom of each display: *"Drag to record an area · Return records this whole screen · Esc cancels"*.
   - **Drag** ≥ `ScreenRecordingDefaults.minRegionPoints` (64×64 pt) → that region; the rect shows its size in
     points and the resulting output size in pixels (e.g. "1280×720 pt → 1920×1080 px").
   - **Return**, or a click without a qualifying drag → the whole display under the pointer.
   - **Esc**, ⌘., or the overlay losing key status (another app activated) → cancel; the pill sinks back to
     its backdrop. Nothing was started, nothing is logged.
5. Overlays close **before** the shareable-content snapshot and `startCapture`; Kleoth's whole application is
   excluded from the filter anyway (§5.2). The controller shows **`.recording(since: now)`** on the pill BEFORE
   `recorder.start()` (so a Kleoth window is on screen for the snapshot — §5.2 — and the press is
   acknowledged at once): red dot (pulsing unless Reduce Motion) + monospaced `mm:ss` (→ `h:mm:ss` past an
   hour). It sits at the dock anchor, fully on screen, on every Space (`DictationPanel`
   `canJoinAllSpaces`/`fullScreenAuxiliary`, `app/Sources/KleothPillUI/DictationPanel.swift:22-80`). The pill,
   the picker overlays and every other Kleoth window are excluded from the capture. The digits may run up to
   ~1 s ahead of the file (startup latency) — the file duration is authoritative, the pill is indicative.
6. The first `.screen` sample of ANY status is expected within `firstFrameTimeout` (5 s). If none arrives the
   session is torn down (file deleted) and the pill shows the sticky fault `.screenRecordingStale` (§2.6) —
   the "toggle on, not relaunched" state. ⚠️ Unverified detector (§8 #2); if SCK ever withholds the initial
   frame on a static screen, `firstFrameTimeout` flips to nil (one constant) and the stale state is detected
   only by `-3801`.

### 2.2 Start from the popover (universal entry)
`MenuView` gets one row under `recordControl` (`app/Sources/KleothApp/Views/MenuView.swift:113-120`, pattern
`dictationAccessNotice` `:207-216`): **"Record screen…"**. While recording it becomes
**"Stop screen recording · 02:14"** (digits via `TimelineView(.periodic)` from the machine's `since`); while
finalizing, "Saving screen recording…" (disabled). Same `start(from: .popover)` / `stop()` as the pill. This is
the entry for a user with dictation off; the pill then appears anyway because a recording is in flight (§6.3).

### 2.3 While recording
- **Pill** `.recording(since:)`: hovering swaps the red dot for `stop.fill`; help text "Recording the screen —
  click to stop"; click anywhere on the capsule → `.stopScreenRecording`. `model.hovered` is already set in
  every phase by `handleHover` (`DictationPillController.swift:365`) and unread by the view today
  (`app/Sources/KleothPillUI/DictationPillModel.swift:46`) — it becomes the hover-swap trigger.
- **Menu bar**: `KleothMenuBarLabel.icon` (`app/Sources/KleothApp/KleothApp.swift:96-105`) shows
  `record.circle` when **either** a meeting or a screen recording runs. Decision: the pill can be on a display
  the user is not looking at; a hot mic must always be visible in the menu bar. (Whether 14.4 has a system
  indicator is unverified and irrelevant to this decision; on 15+/26 the system's purple indicator and ours
  coexist.)
- **Popover header subtitle** (`MenuView.swift:107-111`): "Recording the screen · 02:14" when only the screen
  recording runs; the meeting text wins when both run (meetings are the app's primary job).
- **Dictation mid-recording**: fn+shift works exactly as today. The capsule morphs in place
  `.recording → .armed → .listening → .transcribing → .polishing → .done` and every `pill.dismiss()` on the
  dictation path collapses to the **backdrop `.recording(since:)`**, not `.idle` (§6.3). The digits resume at
  the correct value because `since` never changed. Dictated words land in the screen recording's mic track —
  accepted, same as for meetings (`app/Sources/KleothCapture/DictationCapture.swift:52-60`).
- **Meeting recording** may start or stop at any time (§4.6). Nothing is shared.

### 2.4 Stop
Pill click, popover row, `applicationShouldTerminate` (§2.7), stream stop by the system (§2.7), or a writer
failure (§7). Sequence: `.recording → .saving` (same capsule, dot + frozen digits replaced by a travelling
wave, ≤ `finalizeTimeout` 5 s) → `.saved("2:14 · 48 MB")` for 4 s (green check + text; **click = Reveal in
Finder**) → backdrop. If a dictation phase is live when finalize completes, the `.saved` confirmation is
**queued** and shown after the dictation's own `dismiss()`; a confirmation older than
`savedConfirmationMaxDelay` (10 s) is dropped (the popover row still has it).

### 2.5 Where the file goes, and reaching it
- Directory: `AppConfig.settings().outputDir.appendingPathComponent(ScreenRecordingDefaults.directoryName)`
  = `~/Kleoth/screen-recordings/` by default (`Settings.outputDir` default `~/Kleoth`,
  `Sources/KleothCore/Config/Settings.swift:55-56`; sibling of `dictations/`,
  `Sources/KleothCore/Dictation/DictationLogStore.swift:18-27`). Resolved **per session**, never cached
  (Settings can move the folder — `DictationController.syncLogStore` idiom `:319-326`).
- Name: `screen-yyyy-MM-dd-HHmmss.mp4`, `en_US_POSIX` (`DictationLogStore.dayFileName` `:34-45` idiom),
  uniqued with `-2`, `-3` on collision (`ScreenRecordingFileNaming`, tested). **While recording** the writer
  targets `screen-….recording.mp4`; a clean `finishWriting` renames it to the final name. A leftover
  `*.recording.mp4` at launch (crash/kill) is renamed `screen-…-recovered.mp4` if it holds ≥ 1 fragment
  (§5.5) or trashed if it is empty — nothing silently disappears.
- Why the meeting list ignores the folder: `RecordingController.meetingAudioURL(in:)`
  (`app/Sources/KleothApp/RecordingController.swift:1623-1630`) lists an audio-less directory only if it
  contains `meeting.m4a`/`combined.m4a`/`mic.m4a`/`system.m4a`. This design never writes an `.m4a` there
  (the mix lives in memory, §4.4). Creating the subfolder fires one harmless top-level watcher reload
  (`:1697-1733`).
- Reaching the file: (a) click the `.saved` pill; (b) popover row **"Last screen recording · 2:14 · 48 MB"**
  with **Reveal** (`NSWorkspace.shared.activateFileViewerSelecting`, `HistoryView.swift:206-209` idiom) and
  **Copy Path** (`NSPasteboard.general` + `flashCopied()` 1.5 s, `DictationDetailView.swift:171-190`);
  (c) Settings → Screen Recording → **"Open Recordings Folder"**. No History scope in v1 (§9).

### 2.6 Permissions
Screen Recording TCC has **no Info.plist key** (`app/bundle/Info.plist` comment, lines 36-38), is bound to
the code signature (grant lost on an ad-hoc rebuild — the stable "Kleoth Self-Signed" identity from
`app/make-app.sh:44-55` is mandatory, as for Accessibility), and **a fresh grant is not observable until
relaunch** (`CGPreflightScreenCaptureAccess` keeps returning false; System Settings itself says the app "may
not be able to record … until it is quit" — Apple DTS, forums thread 732726). The design tells the truth at
every step:

| State (`ScreenRecordingPermission.State`) | How detected | What the user sees |
|---|---|---|
| `.granted` | `CGPreflightScreenCaptureAccess() == true` | nothing; start proceeds |
| `.notDetermined` (never asked) | preflight false **and** no `dev.kleoth.screenRecording.permissionRequestedAt` default | first start calls `CGRequestScreenCaptureAccess()` (system dialog), stores the timestamp, then shows sticky `.failed(.screenRecordingNeeded)` "Allow Screen Recording, then quit and reopen Kleoth" with action **Open Screen Recording Settings** (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`) |
| `.deniedOrStale` (asked before, still false) | preflight false, timestamp present | same sticky fault; Settings row shows "Not granted — allow it, then quit and reopen Kleoth" with **Open System Settings** |
| `.grantedButStale` (toggle on, not relaunched) | preflight true but no `.screen` sample in `firstFrameTimeout`, or `SCShareableContent`/`startCapture` throws `-3801` | sticky `.failed(.screenRecordingStale)` "Quit and reopen Kleoth to finish enabling Screen Recording" with action **Open Screen Recording Settings** (no quit button — §graft 8) |

- Settings → Screen Recording row polls `CGPreflightScreenCaptureAccess()` at 1 Hz while the window is open
  (the `SettingsDictationSection.swift:43-48` idiom) — it flips green after the relaunch, and the copy says so.
  `refreshPermission()` also runs on `didBecomeActive` (the `refreshTrust()` observer, `AppWiring.swift:74-80`).
- Onboarding: **not** primed (a Screen Recording prompt on first launch of a meeting recorder is off-putting
  and needs a relaunch anyway). First use primes it.
- macOS 15+/26: the monthly *"Kleoth is requesting to bypass the system private window picker…"* alert
  ("Allow For One Month") fires for any non-picker SCK use (9to5mac 2024-08-14; TidBITS 2024-09-23). It cannot
  be avoided for a region recorder (`SCContentSharingPicker` has no rectangle mode — `SCContentSharingPicker.h:19-25`;
  the `persistent-content-capture` entitlement is VNC-only per forums 761641). The pill's help text and the
  Settings footer say: *"macOS may ask you to re-allow screen recording about once a month."*
- Microphone: `AVCaptureDevice.authorizationStatus(for: .audio)`. `.denied` → record **without** mic, pill
  `.warning("Recording without the microphone — allow it in System Settings")` for 3 s, then `.recording`
  (§7 row 5). `.notDetermined` → request; the system prompt is asynchronous and Core Audio returns zeros for
  as long as the dialog is up, so the `MicrophoneSource` attaches **late**, the moment the grant lands (§4.2);
  the mic track is silent until then (honest, not "~1 s").

### 2.7 Quit / display disconnect / audio device change
- **Quit** (popover Quit, ⌘Q from a Kleoth window, logout, Apple-Event quit, `NSApp.terminate`): `AppDelegate`
  gains `applicationShouldTerminate(_:)`. If a recording is in flight: stop capture, start `finishWriting`,
  return `.terminateLater`, and call `NSApp.reply(toApplicationShouldTerminate: true)` when finalize completes
  or after `finalizeTimeout` (5 s) — whichever first. `applicationWillTerminate` stays synchronous
  (`app/Sources/KleothApp/AppWiring.swift:83-88`, comment says why). Popover Quit guard
  (`MenuView.swift:282-308`) extends its condition to `controller.isProcessing || screenRecording.isActive`
  with dialog copy "A screen recording is in progress. Quit saves what was recorded so far." (Quit Anyway /
  Cancel). **`kill -TERM` and `kill -9` bypass BOTH delegate methods** (AppKit installs no SIGTERM handler);
  there the fragmented file (§5.5) is the only safety net: every completed 10 s fragment is playable and the
  launch sweep renames the leftover to `-recovered.mp4`.
- **Display disconnect / sleep / lock**: SCK stops the stream — `didStopWithError` (14.4) or
  `SCStreamErrorSystemStoppedStream -3821` (15+). The recorder treats it as a **stop, not a failure**: finalize
  what exists → `.saved("2:14 · 48 MB")` plus the popover row's detail "Stopped: display disconnected".
  Lock screen / display sleep deliver `.idle`/`.blank`/`.suspended` frames which are dropped; the audio
  continues; the video simply has no new samples until the next `.complete` frame (players hold the last
  frame), and the stop-time re-append (§5.3) closes the tail.
- **Mic device change** (unplug, Bluetooth A2DP→HFP flip at mic open, default input change): the
  `MicrophoneSource` handles `.AVAudioEngineConfigurationChange` exactly like
  `DictationCapture.handleConfigurationChange()` (`DictationCapture.swift:399-422`): reinstall the tap at the
  node's new format, rebuild the `AVAudioConverter` to 48 kHz stereo, restart. The mixer (§4.3) is keyed by
  host time, so the gap is zero-filled and the mic resumes in sync; the result carries `MicGap`s and the
  popover row says "mic dropped for 1.2 s at 3:12" when any gap exceeds 0.5 s. If the engine cannot restart,
  the recording **continues without mic** and ends with `.warning("Saved — the microphone dropped out at 3:12")`.
- **Default output device change** (AirPods connect): irrelevant to SCK audio — it is a process-level mixdown,
  not a device capture (`SCStreamConfiguration.capturesAudio`, `SCStream.h:295`). Verified by §8 #22.
- **Bluetooth mic caveat**: opening the mic flips the headset to HFP, so system audio the user *hears* drops in
  quality while recording (not the recorded system audio). Documented in the Settings footer; no fix.

---

## 3 Architecture

### 3.0 Baseline the implementers build on
`git status` at HEAD `06b60d0` shows NO modifications under `app/Sources` — the AudioFormat / DictationCapture /
MicCapture edits listed in the thread's STATE.md as "uncommitted" were committed as `72cca9a` ("Fix capture on
external mics: clamp the AAC bit rate to the encoder, survive the Bluetooth profile switch", +378/−54) and
documented in `06b60d0`. Every worktree MUST be cut from ≥ `06b60d0`; those three files are DO-NOT-TOUCH
(§3.2 "Do not touch"). Untracked but unrelated in the tree: `docs/CODE-REVIEW.md`, three `Resources/Empty*V2.png`,
`app/branding-src/{cleos-v2,kleoth-lyre}/` — never sweep them into a screen-recording commit.

Four targets, one contract. Signatures below are the seams parallel implementers build against; anything not
shown is private to its target.

```
KleothCore  (pure, tested)     ScreenRecordingDefaults · ScreenRecordingTypes (Failure/StopReason/Summary/MicGap) ·
                               CaptureGeometry · ScreenRecordingSessionMachine · ElapsedFormatter ·
                               ScreenRecordingFileNaming · HostClockMath · AudioRing · MixMath
KleothCapture (capture+encode) ScreenRecorder (@MainActor) · ScreenRecordingTarget/Configuration · ScreenRecorderEvent/Error ·
                               ScreenRecordingPermission · VideoFormat · internal: MicrophoneSource · SystemAudioSink ·
                               AudioMixPump · VideoFrameGate · MovieWriter   (deletes ScreenshotCapture.swift)
KleothPillUI (pill)            +DictationPillState.recording(since:)/.saving/.saved(String) · +DictationPillBackdrop ·
                               +DictationPillFault ×2 · +DictationPillAction ×4 · DictationPillController.setBackdrop + currentState
KleothApp   (glue)             PillCoordinator · ScreenRecordingController · RegionPicker · SettingsScreenRecordingSection ·
                               popover rows · AppDelegate terminate hook · screenrec probe target
```

### 3.1 KleothCore — `Sources/KleothCore/ScreenRecording/` (+ `Tests/KleothCoreTests/ScreenRecording*Tests.swift`)
The app package has no test target (`app/Package.swift`), so every decision that can be pure lives here.
Gotcha (CLAUDE.md): after adding KleothCore files delete `app/.build/arm64-apple-macosx/debug/description.json`.

```swift
public enum ScreenRecordingDefaults {
    public static let directoryName = "screen-recordings"
    public static let filePrefix = "screen"
    public static let recordingSuffix = ".recording.mp4"     // in-flight name
    public static let recoveredSuffix = "-recovered.mp4"
    public static let framesPerSecond: Int32 = 30            // SCStream.h:222 minimumFrameInterval
    public static let maxLongEdgePixels = 1920               // Loom ladder / CleanShot downscale precedent; dodges AVAssetWriter 4096×2304
    public static let videoBitRateAt1080p = 3_000_000        // §5.4 (graft 1)
    public static let minimumVideoBitRate = 1_000_000
    public static let peakBitRateMultiplier = 2.0            // HLS rule: peak ≤ 200 % of average
    public static let keyFrameIntervalSeconds = 2
    public static let audioSampleRate = 48_000.0             // SCStream.h:300 default
    public static let audioChannels: UInt32 = 2
    public static let audioBitRate = 128_000                 // clamped by AudioFormat.maxAACBitRate
    public static let mixBlockFrames = 960                   // 20 ms @ 48 kHz
    public static let mixLatency: TimeInterval = 0.25        // pump reads this far behind "now"
    public static let ringSeconds: TimeInterval = 2.0
    public static let mixAlignToleranceFrames = 96           // 2 ms: jitter → contiguous append
    public static let keepaliveInterval: TimeInterval? = nil // §5.3 — OFF; stop-time re-append only (graft 10)
    public static let firstFrameTimeout: TimeInterval? = 5.0 // nil disables the stale-grant detector
    public static let finalizeTimeout: TimeInterval = 5.0
    public static let fragmentInterval: TimeInterval? = 10   // nil → plain moov-at-front file (§5.5)
    public static let minRegionPoints: CGFloat = 64
    public static let minFreeDiskBytes: Int64 = 500 * 1024 * 1024
    public static let savedConfirmation: TimeInterval = 4
    public static let savedConfirmationMaxDelay: TimeInterval = 10
    public static let micGapReportThreshold: TimeInterval = 0.5
    public static let micOffsetCompensation: TimeInterval = 0   // §4.5 clap-test knob
    public static let permissionRequestedDefaultsKey = "dev.kleoth.screenRecording.permissionRequestedAt"
}

/// Shared value types (T0 contract). Acronym-free names — the project's stored-key rule.
public enum ScreenRecordingStopReason: Equatable, Sendable { case user, quit, systemStoppedStream, writerFailed, displayLost }
public enum ScreenRecordingFailure: Equatable, Sendable {
    case permissionNeeded, permissionStale, noDisplay, diskFull, alreadyActive, outputUnwritable(String),
         captureFailed(String), writerFailed(String), nothingCaptured
}
public struct ScreenRecordingSummary: Equatable, Sendable {    // stored nowhere in v1; drives the pill/popover text
    public var url: URL; public var duration: TimeInterval; public var fileSizeBytes: Int64
    public var videoFramesAppended: Int; public var droppedFrames: Int; public var micCaptured: Bool
    public var micGaps: [MicGap]; public var stopReason: ScreenRecordingStopReason
    public var pillText: String { "\(ElapsedFormatter.string(seconds: Int(duration))) · \(sizeText)" }  // "2:14 · 48 MB"
    public struct MicGap: Equatable, Sendable { public var at: TimeInterval; public var duration: TimeInterval }
}

/// Pure geometry: points → pixels, AppKit ↔ display-local, caps, rounding, bitrate policy.
public enum CaptureGeometry {
    /// Output size in pixels: source points × scale, long edge capped, both dims rounded DOWN to even
    /// (AVVideoSettings.h:65), aspect preserved. 2880×1800 pt @2 → 1920×1200; 1280×720 pt @2 → 1920×1080.
    public static func outputPixelSize(sourcePoints: CGSize, pointPixelScale: CGFloat, maxLongEdge: Int) -> CGSize
    /// AppKit global rect (bottom-left origin) → SCStream `sourceRect` (display-local, TOP-left origin, points).
    /// x = r.minX − s.minX; y = s.maxY − r.maxY.
    public static func sourceRect(fromGlobal rect: CGRect, displayFrame: CGRect) -> CGRect
    /// Drag rect normalized + clamped to the display; nil if a side < `minimum` (→ whole display).
    public static func region(from dragStart: CGPoint, to end: CGPoint, in displayFrame: CGRect, minimum: CGFloat) -> CGRect?
    /// videoBitRateAt1080p × (w·h / (1920·1080)), clamped to [minimumVideoBitRate, videoBitRateAt1080p]. (graft 1)
    public static func videoBitRate(pixelSize: CGSize) -> Int
}

/// The session's life as a pure machine (mirrors DictationChordMachine's role). Every controller
/// transition goes through `apply`; illegal events are rejected (nil effect, state unchanged), never crashed on.
public struct ScreenRecordingSessionMachine: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle, checkingPermission, pickingRegion, starting(since: Date), recording(since: Date),
             stopping(reason: ScreenRecordingStopReason), saving, saved(ScreenRecordingSummary), failed(ScreenRecordingFailure)
    }
    public enum Event: Equatable, Sendable {
        case startRequested(Date), permissionOK, permissionMissing(ScreenRecordingFailure), regionPicked, regionCancelled,
             captureStarted, captureDidNotStart(ScreenRecordingFailure), stopRequested(ScreenRecordingStopReason),
             captureStopped, finalized(ScreenRecordingSummary), finalizeFailed(ScreenRecordingFailure), dismissed
    }
    public enum Effect: Equatable, Sendable { case requestPermission, presentPicker, startCapture, showRecording, stopCapture, finalize, showSaved, showFailed, reset }
    public private(set) var state: State
    public init()
    @discardableResult public mutating func apply(_ event: Event) -> Effect?
    public var isActive: Bool   // anything but idle/saved/failed
    public var since: Date?     // starting/recording payload
}
// Tests: happy path; Esc in picker → idle; stopRequested while starting → stopping (never lost); systemStoppedStream while
// recording → stopping → saving; quit while pickingRegion → idle (no file); startRequested while active → nil + unchanged;
// every state × every event has a defined result (table-driven).

public enum ElapsedFormatter {
    /// 0 → "00:00", 754 → "12:34", 3754 → "1:02:34". Monospaced-digit friendly (no locale).
    public static func string(seconds: Int) -> String
}

public enum ScreenRecordingFileNaming {
    public static func baseName(for date: Date) -> String                     // "screen-2026-09-06-143012" (en_US_POSIX)
    public static func recordingURL(in dir: URL, date: Date, existing: Set<String>) -> URL  // uniqued "-2", "-3"; ".recording.mp4"
    public static func finalURL(for recordingURL: URL) -> URL                 // strips ".recording"
    public static func recoveredURL(for recordingURL: URL) -> URL
    public static func isInFlightName(_ name: String) -> Bool
    public static func sizeText(bytes: Int64) -> String                       // "48 MB", "1.2 GB"
}

/// mach host time ↔ seconds ↔ sample positions, with the timebase injected so tests are deterministic.
public struct HostClockMath: Sendable {
    public init(timebaseNumer: UInt32, timebaseDenom: UInt32)
    public func seconds(fromHostTime t: UInt64) -> Double
    public func samplePosition(hostTime t: UInt64, origin: UInt64, sampleRate: Double) -> Int64
}

/// Single-writer / single-reader float ring addressed by ABSOLUTE sample position (not a FIFO): a write
/// lands where its timestamp says; unwritten positions read as silence. This is what makes the mixer
/// indifferent to gaps, late buffers and device switches.
public struct AudioRing: Sendable {
    public init(capacityFrames: Int, channels: Int)
    /// Returns frames actually stored (positions older than the read cursor are dropped, counted in `dropped`).
    /// Writes within `tolerance` of `writeCursor` are appended contiguously (jitter → no click).
    public mutating func write(_ frames: UnsafeBufferPointer<Float>, channels: Int, at position: Int64, tolerance: Int) -> Int
    /// Reads `count` frames at `position` into `out` (zero-filled where nothing was written); returns frames that were real.
    public mutating func read(into out: UnsafeMutableBufferPointer<Float>, count: Int, at position: Int64) -> Int
    public var writeCursor: Int64 { get }
    public var dropped: Int64 { get }
}
// Tests: contiguous append within tolerance; gap → zeros; late write dropped; wraparound; mono-into-stereo dup.

public enum MixMath {
    /// out = clip(a + b, ±0.97) — the ChannelAudio.mixToMono idiom (ChannelAudio.swift:96-104), streamed. vDSP.
    public static func sumAndLimit(_ a: UnsafeBufferPointer<Float>, _ b: UnsafeBufferPointer<Float>, into out: UnsafeMutableBufferPointer<Float>)
}
```

### 3.2 KleothCapture — `app/Sources/KleothCapture/ScreenRecording/`
No `@available(macOS 14.4, *)` needed (package floor is 14.4, `app/Package.swift` platforms); only 15+ SCK
APIs would need `#available(macOS 15, *)` — this design uses none (§5.1). **Delete `ScreenshotCapture.swift`**
(dead: `grep -rn ScreenshotCapture app/Sources Sources` finds no caller; it is the only other SCK entry point
and carries its own error enum + `macOS 14.0` gate).

```swift
public struct ScreenRecordingTarget: Sendable, Equatable {
    public var displayID: CGDirectDisplayID
    /// Display-local, top-left-origin points (SCStream.h:269). nil = whole display.
    public var sourceRect: CGRect?
}

public struct ScreenRecordingConfiguration: Sendable {
    public var target: ScreenRecordingTarget
    public var outputURL: URL                 // the ".recording.mp4" URL
    public var captureMicrophone: Bool        // false when mic permission is denied
    public var fragmentInterval: TimeInterval? = ScreenRecordingDefaults.fragmentInterval
    public var firstFrameTimeout: TimeInterval? = ScreenRecordingDefaults.firstFrameTimeout
}

public enum ScreenRecorderEvent: Sendable {
    case firstFrame(hostTime: UInt64)
    case micStarted, micGapBegan(at: TimeInterval), micGapEnded(at: TimeInterval), micLost(String)
    case streamStopped(reason: String, systemInitiated: Bool)
    case writerFailed(String)
}

/// One session. Owns the SCStream, the mic engine, the mix pump, the writer, and three serial queues
/// (video, audio, writer). **`@MainActor`** — its public API is called from the controller; the SCK / tap /
/// writer callbacks run on the queues inside `@unchecked Sendable` sink objects (MovieWriter, VideoFrameGate,
/// AudioMixPump, MicrophoneSource) that only ever hop RESULTS back to the main actor. `finishWriting` is awaited
/// via its completion-handler form (never the synchronous one — AVAssetWriter.h:384). Fresh instance per session,
/// like Recorder.swift:24-44.
@MainActor public final class ScreenRecorder {
    public init(configuration: ScreenRecordingConfiguration)
    /// Resolves SCShareableContent (under KleothCore `withTimeout` 5 s — it can hang while the TCC dialog is up),
    /// builds the filter (§5.2) + stream configuration, opens the writer, starts capture, and returns after the
    /// first `.screen` sample of any status — or throws `ScreenRecorderError.noFirstFrame` after
    /// `firstFrameTimeout` (deleting the file). Throws `.userDeclined` for SCStreamErrorUserDeclined (-3801).
    public func start() async throws
    /// Idempotent. Stops the stream + mic, appends the retained last frame at the stop time (§5.3), flushes the
    /// mix pump, awaits `finishWriting`, renames to the final URL. Bounded by `finalizeTimeout`. Throws
    /// `.nothingCaptured` (file deleted) when zero video frames were appended.
    public func stop(reason: ScreenRecordingStopReason) async throws -> ScreenRecordingSummary
    public var events: AsyncStream<ScreenRecorderEvent> { get }
}

public enum ScreenRecorderError: Error, Sendable {
    case userDeclined, noDisplay, noFirstFrame, shareableContentTimedOut, selfNotInShareableContent,
         writerSetupFailed(String), writerFailed(String), alreadyStarted, nothingCaptured, finalizeTimedOut
}

/// Screen Recording TCC, mirrored on AccessibilityPermission.swift:12-47. Lives here so `screenrec` can use it.
public enum ScreenRecordingPermission {
    public enum State: Sendable, Equatable { case granted, notDetermined, deniedOrStale }
    public static func state(defaults: UserDefaults) -> State   // CGPreflightScreenCaptureAccess + the requested-at default
    @discardableResult public static func request(defaults: UserDefaults) -> Bool   // CGRequestScreenCaptureAccess, stamps the default
    public static let settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
}

/// H.264 settings next to AudioFormat.aacSettings (AudioFormat.swift:33-48).
public enum VideoFormat {
    /// §5.4 dictionary; averageBitRate from CaptureGeometry.videoBitRate(pixelSize:), peak = ×peakBitRateMultiplier.
    public static func h264Settings(pixelSize: CGSize, averageBitRate: Int) -> [String: Any]
}
```

Internal types (not public, but the implementer's map; each `@unchecked Sendable` with a documented
single-queue argument, the `TapWriter` / `RenderLevel` precedent in `AudioFormat.swift`):
- `MicrophoneSource` — own `AVAudioEngine` (third engine; two are proven to coexist,
  `DictationCapture.swift:55-60`), tap `bufferSize 2048` at the node's native format, per-buffer
  `AVAudioTime.hostTime` forwarded, `AVAudioConverter` → Float32 48 kHz stereo (mono duplicated) with a
  preallocated scratch (the `TapWriter` shape, `AudioFormat.swift:179-256`), `.AVAudioEngineConfigurationChange`
  → rebuild converter + reinstall tap (`DictationCapture.swift:399-422` shape). Emits `(frames, hostTime)` into
  the mic `AudioRing` on `audioQueue`. Can be started late (mic permission granted mid-session).
  `micOffsetCompensation` seeded from `inputNode.presentationLatency` + the constant.
- `SystemAudioSink` — the SCStream `.audio` output: wraps each CMSampleBuffer's ABL as Float32 non-interleaved
  (Apple sample idiom; Chromium's CHECK confirms planar float), reads `CMSampleBufferGetPresentationTimeStamp`
  (host clock), writes into the system `AudioRing` at the position that PTS implies.
- `AudioMixPump` — `DispatchSourceTimer` every 20 ms on `audioQueue`; emits the block ending at
  `now − mixLatency` from both rings via `MixMath.sumAndLimit`, as one interleaved Float32 stereo LPCM
  `CMSampleBuffer` (PTS = block start on the host clock) to the writer's audio input. Counts real-vs-silent
  mic frames to derive `MicGap`s. Never blocks: if `isReadyForMoreMediaData` is false the block is dropped + counted.
- `VideoFrameGate` — appends only `SCFrameStatus.complete` frames **and only when `pts > lastAppendedPTS`**
  (drop + count otherwise); retains the last appended frame; on stop appends a copy at the stop time
  (`CMSampleBufferCreateCopyWithNewTiming`). Also reports the FIRST `.screen` sample of any status (the
  stale-grant detector). Keepalive timer exists behind `keepaliveInterval` (nil = off) and obeys the same guard.
- `MovieWriter` — `AVAssetWriter(outputURL:, fileType: .mp4)`, `movieFragmentInterval` (when non-nil),
  `shouldOptimizeForNetworkUse = true`, video + audio inputs (`expectsMediaDataInRealTime = true`, set before
  `startWriting`), `startSession(atSourceTime:)` = the first video frame's PTS, audio blocks earlier than that
  are dropped; `finish()` via `finishWriting(completionHandler:)` bridged to async; rename on success.

**Do not touch** (72cca9a — the external-mic fix, meeting path not yet runtime-verified): `AudioFormat.aacSettings`
clamp, `openAACFile` retry, `TapWriter`, both `handleConfigurationChange()` implementations; `SystemAudioTap`'s
file path + teardown order; never a second tap on an existing engine's `inputNode`; never `Sendable` on
MicCapture/SystemAudioTap/DictationCapture; never `com.apple.security.app-sandbox` in the entitlements.

### 3.3 KleothPillUI — contract additions (`app/Sources/KleothPillUI/PillTypes.swift`)
The library keeps depending only on KleothCore (`app/Package.swift:35-43`): plain values (Date, String) cross
the seam. The `DictationPillPresenting` protocol is **unchanged** (`setResting(_ visible: Bool)` stays), so
`DictationController.swift:30` and the sandbox (`main.swift:241, :414`) compile as they are.

```swift
public enum DictationPillState {          // + cases; every exhaustive switch listed in §6.1 gains them
    /// Screen recording in flight — the pill's BACKDROP while it runs (never tucked). `since` is fixed for
    /// the session so re-shows compare equal (no spurious re-transition / beat / announce). Digits come from
    /// `TimelineView(.periodic(from: since, by: 1))` in the view — no per-second show(). (graft 9)
    case recording(since: Date)
    case saving            // finalize in flight (≤ 5 s): same capsule as .recording, travelling wave
    case saved(String)     // "2:14 · 48 MB": green check + text, autoHideAfter 4 s, click = reveal
}
// autoHideAfter: .saved → .seconds(4); .recording/.saving → nil.   showsText: .saved → true; .recording/.saving → false.

/// What the pill collapses to when no phase is live. Generalizes `restingVisible: Bool`.
public enum DictationPillBackdrop: Equatable, Sendable {
    case hidden, idle, recording(since: Date)
    public var state: DictationPillState?     // nil / .idle / .recording(since:)
}

public enum DictationPillFault {          // + cases
    case screenRecordingNeeded   // text "Allow Screen Recording, then quit and reopen Kleoth", action .openScreenRecordingSettings
    case screenRecordingStale    // text "Quit and reopen Kleoth to finish enabling Screen Recording", action .openScreenRecordingSettings
}
public enum DictationPillAction {         // + cases (title "" for the tap-only ones; "Open Screen Recording" for the button)
    case startScreenRecording, stopScreenRecording, revealLastRecording, openScreenRecordingSettings
}

// DictationPillController (public, NOT on the protocol — the PillCoordinator holds the concrete type):
public func setBackdrop(_ backdrop: DictationPillBackdrop)   // setResting(_:) becomes setBackdrop(visible ? .idle : .hidden)
public var currentState: DictationPillState { get }          // model.phase — the coordinator's "is a dictation phase live?" input
```
`DictationPillController`: `restingVisible: Bool` (`:75`) → `backdrop: DictationPillBackdrop`;
`dismiss()`/`collapseToResting()` (`:165-193`) show `backdrop.state` (`.idle` / `.recording`) or
`hideCompletely()`; `setBackdrop` mirrors `setResting`'s guard (`:182`): takes over only when the phase is
`.hidden`, `.idle` or `.recording` — never a live phase — and otherwise just stores the value for the next
`dismiss()`. `origin(for:)` (`:710-716`) still tucks only `.idle`, so `.recording` sits fully on the anchor.

### 3.4 KleothApp — `app/Sources/KleothApp/ScreenRecording/`

```swift
/// The ONE owner of the pill instance. DictationController and ScreenRecordingController each get a face;
/// the coordinator merges backdrops and fans out actions. Dictation phases are foreground; recording is backdrop.
@MainActor final class PillCoordinator {
    static let shared: PillCoordinator                 // built on first access from KleothApp's @StateObject inits (main actor)
    let pill: DictationPillController                  // real instance (was inline at DictationController.swift:121)
    /// Handed to DictationController's designated init as `pill:`. Conforms to DictationPillPresenting:
    /// forwards show/dismiss/setLevel/resetPosition; `setResting(v)` → `dictationWantsResting = v; recompute()`;
    /// its `onAction`/`onDismiss` setters store the dictation handlers the fan-out calls.
    var dictationFace: any DictationPillPresenting { get }
    /// Recording side.
    func setRecordingBackdrop(since: Date?)                         // non-nil → .recording(since:) outranks .idle; recompute()
    func showRecordingPhase(_ state: DictationPillState)            // .saving / .saved / .warning / .failed — applied now if no
                                                                    // dictation phase is live; a .saved is queued (≤ 10 s) else dropped
    func dismissRecordingPhase()                                    // pill.dismiss() iff currentState is .saved/.saving/a recording fault
    var isDictationPhaseLive: Bool { get }                          // currentState ∈ armed/listening/transcribing/polishing/done,
                                                                    // or warning/failed last shown by the dictation face
    var onRecordingAction: ((DictationPillAction) -> Void)?         // start/stop/reveal/openScreenRecordingSettings
    // internal: pill.onAction fan-out — .openSettings/.openAccessibilitySettings → dictation handler; the four
    //           recording cases → onRecordingAction. pill.onDismiss → dictation handler if the dictation face showed
    //           the current state, else clears a queued .saved. After every forwarded dictation dismiss(): show a queued .saved.
    // recompute(): backdrop = recordingSince.map { .recording(since: $0) } ?? (dictationWantsResting ? .idle : .hidden); pill.setBackdrop(backdrop)
}

@MainActor final class ScreenRecordingController: ObservableObject {
    private(set) static var shared: ScreenRecordingController?
    @Published private(set) var machineState: ScreenRecordingSessionMachine.State
    @Published private(set) var lastSummary: ScreenRecordingSummary?
    @Published private(set) var lastStopDetail: String?           // "Stopped: display disconnected", "mic dropped 1.2 s at 3:12", "Recovered a screen recording"
    @Published private(set) var permissionState: ScreenRecordingPermission.State
    var isActive: Bool { machine.isActive }                        // pill backdrop + menu-bar glyph + quit guard + popover row
    var since: Date? { machine.since }                             // popover TimelineView digits
    enum Origin { case pill, popover }
    convenience init()                                             // coordinator: PillCoordinator.shared; sets shared
    init(coordinator: PillCoordinator, defaults: UserDefaults)
    func start(from: Origin)          // preflight → picker → pill .recording → recorder.start(); every failure → sticky fault (§7)
    func stop()                       // user stop
    func revealLast()                 // NSWorkspace.activateFileViewerSelecting
    func copyLastPath()               // NSPasteboard.general
    func openRecordingsFolder()       // Settings button; creates the folder if missing
    func refreshPermission()          // 1 Hz from Settings, and on didBecomeActive
    func startIfNeeded()              // launch: sweep *.recording.mp4 → -recovered / trash; refreshPermission()
    /// Quit path: returns false immediately when nothing records; otherwise begins stop(.quit) and calls
    /// `completion` on the main actor when finalized or after finalizeTimeout. Synchronous entry (assumeIsolated).
    func beginTerminationStop(completion: @escaping @MainActor () -> Void) -> Bool
}

/// One transparent overlay window per display; returns the chosen target or nil.
@MainActor final class RegionPicker {
    struct Choice: Equatable { var displayID: CGDirectDisplayID; var displayFrame: CGRect; var globalRect: CGRect? }
    func pick() async -> Choice?       // nil = cancelled (Esc / ⌘. / lost key status)
}
```
Wiring: `KleothApp.swift:17-18` adds `@StateObject private var screenRecording = ScreenRecordingController()`
and injects it into **all four** scenes (`:22-25, :40-44, :50-54, :58-62`). `DictationController.convenience
init()` (`:117-129`) passes `PillCoordinator.shared.dictationFace` instead of `DictationPillController()`.
`AppDelegate` adds `applicationShouldTerminate`, calls `ScreenRecordingController.shared?.startIfNeeded()`
from `applicationDidFinishLaunching` (`AppWiring.swift:70` neighbourhood) and `refreshPermission()` from the
existing `didBecomeActive` observer (`:74-80`) — all via `MainActor.assumeIsolated`, synchronous bodies.
**No** `Settings` field, Keychain key, or `AppConfig` line (graft 5). `SettingsScreenRecordingSection` mounted
after `SettingsDictationSection` in `SettingsView.swift:102-116`: permission row (state + Open System
Settings), "Open Recordings Folder", footer with the monthly-re-consent + Bluetooth notes. Non-secret state
(`permissionRequestedAt`) lives in UserDefaults (`DictationPillController.swift:38-41` precedent).
Probe target `screenrec` (`app/Sources/screenrec/main.swift`, depends on KleothCapture + KleothCore, like
`dictate`): `screenrec <seconds> [--display N] [--region x,y,w,h] [--no-mic] [--out file] [--inspect file]`
prints permission state, resolved pixel size + bitrate, frames appended/dropped, audio blocks, mic gaps,
duration (AVURLAsset), size, MB/min. It is the MB/min, sync and mixer harness — NOT the TCC spike: any
binary exec'd from a shell is TCC-attributed to the shell (responsible process), wherever it lives. The TCC
spike is the release app's own popover row (§8 #0).

---

## 4 Audio design

### 4.1 The clock problem, and the choice that removes it
Kleoth's meeting stack has **no timestamps**: `SystemAudioTap`'s IOProc discards `inInputTime`
(`app/Sources/KleothCapture/SystemAudioTap.swift:227`, the block's first param is `_`), `MicCapture`'s tap
discards `AVAudioTime` (`MicCapture.swift:82-92`), and mixing is whole-file offline
(`ChannelAudio.mixToMono`, `ChannelAudio.swift:49-122`). The mic and the aggregate-device tap are
independent clocks that may differ in rate (`ChannelAudio.swift:34-41`). Synthesizing PTS from frame counts
would drift against SCK's host-clock video PTS over a long recording.

**Decision — system audio comes from SCStream (`capturesAudio`), not from a second `SystemAudioTap`:**
1. SCK audio and video PTS share the host clock (`SCStream.synchronizationClock`, `SCStream.h:453`;
   Nonstrict starts the writer at `CMClock.hostTimeClock`), so **video ↔ system audio need no alignment**.
2. `SystemAudioTap` would have to forward `inInputTime` and its no-copy `AVAudioPCMBuffer` is valid only inside
   the callback (`SystemAudioTap.swift:227-256`) — two API changes to code that is hours old (commit 72cca9a)
   and not yet runtime-verified for the meeting path.
3. Two concurrent process taps are **unprobed**. SCK audio is a different subsystem, so a meeting's tap and the
   screen recording never touch.
4. `excludesCurrentProcessAudio = true` (`SCStream.h:310`) mirrors the tap's exclude-self, so Kleoth's own
   chime/player never leaks in (same caveat as meetings: demoing Kleoth itself is silent — documented).

**Microphone comes from a third `AVAudioEngine` input tap with `AVAudioTime.hostTime` forwarded** — one
path on every OS. Not `SCStreamConfiguration.captureMicrophone` (15.0, `SCStream.h:360`): Apple DTS states its
mic buffers arrive with a different `CMFormatDescription` **on an independent clock** that must be offset
manually, and writing both SCK audio types into one input corrupts the container (forums 805892). That is the
exact problem this design is built to avoid, and it would leave 14.4 on a second path anyway.
`AVAudioTime.hostTime` is `mach_absolute_time` — the host clock (Apple forums 651388/68611; Nonstrict).

### 4.2 Sources → rings (all on `audioQueue`, serial, `.userInteractive`)
| Source | Arrives as | Rate/format | Timestamp | Into ring at |
|---|---|---|---|---|
| SCStream `.audio` | `CMSampleBuffer`, Float32 planar, 2 ch (Apple sample; Chromium CHECK) | 48 kHz stereo by config (`SCStream.h:300/305`) | `CMSampleBufferGetPresentationTimeStamp` (host) | `HostClockMath.samplePosition(pts, origin, 48k)` |
| `MicrophoneSource` tap | `AVAudioPCMBuffer`, node native (Float32 planar, 1–2 ch, 16–48 kHz — a Sony XM5 HFP mic is 16 kHz mono, `AudioFormat.swift` comment) | converted to 48 kHz stereo (mono dup) by `AVAudioConverter` | `AVAudioTime.hostTime` of the buffer's first frame (converter output position = input position × ratio) − `micOffsetCompensation` | same |

`origin` = the host time of the first appended video frame (writer session start). Both rings are
`AudioRing`s of 2 s. Writes within `mixAlignToleranceFrames` (2 ms) of the ring's write cursor are appended
contiguously (kills clicks from timestamp jitter); larger jumps land where the timestamp says (gap → silence,
late → dropped + counted). A late-attaching mic (permission granted mid-session, device restart) simply starts
writing at the right position.

### 4.3 One track: the pull-based `AudioMixPump`
A `DispatchSourceTimer` (20 ms) emits the 960-frame block ending at `now − mixLatency` (250 ms): read both
rings at that position, `MixMath.sumAndLimit` (±0.97 clip — the `ChannelAudio.swift:96-104` idiom), one
interleaved Float32 stereo LPCM `CMSampleBuffer` with PTS = block start → `AVAssetWriterInput.append` on
`writerQueue` if `isReadyForMoreMediaData` (else the block is counted as dropped — never blocks the timer).
Why pull, not push: **either source can stop** (SCK may deliver nothing while the system is silent on some
versions, the mic disappears on unplug) and the track must still be continuous and in sync; the pump makes
silence explicit and cheap. 250 ms of audio latency is invisible to the writer — `expectsMediaDataInRealTime`
inputs interleave by PTS — and never affects A/V sync because audio PTS are real host times.
Mic vs system real-frame counts per block drive `MicGap` detection (gap ≥ 0.5 s → reported, §2.7).
Loudness: no AGC in v1 (deferred, §9). The limiter prevents the clipping the meeting mic showed before
normalization (CLAUDE.md 2026-07-22: mic peaks 6.1× full scale) from becoming hard clicks; per-source gain
stays 1.0.

### 4.4 Sample formats end to end
Mix bus = Float32 interleaved stereo 48 kHz. AAC input settings = `AudioFormat.aacSettings(sampleRate: 48_000,
channels: 2, bitRate: 128_000)` (`AudioFormat.swift:33-48` — the clamp via `maxAACBitRate` is kept in the path
so a future "mic-only" mode on a 16 kHz device cannot reproduce the `!dat` failure of 72cca9a). No scratch
files: `.m4a` names in `screen-recordings/` would surface the folder as an Untranscribed meeting
(`RecordingController.swift:1623-1630`).

### 4.5 Sync budget and how it is measured
- Video ↔ system audio: same clock, no offset by construction. Verified by §8 #14 (metronome video: flash
  and click within one frame at 30 fps = 33 ms).
- Mic ↔ system: host-clock stamped on both sides; expected residual = input device latency (`AVAudioEngine`
  input latency, typically 5–20 ms built-in, up to ~150 ms Bluetooth HFP). Verified by §8 #15 (speaker click
  heard by the mic trails the system copy by a constant < 60 ms wired / < 200 ms BT and does **not drift**
  over 10 min). `micOffsetCompensation` (default 0, plus `inputNode.presentationLatency`) is the only knob if
  measurement shows a bias.

### 4.6 Interplay with a concurrent meeting recording
| Resource | Meeting (`Recorder`) | Screen recording | Shared? |
|---|---|---|---|
| System audio | Core Audio process tap, private aggregate device (`SystemAudioTap.swift:189-207`) | SCStream `.audio` | no |
| Mic | `MicCapture`'s own `AVAudioEngine` (`MicCapture.swift:13-14`) | `MicrophoneSource`'s own engine | same device, separate engines (two proven; three = meeting + dictation + screen is the extrapolation — §8 #11) |
| Encoder | AVAudioFile AAC | AVAssetWriter H.264 + AAC | no |
| Files | `~/Kleoth/meeting-…/` | `~/Kleoth/screen-recordings/` | no |
| Controller | `RecordingController` | `ScreenRecordingController` | none; each reads `AppConfig.settings()` |
Consequences stated: the meeting's `mic.m4a` also hears anything said during the screen recording (already
true for dictation); Bluetooth HFP is entered by whichever opens the mic first.

---

## 5 Video / encode design

### 5.1 API choice — SCStream + AVAssetWriter, one path, floor unchanged
- Everything needed exists at 14.4: `SCStream`/`SCContentFilter`/`SCStreamConfiguration` (12.3),
  `.audio` (13.0), `sourceRect`, `includeMenuBar` (14.2), `pointPixelScale` (14.0) — `SCStream.h` refs in the
  research file. No floor change; nothing to gate.
- **Not `SCRecordingOutput`** (15.0): its configuration exposes only `outputURL`, `videoCodecType`,
  `outputFileType` (`SCRecordingOutput.h`) — no bitrate, fps, dimensions or audio keys; file size is the user's
  #1 complaint; it stops when the configuration is updated; forum 803050 reports blurry/low-bitrate output;
  and it would still leave 14.4 on a second path.
- **Not `SCContentSharingPicker`**: no region mode (`SCContentSharingPicker.h:19-25`).
- Hardware encode is the VideoToolbox default (`kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder`
  "true by default", `VTCompressionProperties.h:788`); the spec key is passed explicitly anyway;
  `Require…` (`:807`) is **not** set — a software fallback beats a failed recording.

### 5.2 Stream configuration
- **Filter: `SCContentFilter(display:excludingApplications:[kleoth], exceptingWindows: [])`** (`SCStream.h:180`,
  Apple's sample idiom; graft 4) where `kleoth` = the `SCRunningApplication` in
  `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).applications` whose
  `bundleIdentifier == Bundle.main.bundleIdentifier`. Excludes the pill, the picker overlays, and any Kleoth
  window — including ones created AFTER `startCapture` (the filter is by owning process). **Ordering written
  down:** the controller shows `.recording` on the pill BEFORE `recorder.start()`, so at least one Kleoth window
  (the pill panel; the status item's window is always there too) is in the snapshot. If Kleoth is still not in
  `applications`, fall back to `excludingWindows:` = every `SCWindow` whose `owningApplication?.processID ==
  getpid()` and log it; if that set is also empty, throw `.selfNotInShareableContent` (never record with the
  indicator in frame). A bare `screenrec` (no bundle id) skips the exclusion. Consequence (written down): a
  user cannot demo Kleoth's own History/Settings in a recording — per-window exclusion is the §9 follow-up.
  `includeMenuBar` left default (YES for display filters, `SCStream.h:124`).
- `sourceRect` = `CaptureGeometry.sourceRect(fromGlobal:displayFrame:)` (points, display-local, top-left,
  `SCStream.h:269`); nil for whole display.
- `width/height` = `CaptureGeometry.outputPixelSize(sourcePoints, filter.pointPixelScale (SCStream.h:114), 1920)` —
  even, aspect kept; a 5K/6K display downscales to 1920 on the long edge (also dodges AVAssetWriter's
  4096×2304 crash, Nonstrict). `preservesAspectRatio` default YES (`:244`).
- `minimumFrameInterval = CMTime(1, 30)` (`:222`); `queueDepth = 6` (≤ 8, `:279`); `showsCursor = true`
  (`:254`); `pixelFormat = 'BGRA'`: correctness first — BGRA has no color-matrix tagging to get wrong (forum
  803050's washed colors), is what `showMouseClicks` would need later (`:259`), and the RGB→YUV pass is inside
  VideoToolbox on Apple Silicon. `colorSpaceName` left unset. §8 #13 checks color by eye; switching to `420v`
  + `colorMatrix` 709 is a one-line follow-up if CPU matters.
- Audio: `capturesAudio = true`, `sampleRate = 48000`, `channelCount = 2`, `excludesCurrentProcessAudio = true`
  (`SCStream.h:295-310`).
- Outputs: `.screen` on `videoQueue`, `.audio` on `audioQueue` (Apple sample uses separate serial queues).

### 5.3 Frame rules (`VideoFrameGate`)
- Append only `SCFrameStatus.complete` (attachment `SCStreamFrameInfo.status`, `SCStream.h:395`, statuses
  `:44-51`) — Apple's sample does the same; `.idle/.blank/.suspended/.started/.stopped` are dropped and counted.
  The FIRST `.screen` sample of ANY status resolves `start()`'s first-frame wait (stale-grant detector).
- **Monotonic PTS guard**: every append requires `pts > lastAppendedPTS`; otherwise drop + count. (graft 10)
- Writer session starts at the **first appended frame's PTS**; audio blocks with PTS earlier are discarded.
- **Stop-time re-append**: SCK emits frames only when the screen changes; a static screen ends the movie at
  the last change (Nonstrict). At stop a copy of the retained last frame is appended at the stop time
  (`CMSampleBufferCreateCopyWithNewTiming`) so video length == audio length. Between changes the track simply
  has no samples (players hold the last frame). `keepaliveInterval` (nil) can turn on a periodic re-append that
  obeys the same PTS guard if §8 #19 shows a 60 s static stretch scrubbing badly.
- Backpressure: if `isReadyForMoreMediaData` is false the frame is dropped (counted), never queued — the
  encoder is real-time (`expectsMediaDataInRealTime`, `AVAssetWriterInput.h:167-174`).

### 5.4 Encoder settings (`VideoFormat.h264Settings`)
```
AVVideoCodecKey: .h264                                  // 'avc1', AVVideoSettings.h:44 — Slack/browser-safe
AVVideoWidthKey / AVVideoHeightKey: even, ≤1920 long edge (:65)
AVVideoCompressionPropertiesKey:
  AVVideoAverageBitRateKey: CaptureGeometry.videoBitRate(pixelSize)   // 3_000_000 at 1080p, area-scaled, ≥ 1_000_000 (:193)
  kVTCompressionPropertyKey_DataRateLimits: [average × 2 / 8 bytes, 1 s]   // peak ≤ 2× average (HLS rule); VT keys may be mixed in (:188)
  AVVideoProfileLevelKey: H264HighAutoLevel             // :212/:227
  AVVideoExpectedSourceFrameRateKey: 30                 // required with AutoLevel (:245-247)
  AVVideoMaxKeyFrameIntervalDurationKey: 2              // :196 — seekable, cheap for static content
  AVVideoAllowFrameReorderingKey: false                 // :206-210 "may yield the best results" for real-time
AVVideoEncoderSpecificationKey: [EnableHardwareAcceleratedVideoEncoder: true]   // :281, VTCompressionProperties.h:788
```
Audio: AAC-LC 48 kHz stereo 128 kbps (Loom: AAC 48 kHz up to stereo).
**Expected size**: 3 Mbps video = 22.5 MB/min; 128 kbps audio = 0.96 MB/min ⇒ **≈ 23.5 MB/min ceiling at
1080p** (peak-limited to 6 Mbps ⇒ never above 46 MB/min in a burst). Region examples on a 2× Retina display:
1280×720 pt → 2560×1440 px → capped to 1920×1080 → 3 Mbps; 960×540 pt → 1920×1080 px (no cap) → 3 Mbps;
640×360 pt → 1280×720 px → 1.33 Mbps ≈ 10 MB/min (area-scaled). Screen content is mostly static, so VBR
undershoots: expect **8–15 MB/min** on typical narration over an IDE/browser. Sources: 1080p30
screen-recording guides converge on 3–6 Mbps (vid-crush; OBS guides) — screen content is low-motion so the low
end is chosen; YouTube's 8 Mbps 1080p30 is the camera-content upper bound; Loom's desktop settings are H.264,
target 30 fps, VBR, AAC 48 kHz. For contrast, CleanShot's native-Retina default runs to > 400 MB per 5 min
(≈ 80 MB/min, screenkite) — the QuickTime-sized files the user hand-compresses today; a 5-minute 1080p Kleoth
recording ≈ 118 MB worst case, ~3.4× smaller. **Verified by §8 #12** (5-minute real recording, target
≤ 25 MB/min; the checklist says when to drop to 2.5 Mbps).

### 5.5 Container and crash safety
`AVAssetWriter(fileType: .mp4)` with `movieFragmentInterval = 10 s` (`AVAssetWriter.h:423`) and
`shouldOptimizeForNetworkUse = true` (graft 2): a fragmented MP4 whose every completed 10 s survives a crash,
SIGKILL, SIGTERM or power loss; `finishWriting` closes it normally. The launch sweep (§2.5) renames leftovers
to `-recovered.mp4`. **Risk stated**: fMP4 is valid ISO-BMFF and plays in QuickTime/Chrome/Safari, but some
sharing targets' inline players prefer a single `moov`. §8 #16 plays the file in QuickTime, Chrome, Slack,
Telegram and iMessage; if any target refuses it, `fragmentInterval` flips to `nil` (one constant) — the file
is then moov-at-front thanks to `shouldOptimizeForNetworkUse`, the quit path relies solely on
`.terminateLater`, and a crash loses the whole recording (recorded as the trade-off either way). No re-encode,
no remux pass in v1.

---

## 6 Pill integration

### 6.1 Contract delta (exact) and why each shape
- **`.recording(since: Date)` carries the session's fixed start.** `transition(to:phase:capsule:)` computes
  `reshapes` as `model.phase != phase || capsuleSize != capsule` (`DictationPillController.swift:543`); because
  `since` never changes within a session, every re-show (after each dictation `dismiss()`) compares equal and
  fires no spring / `MotionBeat` / `layout()` / `announce()`. The view renders
  `TimelineView(.periodic(from: since, by: 1)) { Text(ElapsedFormatter.string(seconds:)).monospacedDigit() }`
  in a **fixed 56 pt frame** (fits `1:02:34` in caption monospaced) so the capsule never re-measures. Costs
  nothing while idle (the `TimelineView` is mounted only in `.recording`, like `Waveform`'s). (graft 9)
- **Sizes** (graft 7): `capsuleHeight(.recording) = capsuleHeight(.saving) = 28` (between resting 22 and motion
  32 — "resting family, but alive"; the sandbox film decides between 26/28); `.saved(String)` = **32** (the
  motion thickness, so the text confirmation is ONE morph). `layout(.recording)` = `layout(.saving)` length =
  8 (dot) + spacingS + digit box 56 + 2 × compactPadding 14 = **100 pt ≤ the hands-free listening capsule
  (~110 pt)**, so the single anchor's `referenceSize` (`:646-652`) still covers it and no per-phase clamping
  creeps near a corner. `.saved(String)` is measured like `.warning` (`:838-847`, `.callout` medium + 20 icon +
  paddings ≈ 140 pt for "2:14 · 48 MB") and capped by `labelCap`; being LONGER than the reference it CAN be
  nudged per phase near a corner by `activeOrigin` (`:678-683`) — the same accepted nudge every existing
  `.warning` gets, for 4 s. Honest, not "no creep".
- **`.armed` on a `.recording` backdrop** (graft 6): `show()` resolves an *effective layout state* — `.armed`
  while `backdrop` is `.recording` lays out as `.recording` (same 28×100 capsule; content = the mic glyph) so the
  capsule does not shrink to 68×22 for `minHold` 0.2 s and bloom back. `layout(for:edge:on:)` gains an
  `effective:` resolution step in `show()`; the static `layout` itself is unchanged. Film (§6.5) decides.
- **Every exhaustive switch gains the cases**: `PillTypes.swift` `autoHideAfter`/`showsText`;
  `DictationPillController` `capsuleHeight` (`:785-791`), `layout` (`:823-857`), `pillText` (`:892-905`:
  "Recording the screen — click to stop" / "Saving the recording…" / the saved text), `symbolName`
  (`:908-917`), `announce` skip list (`:875-885` — add `.recording` and `.saving`; the controller posts ONE
  `NSAccessibility` announcement "Screen recording started"; `.saved` announces itself);
  `DictationPillView` `content` (`:206-278`), rim/sheen/opacity conditions (`:106-124` — `.recording` gets the
  hairline rim, **no** resting sheen/opacity); `pillsandbox` `pillState(named:)`/`phaseName` (`main.swift:60-88`);
  `DictationController.handlePillAction` (`:812-827`) gains the four new cases as `break` (the coordinator never
  forwards them there) and its unconditional `pill.dismiss()` (`:826`) stays for the dictation cases only.
  **NOT** `isSticky` — it is an `if case .failed` (`:921-924`), compiles unchanged.
- **Backdrop precedence** (`PillCoordinator.recompute()`):
  `backdrop = recordingSince.map { .recording(since: $0) } ?? (dictationWantsResting ? .idle : .hidden)`.
  `pill.setBackdrop(backdrop)` — the pill controller applies it now if no phase is live, else at the next
  `dismiss()`. Hence: recording starts while idle → `.idle → .recording` (`.rise` cue: content hidden 0.08 s
  then blooms — the existing cue expression at `:551-554` treats any non-idle/armed destination as active);
  recording stops while idle → `.recording → .saving → .saved → .idle` (`.morph`, `.morph`, `.sink`); a dictation
  ends mid-recording → `.done → .recording` (`.morph` in place, same anchor); recording stops **while a
  dictation phase is live** → nothing visible changes until the dictation's `dismiss()`, which lands on
  `.idle`/`.hidden`, and the queued `.saved` is shown then (§2.4).

### 6.2 State table — coexistence with dictation phases
| Situation | Pill shows | Backdrop stored |
|---|---|---|
| nothing, dictation off | hidden | `.hidden` |
| dictation armed (monitors on) | `.idle` (tucked) | `.idle` |
| hover on `.idle` | peek: mic + record glyphs | — |
| recording, no dictation | `.recording` (dot + digits; hover → stop glyph) | `.recording(since:)` |
| recording + fn+shift | `.armed` (recording-sized) `→ .listening → … → .done` morphing in place | `.recording(since:)` |
| dictation `.failed` sticky while recording | `.failed` (user dismisses → `.recording`) | `.recording(since:)` |
| recording stops while dictation live | dictation phase continues; `.saved` queued | `.idle`/`.hidden` |
| recording, dictation disabled in Settings | `.recording` stays (backdrop rule) | `.recording(since:)` |
| recording ends, dictation off | `.saving → .saved → hidden` | `.hidden` |
| "Refuse while busy" dictation warning (`:539-549`) | unchanged — restores the pipeline phase, not the backdrop | `.recording(since:)` |

### 6.3 Visibility precedence — decision record
Pill visible ⇔ `isMonitoring || screenRecording.isActive`. Reason (data): the only pill visibility path today
is dictation's (`DictationController.swift:27-31`); the ask puts the start control on the pill; a hot mic must
have an indicator. Existing installs see no change until they record. A resting pill for dictation-off users
(a Settings toggle) is a product decision for the user (§9).

### 6.4 Click routing
`DictationPillView.swift:77-79` `.onTapGesture` becomes a switch: `.failed` → `dismissFromUser()` (as today);
`.idle where model.peeking` → `perform(.startScreenRecording)`; `.recording` → `perform(.stopScreenRecording)`;
`.saved` → `perform(.revealLastRecording)`; default → nothing. The record glyph itself is also a `Button`
(buttons already coexist with the drag gesture, `:301-316`), so both the glyph and the capsule start; the mic
glyph stays inert (click-to-hands-free remains unwired — CLAUDE.md). `DragGesture(minimumDistance:)` is
raised 3 → **6** for forgiveness (a jittery click on a start/stop control must not re-dock the pill); §8 #7
checks drag still works. `perform` (`:314-316`) → `onAction` → `PillCoordinator` fan-out →
`ScreenRecordingController`. The chord machine is never touched (recording is independent; CLAUDE.md's "click
on the peeking pill not wired — needs a controller path that keeps the chord machine in sync" is answered by
*not* going through `DictationController.handle(event)` at all). `acceptsFirstMouse` (`DictationPanel.swift:89`)
makes the first click land while Kleoth is inactive.

### 6.5 Sandbox additions and how to film it
`pillsandbox` (`app/Sources/pillsandbox/main.swift`): names `recording`, `saving`, `saved` in
`pillState(named:)`/`phaseName` (`recording` → `.recording(since: filmStart)` — ONE date per run so re-shows
compare equal); `--backdrop hidden|idle|recording` (film mode calls `setBackdrop` at `:241`/`:414`; default
`idle` keeps today's behavior); a ControlPanel row with Recording / Saving / Saved buttons and a "Recording
backdrop" toggle. Sequences to film and read (`frames.tsv` + `sheet.png` via the Read tool):
- `--edge bottom --backdrop recording --sequence idle,recording,armed,listening,transcribing,done,recording,saving,saved,idle`
  — checks: `.recording` is centered on the anchor (never half off-screen); `recording→armed` keeps the capsule
  size (graft 6) — compare against a run with the inheritance disabled; `done→recording` is a **morph** (panel
  frame does not move in `frames.tsv`); `recording→saving` is content-only; `saving→saved` is one reshape;
  `saved→idle` is a **sink**.
- `--edge right --fraction 0.3 --backdrop recording --sequence recording,listening,recording` — side-edge
  rotation of dot + digits (rotated by `-edgeRotation` like the mic glyph) and no creep of the panel origin.
- `--edge bottom --backdrop recording --sequence recording,peek,unpeek` — `setHovered` drives `model.hovered`
  (`handleHover :365`), so the stop-glyph swap is visible in the film even though the sandbox cannot click.
- `--edge bottom --sequence idle,peek,unpeek` — the record glyph next to the mic while peeking.
Build: `swift build --package-path app --product pillsandbox && app/.build/debug/pillsandbox --film <dir> …`.

---

## 7 Error matrix
| # | Condition | Detected where | User sees | File | Log row / detail |
|---|---|---|---|---|---|
| 1 | Screen Recording never asked | `ScreenRecordingPermission.state == .notDetermined` | system prompt, then sticky `.failed(.screenRecordingNeeded)` + Open Screen Recording Settings | none | — |
| 2 | Denied / granted-but-not-relaunched (preflight false) | `.deniedOrStale` | sticky `.failed(.screenRecordingNeeded)`; Settings row red | none | — |
| 3 | Preflight true but no `.screen` sample in 5 s (stale grant) or `-3801` | `ScreenRecorderError.noFirstFrame` / `.userDeclined` | sticky `.failed(.screenRecordingStale)` + Open Screen Recording Settings | `.recording.mp4` deleted | detail "Screen Recording needs a relaunch" |
| 4 | `SCShareableContent` hangs (TCC dialog up) | `withTimeout` 5 s → `.shareableContentTimedOut` | `.failed(.message("Screen Recording did not respond — try again after allowing it"))` | none | — |
| 5 | Mic permission denied | `AVCaptureDevice.authorizationStatus == .denied` | record without mic; `.warning` 3 s then `.recording` | video + system audio | detail "No microphone (permission denied)"; `micCaptured: false` |
| 6 | Free disk < 500 MB | `volumeAvailableCapacityForImportantUsage` | `.failed(.message("Not enough free disk space to record"))` | none | — |
| 7 | Start while already active (popover + pill race) | machine rejects `.startRequested` (nil effect) | `.warning("Already recording")` 1 s then `.recording` (the `refuseWhileBusy` idiom, `DictationController.swift:539-549`) — only if no dictation phase is live | — | — |
| 8 | Region picker cancelled (Esc / ⌘. / focus lost) | `RegionPicker.pick() == nil` | pill sinks to backdrop | none | — |
| 9 | Region < 64 pt | `CaptureGeometry.region` nil | picker treats the click as "whole display" (the hint says so) | — | — |
| 10 | Display id vanished between pick and start | `SCShareableContent` lookup | `.failed(.message("That display is no longer available."))` | none | — |
| 11 | Kleoth not in the shareable-content snapshot AND no own windows found | `.selfNotInShareableContent` | `.failed(.message("Couldn't hide Kleoth's own windows from the recording — try again"))` | none | logged; never records with the indicator in frame |
| 12 | Display disconnected / sleep / lock mid-recording | `didStopWithError` (14.4) / `-3821` (15+) | `.saving → .saved` | finalized normally | detail "Stopped: the display disconnected" |
| 13 | Writer fails mid-run (disk full, I/O) | `AVAssetWriter.status == .failed` on append | `.failed(.message("Recording failed: <≤140 chars>"))` sticky | fragments up to failure kept as `-recovered.mp4` | `os.Logger(subsystem: "dev.kleoth", category: "ScreenRecording")` gets the full error |
| 14 | Zero video frames appended at stop | `.nothingCaptured` | `.failed(.message("Nothing was recorded."))` | deleted | — |
| 15 | Mic device change / BT flip | `.AVAudioEngineConfigurationChange` | nothing (gap zero-filled) | continuous | detail lists gaps ≥ 0.5 s |
| 16 | Mic engine cannot restart | `MicrophoneSource` restart throws | recording continues; at stop `.warning("Saved — the microphone dropped out at m:ss")` | complete, mic silent after | detail |
| 17 | Quit mid-recording (⌘Q / popover / logout) | `applicationShouldTerminate` | `.saving`; app exits after finalize or 5 s | finalized (or fragments) | popover row on next launch shows the file |
| 18 | `kill -TERM` / `kill -9` / crash mid-recording | launch sweep finds `*.recording.mp4` | popover "Recovered a screen recording" row | `-recovered.mp4` (≥ 1 fragment) or trashed | — |
| 19 | Output folder unwritable / moved | `createDirectory` throws at start | `.failed(.message("Can't write to <folder>"))` | none | — |
| 20 | Dictation chord while `.saving` | dictation proceeds normally | `.saving → .armed …`; `.saved` queued | — | — |
| 21 | Recording stopped while a dictation phase is live | coordinator | `.saved` NOT shown over the live phase; queued ≤ 10 s, shown after the dictation's `dismiss()` | finalized | popover row updates immediately |
| 22 | Recording start fault while a dictation phase is live | coordinator | fault dropped from the pill; `lastStopDetail` carries it | none | — |
| 23 | Monthly re-consent alert (15+/26) | system dialog before `SCShareableContent` returns | help text warned; if declined → row 3 path | none | — |
| 24 | `finishWriting` exceeds 5 s | `finalizeTimeout` → `.finalizeTimedOut` | `.warning("Saved with a delay")`, file checked on next launch by the sweep | fragmented file | — |
| 25 | Bluetooth headset flips A2DP → HFP when the mic engine opens | Core Audio | the user's own playback drops to 16 kHz mono for the recording | mic lane resampled 16 k → 48 k; system lane unaffected | same as a meeting today (72cca9a); documented, not fixed |

---

## 8 Manual verification checklist
Prereq: `bash app/setup-signing.sh` once; `bash app/make-app.sh release`; `pkill -x Kleoth; open -a Kleoth`;
`codesign -dv /Applications/Kleoth.app` shows "Kleoth Self-Signed". Reset flows with
`tccutil reset ScreenCapture dev.kleoth.app`.

**Spikes (do FIRST — they gate the design):**
0. **TCC on a self-signed (no Team ID) identity, macOS 26.x — exercised BY Kleoth itself.** A bare
   `screenrec` launched from a terminal (from ANY path, `Contents/MacOS/` included) is attributed to the
   terminal's Screen Recording grant (TCC "responsible process"), so it either inherits Terminal/iTerm's
   permission or prompts for *them* — it proves nothing about Kleoth's identity. The spike is therefore the
   release app: `tccutil reset ScreenCapture dev.kleoth.app`, `bash app/make-app.sh release`, relaunch, popover
   **"Record screen…"** → system prompt appears (#8) → grant → the sticky "quit and reopen" pill → relaunch →
   "Record screen…" → Return → 5 s → stop → the file plays. Cap reports Sequoia silently rejecting ad-hoc SCK
   (CapSoftware/Cap#1722) — if the relaunched app still gets `-3801` / no frames, the feature needs Developer
   ID; stop and report to the user. (`screenrec` from the shell stays the right tool for MB/min, sync and
   mixer probes — the shell's own grant is fine for those.)
1. **Static screen:** `screenrec 10` with no screen changes → the first `.screen` sample arrives within 1 s
   (else `firstFrameTimeout` → nil); file duration 10.0 ± 0.1 s; video track not truncated (stop-time re-append).
2. **Stale grant:** `tccutil reset`, grant, do NOT relaunch → start from the popover → within 5 s sticky
   "Quit and reopen Kleoth…"; relaunch → recording works; Settings row green. Confirms the detector; if a stale
   grant yields frames (black) instead of nothing, record that and drop the detector.
3. **SCK audio cadence in silence:** 10 s with nothing playing → log audio buffer PTS; note gaps (informs
   whether the pump ever zero-fills the system lane).
4. **Clap test:** record a visible clap (hands in frame) with a mic → measure mic-vs-video and
   system-vs-video offsets in a video editor; set `micOffsetCompensation` if |offset| > 40 ms.
5. **Three `AVAudioEngine`s:** meeting recording running + dictate + `screenrec 10` → all three receive
   audio; `mic.m4a` has no dropouts. Record the result in CLAUDE.md.
6. **Two system-audio consumers:** meeting recording + screen recording simultaneously → both `system.m4a`
   and the mp4 carry the system audio.

**Feature (by eye/ear in the release app):**
7. Hover the resting pill → mic + red record glyph appear; move away → tucks after 0.45 s. Drag the
   `.recording` pill along its edge → re-docks; a slightly jittery click (< 6 pt) still stops (not re-docks).
8. Fresh TCC: hover pill → record → system prompt appears; pill sticky "Allow Screen Recording, then quit and
   reopen"; Open Screen Recording Settings deep-links to Privacy → Screen Recording.
9. Pill start: hover → peek shows mic + record glyph; click record → picker on every display; Esc cancels
   (pill sinks); Return records the whole display under the pointer; drag < 64 pt → whole display; drag
   800×450 pt → "1600×900 px" label; recording starts, pill `.recording` with digits counting from 00:00.
10. The pill panel and the picker overlay are NOT in the recording; the cursor IS; Kleoth's History window is
    NOT either (whole-app exclusion — expected in v1).
11. Meeting recording running, then screen recording, then dictation (three engines): all three produce audio
    (`mic.m4a` intact; screen recording has mic; dictation pastes).
12. **MB/min:** 5-minute real recording (IDE + browser + talking) at 1080p → `ls -l`; target ≤ 25 MB/min
    (expect 8–15); `screenrec --inspect file` prints bitrate + nominal fps. If the user wants smaller, drop
    `videoBitRateAt1080p` to 2.5 Mbps and re-measure.
13. Colors: a known #FF0000 / #00FF00 / #0000FF test image and text edges look right in QuickTime (BGRA path).
    A 5K display records at 1920 long edge; a 1440×900 display at native 2880×1800 → 1920×1200.
14. A/V sync: play a metronome video with visible flash; frame-step in QuickTime — flash and click within
    1 frame at the start AND at 10 min.
15. Mic ↔ system: speakers on, mic on, play a click track; open the file's audio in a waveform viewer — the
    mic echo trails the system copy by a constant < 60 ms (wired) / < 200 ms (BT) with no drift over 10 min.
16. Playback of the fMP4: QuickTime, Chrome, Safari, Slack inline, Telegram, iMessage. Any refusal → flip
    `fragmentInterval` to nil and re-verify #17/#18 (the file is then moov-at-front, crash = total loss).
17. Quit via popover mid-recording → dialog; Quit Anyway → app exits within 5 s; file plays; duration matches.
    ⌘Q from the History window mid-recording → same.
18. `kill -9 Kleoth` mid-recording → relaunch → "Recovered a screen recording" row → `-recovered.mp4` plays
    up to the last fragment (≤ 10 s lost). `kill -TERM` → identical (no delegate runs).
19. Static screen for 60 s mid-recording → video plays through (last frame held), scrub works, no desync at
    the end. If scrubbing stalls, set `keepaliveInterval = 1` and re-verify #1 + PTS monotonicity (no writer
    failure in the log).
20. Hover the `.recording` pill → stop glyph; click → `.saving` → `.saved("m:ss · N MB")` → click → Finder
    reveals the file; pill returns to `.idle` (dictation on) or hides (dictation off).
21. Popover: "Record screen…" works with dictation DISABLED → pill appears for the recording only, hides after
    `.saved`; menu-bar icon shows `record.circle`; header "Recording the screen · 00:xx".
22. Change the default OUTPUT device mid-recording → recorded system audio continuous. AirPods connect
    mid-recording → HFP flip; system audio in the FILE unaffected; mic continues (converter rebuilt).
23. Dictation mid-recording: fn+shift → `.armed/.listening/…/.done` morph in place (capsule keeps its size at
    `.armed`) → back to `.recording` with correct digits; the pasted text lands; the recording's mic track
    contains the dictated words.
24. Stop the screen recording while hands-free dictation is live → dictation completes normally; `.saved`
    appears after it; nothing lost.
25. Unplug the USB mic at 0:30, replug at 0:40 → recording continues; detail says "mic dropped 10 s at 0:30";
    audio after 0:40 in sync. Lock the screen for 20 s mid-recording → frames dropped, audio continuous.
26. Disconnect the recorded external display mid-recording → `.saved` with detail "display disconnected"; file plays.
27. Reduce Motion on: `.recording` dot static, digits still tick, transitions jump; VoiceOver announces "Screen
    recording started" / the saved text once each, not every second.
28. Move `~/Kleoth` in Settings → next recording lands in the new `screen-recordings/`; History never lists
    the folder as a meeting; the folder holds only `.mp4`.
29. Settings section: permission row polls at 1 Hz; "Open Recordings Folder" opens Finder (creates the folder).
30. macOS 26 monthly alert: after `tccutil reset` + grant, the "bypass the system private window picker" alert
    appears on first SCK use — Allow For One Month → recording proceeds.
31. Idle CPU: `.recording` pill on screen for 5 min → Activity Monitor < 1 % for Kleoth's UI (the
    `TimelineView` tick is the only per-second work).
32. Sandbox films (§6.5) read: `.recording` centered, `recording→armed` keeps size, `done→recording` morph,
    `saving→saved→idle` two reshapes, side edge upright digits, peek shows the record glyph.

---

## 9 Deliberately deferred (with the reason)
- **Per-window exclusion instead of whole-app** — needs the pill's `windowNumber` on the contract plus
  `updateContentFilter` after the pill's first `show()` (the panel is created lazily); only matters for demoing
  Kleoth itself. The v1 hole it would open (popover start with the pill hidden) is why whole-app won.
- **"Keep the pill on screen for screen recording" Settings toggle** (B's) — a Settings field, Keychain key,
  AppConfig line and a Settings row for a case the popover row already covers. Ship only if a user asks —
  **user decision**.
- **History scope for recordings** — the ask says "a minimal way to get at the file"; the `.saved` click, the
  popover row and the folder button cover it; a scope needs a list model, thumbnails/duration probing and
  delete UI. Revisit once there are dozens of files.
- **Keepalive frames** (periodic re-append) — off; the stop-time re-append covers a static tail; §8 #19 decides.
- **Remembered region / "record the same area again"** — a second decision surface in the picker; v1 keeps
  drag / Return / Esc only.
- **Per-source loudness (AGC / mic gain)** — meetings normalize offline (`ChannelAudio.normalizeLoudness`);
  a real-time AGC is new DSP with its own failure modes. The limiter prevents clipping; measure real files first.
- **`captureMicrophone` (15+) / `SCRecordingOutput`** — rejected with data (§4.1, §5.1), not deferred.
- **`420v` pixel format** — one-line switch after §8 #13 shows BGRA colors are right and CPU is measured.
- **Pause/resume, camera bubble, trimming, share links, per-window capture, HEVC, `showMouseClicks` (15+),
  countdown, keyboard shortcut, App Intent / `kleoth://screen` verb** — out of v1 per the ask; the state
  machine has room (`Event`/`State` are enums) and the popover entry is the natural place for a shortcut later.
- **Esc to stop a recording** — Esc is dictation's cancel key (`DictationController.handleEscape`); a global
  Esc while not dictating would need its own monitor.
- **Onboarding permission priming for Screen Recording** — deliberately not (needs a relaunch; alarming for a
  meeting recorder's first launch).
- **Developer ID signing** — Cap reports Sequoia refusing SCK for Team-ID-less signatures (Cap issue 1722);
  "Kleoth Self-Signed" has no Team ID either. §8 #0 is the spike; if it fails, Developer ID (already on the
  roadmap) becomes a blocker for this feature and must be raised with the user.


---

## 10 Implementation notes (2026-09-06)

What the six implementation lanes actually deviated from the design above, plus the fixes from the
integration review. One bullet per item; the code is the authority, this is the trail.

**Lane deviations**

- **T1 — `CaptureGeometry.outputPixelSize` cap.** The design's `scale = cap / longEdge` then
  even-floor produced **1918, not 1920** on any source whose long edge does not divide 1920 exactly
  (1333×999 pt @2 → 2666 px; `2666 * (1920/2666)` evaluates to 1919.999…). The long dimension is now
  assigned `cap` verbatim and only the short dimension carries the division. Exact-divisor shapes
  (2880×1800@2, 1440×900@2, 1280×720@2) are unchanged. §3.1's "aspect preserved within 1 px" is
  asserted on the short edge (the only rounded one, within 2 px) plus `max(out) == cap`.
- **T1 — session machine, beyond §3.1's table.** `stopRequested` is accepted from
  `.checkingPermission` and `.pickingRegion` (→ `.idle` / `.reset`, never `.finalize` — nothing was
  opened); `startRequested` is accepted from the terminal `.saved` and `.failed` and replaces the old
  result (a sticky fault must not block a retry); `dismissed` is rejected in every non-terminal state;
  a second `stopRequested` in `.stopping`/`.saving` is a no-op; a late `captureStarted` in `.stopping`
  is rejected. A private `pendingSince: Date?` carries the click instant across the permission and
  picker legs so the elapsed clock does not start at the first SCK frame.
- **T2 — pill.** `PillTypes.swift` needed no copy refinement (the contract commit already shipped the
  final strings). `.recording`/`.saving` capsule height settled at **28 pt** (§6.1 left 26/28 to the
  film). `.armed` **keeps** the recording layout (A/B-filmed, inheritance won) and therefore wears the
  resting rim at recording size — the one place that combination occurs. Side-edge digits carry
  `.rotationEffect(-edgeRotation)` like the mic glyph, so the capsule stands up and the digits read
  upright. `DragGesture(minimumDistance:)` went 3 → 6 pt so a jittery stop click is not a re-dock.
- **T3 — `ScreenRecorderStats.sessionOriginHostTime` added.** Without it `screenrec 10` produced a
  **10.23 s** file: the probe anchored on `start()` returning while the movie's zero is the first
  frame's PTS, which SCK hands over ~0.19 s in the past. Anchored on the origin: 10.05 s video /
  10.00 s audio.
- **T3 — `AudioMixPump` flushes a partial tail block** on stop (`emit(upTo:budget:allowPartialTail:)`).
  §4.3 describes whole 960-frame blocks only; those left the audio track up to 20 ms short of the
  video's retimed stop frame. The remaining ~50 ms gap is the video's final-sample duration at 30 fps
  plus MP4 timescale rounding, and it does **not** accumulate (300.04 s vs 300.00 s over 5 minutes).
- **T3 — thread-safety and lifetime.** `ScreenRecorder.stop()` reads `rings.origin`/`originPTS`
  through `audioQueue.sync` (`AudioRingBox` is `@unchecked Sendable`, audio-queue-only), and
  `eventSink.finish()` moved into a `defer` at the top of `stop()` — it previously ran only on the
  success path, so a `.nothingCaptured` / `.finalizeTimedOut` throw hung the controller's
  `for await recorder.events` loop forever.
- **T3 — `MicrophoneSource.handleConfigurationChange` recomputes `offsetTicks`** from the new device's
  `presentationLatency`; it used to carry the old device's value, so built-in (a few ms) → Bluetooth
  HFP (>100 ms) left the mic lane wrongly shifted for the rest of the session.
- **T3 — the session origin is the first `.screen` sample of any status**, not the first appended
  frame as §4.2's table says. The ring position and the emitted PTS use the same origin, so a block's
  PTS round-trips to its true host time either way; measured, the two instants coincided (501 blocks
  emitted, 0 dropped by the writer over 10 s). §5.3's keepalive lives in `ScreenRecorder` as a
  `DispatchSourceTimer` driving `VideoFrameGate.appendFinalFrame`, dead by default
  (`keepaliveInterval` nil).
- **T3 — the clap test could not be measured per lane** (the design deliberately produces ONE mixed
  track). Measured instead as the gap between the two copies of a single 2 kHz click in the mix, with
  a `--no-mic` control run: the **mic copy trails the system copy by ≈30 ms**, inside §4.5's < 60 ms
  wired budget, so `micOffsetCompensation` stays 0 until §8 #15 runs on real hardware.
- **T4 — `RegionPicker` debounces cancel-on-lost-key by one main-queue turn.** With one overlay per
  display, crossing a display boundary hands key to a sibling and posts `didResignKey` on the first;
  the deferred check asks "is ANY of my overlays key now?" and only cancels if none is. A whole-display
  pick resolves the display from `NSEvent.mouseLocation` and falls back to the key overlay's screen,
  then `NSScreen.main` (the pointer can land in the gap between non-contiguous displays). Keypad Enter
  (keyCode 76) is accepted alongside Return, and the selection is punched out of the 30 % dim
  (`.copy` blend) rather than merely outlined.
- **T5 — preflight failures other than TCC ride `.permissionMissing(ScreenRecordingFailure)`.** The
  machine has no dedicated preflight-failed event and this is the only `checkingPermission` failure
  carrier with a payload; the free-disk check (§7 row 6) emits `.permissionMissing(.diskFull)`. Do not
  special-case that payload to permission failures.
- **T5 — `.stopCapture` and `.finalize` collapse into one recorder call.** `ScreenRecorder.stop(reason:)`
  stops the stream *and* finalizes, so `stopCapture()` shows `.saving` and immediately applies
  `.captureStopped`; `finalize()` holds the single `await recorder.stop(reason:)`. A stop requested
  while `start()` is in flight **awaits** the start task rather than cancelling it — cancelling would
  propagate into a half-built SCStream/writer behind `ScreenRecorder`'s back and race `stop()` against
  `start()` on the same `@MainActor` object.
- **T5 — the terminate reply is deferred one main-queue turn.** `beginTerminationStop` can complete
  synchronously (quit with the region picker up tears the session down with no file), and
  `NSApp.reply(toApplicationShouldTerminate:)` must not run before `applicationShouldTerminate` has
  returned `.terminateLater`.
- **T5 — the queued `.saved` is polled every 250 ms** in addition to flushing on a forwarded dictation
  `dismiss()`: `DictationPillController.scheduleAutoHide` calls `dismiss()` **directly**, not
  `onDismiss?()`, so `.done` (1 s) and `.warning` (3 s) — the two commonest dictation endings — never
  route through the coordinator's face. The poll is bounded by `savedConfirmationMaxDelay`.
- **T5 — two error-matrix escape hatches.** §7 row 24 (`finalizeTimedOut`) needs to leave `.saving`
  but wants a `.warning("Saved with a delay")`, not a sticky red fault → one optional `faultOverride`
  consumed in `showFailed()`. §7 row 16 (mic engine cannot restart) is `micLostAt`: a `micLost` during
  the session makes `showSaved()` put up `.warning("Saved — the microphone dropped out at m:ss")`;
  `lastSummary`/`lastStopDetail` still carry the file, so the popover row is unaffected.
- **T5 — `isDictationPhaseLive` trails a `show()` by one turn** (`DictationPillController.transition`
  applies `model.phase` on the next main-queue callout), so the flush after a forwarded dictation
  `dismiss()` deliberately does not re-check it — the caller's "the dictation just ended" is the
  fresher fact. The launch sweep's "holds a playable fragment" test is `AVURLAsset.load(.duration) > 0`
  (async, off `applicationDidFinishLaunching`), and the free-disk probe walks to the nearest existing
  ancestor and **fails open** when the volume reports no capacity.
- **T6 — "02:14", not "2:14".** §2.4/§2.5's prose writes the popover row as
  "Last screen recording · 2:14 · 48 MB", but it is built from `ScreenRecordingSummary.pillText` →
  `ElapsedFormatter`, which zero-pads minutes under an hour. The row uses `pillText` verbatim so the
  popover and the pill can never desync; if unpadded minutes are wanted the fix belongs in
  `ElapsedFormatter`/`pillText`, never in a popover special case.
- **T6 — `MenuView.headerSubtitleView`.** `headerSubtitle` stayed a `String` for the three existing
  cases; live digits need a `TimelineView`, so the header renders a `@ViewBuilder` whose
  `TimelineView(.periodic)` exists ONLY on the screen-recording branch — a resting popover schedules
  no 1 Hz redraw. The Settings permission row swaps its `if granted / else` bodies **inside** an
  unconditional `VStack` so the view identity, and with it the 1 Hz `.task`, survives the flip. The
  "Saving screen recording…" state is a plain `Label`, not a disabled `Button` (no dead hit target).
  When both a recording and a transcription are in flight, the quit dialog leads with the recording
  and appends the transcription sentence — neither warning is lost.
  `SettingsScreenRecordingSection` carries its own copy of the 5-line `captionFooter` helper because
  `SettingsView`'s is private to that type.

**Integration-review fixes**

- **`finalizeTimeout` / `SCShareableContent` timeouts now actually bound.** Added
  `withDeadline(seconds:operation:)` to KleothCore (`Sources/KleothCore/Concurrency/Timeout.swift`): a
  one-shot continuation raced by the operation task, a deadline task and outer cancellation, so it
  resumes **without** waiting for a non-cancellable child. `ScreenRecorder.stop()` races
  `writer.finish()` through it (the finish runs as its own Task) and `shareableContent()` uses it too.
  `withTimeout` gained a doc note that it only bounds cancellation-aware work.
- **A late-but-successful finalize no longer strands a complete movie under the in-flight name.** On
  `.finalizeTimedOut`, `ScreenRecorder.renameWhenFinishLands(_:outputURL:)` awaits the still-running
  finish in a detached task and renames `screen-….recording.mp4` to its final name (or deletes it when
  zero frames were appended); a quit before it lands still leaves the file for the launch sweep. The
  doc comments on `start()`/`stop()` were corrected to match.
- **`showSaved()` no longer loses the `.saved` confirmation.** The backdrop is dropped **before** the
  confirmation is shown (mirroring `showFailed()`), so a `.recording` backdrop still on screen — a
  dictation that ended over the top of `.saving` — can no longer collapse the just-scheduled `.saved`
  transition to `.idle`. The "ORDER MATTERS" comment now states the real rule.
- **A retried recording no longer runs behind the previous session's sticky `.failed`** (or a stale
  `.saved`): `ScreenRecordingController.start(from:)` calls `coordinator.dismissRecordingPhase()` right
  after the machine accepts `.startRequested` and before `perform(effect)`, so the pill is in the
  resting family by the time `startCapture()` sets the `.recording(since:)` backdrop.
- **`RegionPicker` hands focus back.** `begin` records `NSWorkspace.shared.frontmostApplication` when it
  is not Kleoth, and `teardown()` re-activates it (if still running) after the overlays close — so after
  a pick or an Esc the user's app is frontmost again, instead of Kleoth staying active with zero windows
  (which also made a following dictation paste land nowhere).
