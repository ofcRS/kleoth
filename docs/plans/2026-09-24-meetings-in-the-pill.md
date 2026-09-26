# Meetings in the pill, and calls that ask to be recorded — design

_2026-09-24. Builds on `main` at `bb2563e` — the dictation-retry work (kept-dictation pill,
`.transcriptionKept`, `.retryTranscription`) merged as PR #3 while this was written; every file:line below
was re-checked against it. Phase 1 (§3.1) stands alone. Phase 2
(§3.2) only adds to it — cutting phase 2 leaves phase 1 complete and unchanged. The pill rules of
`2026-09-03-dictation.md` §5.6 and `2026-09-06-screen-recording.md` §6 stay binding, as do the pill
gotchas in CLAUDE.md (own `PillMenuPanel`, never `NSMenu`; no `NSHostingView` as a panel's content view;
panel frames set by the controller only)._

_Phase 1 built 2026-09-25 and phase 2 2026-09-26, both on `feat/meetings-in-the-pill`; §10 lists the
deviations of each. §3–§6 are corrected in place where a ruling changed the behaviour (each says so and
points at §10); the rest of §4 and §8 stays the plan, and §10 is what was built._

## 1 The ask

User, dictated notes:

> "Add a start meeting recording button to the floating pill, which feels like a killer feature."
>
> "Consider adding a feature similar to Whisperflow where, upon detecting microphone usage, it proposes
> starting a meeting recording. Additionally, we need to determine how to capture meeting context
> (whether Slack, Google Meet, or elsewhere), potentially via screenshots or other means."

The reference, Wispr Flow's Notetaker (beta, changelog 2026-09-15): an "Automatically detect any call"
toggle; it asks "Transcribe this meeting with Wispr?" and records only on yes; it can optionally stop when
the call ends; dictating during the meeting shares the mic instead of pausing it. How it detects a call is
not documented.

The motivation: meetings that happen but never get recorded because starting one takes a trip to the menu
bar, and recorded meetings that rarely know who was in them.

1. **Phase 1 — meetings in the pill.** A Meeting button in the peek dock and the pill menu; while a
   meeting records, the pill is its control bar (elapsed time, levels, Stop), exactly as it already is
   for a screen recording. Dictation, meetings and screen recordings then all start and stop from the pill.
2. **Phase 2 — calls that ask to be recorded.** When another app starts using the microphone (Zoom,
   Teams, a Slack huddle, FaceTime, Discord, Google Meet in a browser…), the pill offers "Zoom call —
   record it?". Each meeting remembers where it happened — app, site, calendar event — in `meta.json`,
   and that feeds the title and the participants.

Fixed: Kleoth never starts a recording on its own. Every recording begins with the user's click
(all-party consent laws; README "Consent").

## 2 Current state (`main`, 2026-09-24)

**The pill.**
- The contract, `app/Sources/KleothPillUI/PillTypes.swift`: `DictationPillState` (:17-73) = the dictation
  phases plus the screen recording's `.recording(since:)`, `.saving`, `.saved(String)`;
  `DictationPillBackdrop` (:78-91) = `.hidden | .idle | .recording(since:)`; `DictationPillAction`
  (:155-195) has no meeting action; `PillMenuContent` (:239-263) knows microphones, the last dictation, the
  hotkey.
- The peek dock is three fields, Dictate · Record · More (`DictationPillView.swift:574-618`). Its hit test
  assumes three fields centred on −pitch / 0 / +pitch (:585-591), `PillDockMetrics.size` is three tiles
  wide (:1207-1212), and the sandbox's film pointer repeats the assumption (`pillsandbox/main.swift:789-806`).
- The pill menu (`DictationPillController.swift:760-802`): Start dictation, Record screen…, Microphone,
  Paste last dictation, Dictation history…, Hide for 1 hour, Settings….
- The screen-recording bar, `RecordingToolbar` (`DictationPillView.swift:733-780`): dot · mm:ss · mic meter
  · system meter · Stop, fed by `setRecordingLevels` (`DictationPillController.swift:199-220`) from a 20 Hz
  pump (`ScreenRecordingController.swift:463-481`).
- `PillCoordinator` (`app/Sources/KleothApp/ScreenRecording/PillCoordinator.swift`) merges exactly two
  sides: dictation (foreground) and screen recording (backdrop, `recompute()` :138-146). `lastShowOwner`
  (:49-50) tells whose `.warning`/`.failed` is up; a `.saved` that lands on a live dictation is queued for
  ≤ 10 s (:150-192); `route` (:196-206) and `routeDismiss` (:211-220) know those two sides only; the menu
  content passes straight through from the dictation side (:273-276).
- The resting pill is up only while the dictation hotkey is armed and not hidden for the hour
  (`DictationController.swift:375-377`). Screen-recording design §6.3 made its bar the one exception: a hot
  microphone must be visible.

**Meetings.**
- `RecordingController.start()` (`app/Sources/KleothApp/RecordingController.swift:606-636`) guards consent
  (:609-612) and reports every refusal and failure only through `statusMessage`, which only the popover
  shows. The start time is private (`activeRecordingStartedAt`, :167); nothing exposes levels.
- `stop()` (:645-735) finalizes off the main actor, then: auto-transcribe off (the default) → returns with
  **no `meta.json` and no calendar lookup** (:707-712); on → calendar lookup (:715-717) and `runPipeline`.
- `calendarMeetingInfo(at:)` (:278-294) takes the events overlapping ±5 min and keeps the FIRST that spans
  the start — an all-day event or a solo focus block wins as easily as the meeting — then
  `attendees.compactMap { $0.name }`: no fallback when `name` is nil, the user and meeting rooms included.
- `runPipeline` (:1016-1120) builds fresh metadata every run (:1068-1077): whatever `meta.json` held before
  transcription is dropped (the loss is acknowledged at :859-863 for participants and consent).
- `loadRecentMeetings` already lists a folder that has `meta.json` but no transcript ("reverted":
  `hasMetadata: true, isProcessed: false`, :1562-1591). Only the no-`meta.json` branch skips the folder
  being recorded (:1598-1599).
- `Recorder` (`app/Sources/KleothCapture/Recorder.swift`) exposes no levels. `SystemAudioTap` already scans
  every IO buffer for its peak (:223-256) and maps a PID to a Core Audio Process object (:350-369) — the
  Process class is in use on the app's 14.4 floor today.

**Microphone use by other apps.** Nothing watches it. The macOS 26.5 SDK has what is needed in
`CoreAudio/AudioHardware.h`: the system object's `kAudioHardwarePropertyProcessObjectList` (`'prs#'`,
:586, :633) lists the Process objects of every client process; each Process object has
`kAudioProcessPropertyPID` (`'ppid'`), `kAudioProcessPropertyBundleID` (`'pbid'`, a CFString),
`kAudioProcessPropertyDevices` and `kAudioProcessPropertyIsRunningInput` (`'piri'`, :1967, :1982 — "running
IO and at least one active input stream"). `AudioObjectAddPropertyListenerBlock` (:397) delivers changes on
a dispatch queue. The selectors carry no `API_AVAILABLE` in the 26.5 or 15.4 headers and Apple's reference
lists no introduction version; they are absent from the macOS 13.3 SDK and present from 14 on — inside
the app's 14.4 floor either way. Permission and listener behaviour: §3.2.1.

**Calendar.** Opt-in (Settings → Meetings → Calendar → Enable). Few meetings end up with attendee names:
the lookup runs only at stop with auto-transcribe on or at transcription of a placeholder-titled folder,
and even then keeps only attendees whose `name` is set.

## 3 Behaviour

### 3.1 Phase 1 — meetings in the pill

#### 3.1.1 Starting

- **Peek dock: four fields, Dictate · Meeting · Screen · More.** The Record field is renamed **Screen**:
  two fields record now, and "Record" next to "Meeting" is ambiguous. The Meeting glyph is
  `person.2.wave.2.fill` in the dock's ink; red stays with Screen. At the default scale the dock grows
  from 210 to 275 pt (Q1).
- **Menu**, second row: **Record meeting** — subtitle "Microphone and system audio". While a meeting
  records: **Stop meeting recording** — subtitle "Recording · 12:03" (the elapsed time when the menu opened).
- A click does what the popover's Start Recording does (`RecordingController.start()`): same folder, same
  two captures, same microphone pick. Nothing else starts differently.
- Already recording (a race with the popover or the hotkey): nothing; the bar is already up.
- The start throws: sticky `.failed(.message("Couldn't start the meeting recording — <reason>"))`, and
  the popover's status line as today.

#### 3.1.2 Consent

`start()` refuses until the user has acknowledged recording consent once (the popover's `ConsentView`,
`MenuView.swift:36-38`). Track 4 (`2026-09-24-summary-truncation-and-onboarding-skip.md` §3.4–§3.5) owns
that refusal: `start()` bumps `consentRequest` and a small **Before you record** window comes forward with
**I understand — start recording**; the guard stays inside `start()` and new start paths add no check of
their own. The pill follows that contract: its Meeting button just calls `start()`; on `.needsConsent` it
shows nothing of its own, the window does the asking, and the bar appears when the recording starts. Until
track 4 lands, `.needsConsent` shows `.warning("Acknowledge recording consent in the Kleoth menu first")`
for 3 s — one line to delete when it does. Consent is asked once per install.

#### 3.1.3 The meeting bar

- **`.meeting(since:)`** is the pill's backdrop while a meeting records — the `.recording(since:)`
  pattern: never tucked, horizontal on every edge, `since` fixed for the meeting so every re-show after a
  dictation compares equal and fires no spring.
- **Layout: `● 👥 12:03 [mic ▮▮▮▮] [system ▮▮▮▮] ■`** — the screen bar with a people glyph after the dot,
  240 pt against the screen bar's 222. A meeting bar that looked like the screen bar would read as "my
  screen is being recorded".
- Only **Stop** stops; the rest of the bar drags; a right-click opens the menu (the screen bar's rules,
  screen-recording §6.4).
- **Meters** come from `Recorder` (new, §4.2). A system meter that never moves is the one visible sign that
  the System Audio Recording grant is missing — the tap then delivers silence, not an error.
- **Shown for every meeting, whoever started it** — popover, global hotkey, `kleoth://record`, App
  Intent, the pill — also with dictation off or the pill hidden for the hour (Q2). This is the
  screen-recording §6.3 rule: a hot microphone has an indicator.
- VoiceOver: "Meeting recording started" once, at the start; the Stop button is "Stop meeting recording".

#### 3.1.4 Stopping

- Stop from anywhere (bar, pill menu, popover, hotkey, URL, App Intent) → **`.saving`** (the existing
  travelling wave) while the two files are combined (seconds for an hour-long meeting) →
  **`.meetingSaved("Meeting saved · 42:10")`** for 4 s — with auto-transcribe on, "Meeting saved · 42:10 ·
  transcribing". A click on it opens History on that meeting.
- The duration is the wall clock from `since` to the stop.
- Finalizing throws: sticky `.failed(.message("The meeting stopped with an error — its audio is in
  History"))`; the History error card as today.

#### 3.1.5 Living with dictation and screen recording

Precedence of backdrops: **screen recording > meeting > resting pill > nothing**.

| Situation | Pill shows | Backdrop |
|---|---|---|
| Dictation armed, idle | `.idle`, tucked; hover → Dictate · Meeting · Screen · More | `.idle` |
| Meeting tile, consent given | `.idle` → `.meeting(since:)` (rise) | `.meeting` |
| Meeting tile, no consent yet | track 4's Before you record window; once it starts the recording → `.meeting(since:)` | `.idle` → `.meeting` |
| Meeting + fn+shift | `.armed` (listening-sized) → `.listening` → … → `.done`, all flat, then the bar again (morph in place) | `.meeting` |
| Meeting + screen recording started | the screen bar; the meeting keeps recording; its Stop is in the menu and the popover | `.recording` |
| Screen recording ends, meeting still on | `.saving` → `.saved` → the meeting bar | `.meeting` |
| Meeting stops, nothing else live | `.saving` → `.meetingSaved` → `.idle` / hidden | `.idle` / `.hidden` |
| Meeting stops while a dictation phase is up | the dictation continues; `.meetingSaved` waits ≤ 10 s for it (the queued `.saved` rule) | `.idle` |
| Dictation off, or hidden for the hour | no resting pill; the meeting bar while recording | `.hidden` ↔ `.meeting` |

- **An old fault never hides a new bar.** When a meeting or a screen recording starts, a sticky `.failed` on
  the pill goes, a dictation's too ("Add an ElevenLabs key to dictate", "… — saved to History"): it is
  terminal (its session has ended; a kept dictation's Retry is also History's "Try again"). A live dictation
  phase and a dictation `.warning` (3 s) stay; the bar lands after them.
- **A dictation over the meeting's `.saving`** takes the stopped meeting's bar down with it: the dictation
  collapses onto the resting pill (or nothing), never back onto a running clock, and "Meeting saved" follows.
  From the stop on, the pill menu's meeting row reads "Record meeting".
- **Microphone sharing.** The meeting's `MicCapture`, the dictation's `DictationCapture` and the screen
  recorder's `MicrophoneSource` each open their own `AVAudioEngine` on the same device (screen-recording
  §4.6: two engines proven, three extrapolated — §6 manual step 5 covers it). Nothing is handed over;
  nothing stops.
- Words dictated during a meeting are also in the meeting's mic channel, and the other side of the call
  hears them unless the user is muted there — true today; the pill changes nothing about it.
- A meeting and a screen recording can run together (true today from the popover). Only one bar fits the
  pill; the screen bar outranks because it is usually the later, shorter capture, and its `.saved` hands
  back to the meeting bar.

### 3.2 Phase 2 — calls that ask to be recorded

#### 3.2.1 What Kleoth watches

- **Core Audio Process objects**: which processes run audio input right now. `IsRunningInput` is the
  truth, read on every check; it is **not** what the listeners watch: per-process `IsRunningInput` /
  `IsRunningOutput` listeners register fine and never fire (Apple forums 770348, Dec 2024; still so on
  macOS 26.6.2 per home-assistant/iOS#5635), while `IsRunning` and `Devices` do. So:
  - **Triggers**: the process-list listener (it fires before the new process's flags are set) and, on each
    Process object, `kAudioProcessPropertyIsRunning` and `kAudioProcessPropertyDevices`. A trigger schedules
    a full re-read 0.3 s later and another at 1.5 s.
  - **Backstop poll**: a full re-read every 3 s while any source holds the mic, every 10 s otherwise —
    missed notifications heal (ghostie runs the same shape at 5 s / 20 s). Device-level
    `DeviceIsRunningSomewhere` is not used: it trips on headset output and reportedly reads 0 for
    Bluetooth mics (Apple forums 741026).
  - `kAudioHardwarePropertyServiceRestarted` (coreaudiod restarted): every listener is re-established, as
    the header requires.
- **No permission, no prompt.** Reading Process objects starts no audio IO; Apple ties the System Audio
  Recording prompt to starting IO on a tap's aggregate device, and no source reports a prompt for these
  reads (open-source detectors — anarlog, meeting-transcriber, ghostie — read them unprompted). `micwatch`
  (§4.2) confirms it on this Mac before the controller lands.
- **Kleoth's own PID is excluded** — its dictation, meeting and screen-recording engines and the
  system-audio tap's aggregate device all run in-process. Other Kleoth builds (`dev.kleoth.*`) are on the
  never list.
- **Each process is resolved to the app a person would name** (order in §4.2):
  - the app itself;
  - the outermost `.app` around a helper's executable — Chrome's audio service runs in "Google Chrome
    Helper" (`com.google.Chrome.helper`, Chromium's `<bundle>.helper<suffix>` scheme), and the same holds for
    Edge, Brave, Arc, Dia, Firefox's plugin-container and Electron apps (Slack, Discord, Teams);
  - the parent process;
  - the **responsible process** for WebKit's GPU process (`com.apple.WebKit.GPU`), which captures the mic
    for Safari — and, since macOS Sonoma, for every app that embeds WebKit, so its bundle id alone does not
    mean Safari. There is no public API for this (Apple DTS; Endpoint Security aside), so it uses
    `responsibility_get_pid_responsible_for_pid`, exported by `/usr/lib/system/libquarantine.dylib` (listed in
    the SDK's `libquarantine.tbd`, no header), looked up once with `dlsym`. Without the symbol: Safari when it
    is the only WebKit browser running, else not a source;
  - a daemon stand-in: FaceTime's audio runs in `com.apple.avconferenced` and the FaceTime app itself never
    reports input (a published measurement on macOS 26.5.2; anarlog relabels the daemon the same way) —
    shown as FaceTime, or Phone when the Phone app is the one running.
- **When it runs**: while call detection is on, and during every meeting recording even when it is off —
  context (§3.2.6) is collected for every meeting.

#### 3.2.2 What counts as a call

A **source** is an app, or a call in a browser. It "holds the mic" while any of its processes run input; a
gap shorter than **8 s** (a device switch, a Bluetooth reconnect) does not end its session. A session
belongs to the app, and its class only ever goes up while it lasts: a browser that shows a Meet title or a
web-call assertion once stays a Meet call when the user switches tabs, and its dwell counts from the
session's start. The catalog (§4.1) sorts sources into classes, each with the continuous time before an
offer:

| Class | Examples (initial catalog, calibrated in §6 step 9) | Offer after |
|---|---|---|
| Call app | Zoom `us.zoom.xos`, Teams `com.microsoft.teams2` / `com.microsoft.teams`, Webex `Cisco-Systems.Spark`, FaceTime (via `com.apple.avconferenced`), GoTo Meeting, Tuple, Around | 5 s |
| Chat app | Slack `com.tinyspeck.slackmacgap`, Discord `com.hnc.Discord`, Telegram `ru.keepcoder.Telegram` / `com.tdesktop.Telegram`, WhatsApp `net.whatsapp.WhatsApp`, Signal `org.whispersystems.signal-desktop`, Messenger, Viber — voice notes and clips are shorter than calls | 30 s |
| Browser call | a browser holding the mic whose window title names a meeting service, **or** a Chromium browser holding the IOKit power assertion "WebRTC has active PeerConnections" (`IOPMCopyAssertionsByProcess`) — a live call, where voice typing has no peer connection | 8 s |
| Browser, no call seen | Chrome `com.google.Chrome`, Safari `com.apple.Safari`, Arc `company.thebrowser.Browser`, Dia `company.thebrowser.dia`, Edge `com.microsoft.edgemac`, Brave `com.brave.Browser`, Firefox `org.mozilla.firefox`, Vivaldi `com.vivaldi.Vivaldi`, Opera `com.operasoftware.Opera`, Orion | 60 s |
| Other app | anything the catalog doesn't list | 60 s (Q4) |
| Never | Apple's own processes except the FaceTime/Phone stand-in (Siri, Dictation, Sound Recognition, Voice Control, `com.apple.replayd` — ScreenCaptureKit's mic capture for other recorders); dictation tools (Wispr Flow `com.electron.wispr-flow`, Superwhisper, MacWhisper, VoiceInk, Aqua Voice, Willow); recorders (Voice Memos, QuickTime Player, Audio Hijack, OBS, Loom, CleanShot); music apps (GarageBand, Logic Pro, Ableton Live); virtual-mic processors (Krisp, Rogue Amoeba's tools); AI assistants' voice modes (ChatGPT, Claude); processes outside any `.app` | — |

Service names come from window titles (`MeetingServiceMatcher`, patterns taken from the open-source
detectors above and re-checked in step 9): Google Meet "Meet - abc-defg-hij" / "<event> - Google Meet";
Teams "<name> | Microsoft Teams", except the idle "Microsoft Teams", "Chat | …", "Calendar | …"; Zoom web
"<name>'s Zoom Meeting" (the whole title); Webex "… - Webex" / "Meeting | …"; plus Whereby, Jitsi Meet, Yandex
Telemost, Kontur.Talk, VK Calls and Jazz by name — only as the title's last words after a separator
("standup | Jitsi Meet"), never elsewhere in it, and never the bare name: a search page puts the query first
("jitsi meet - Google Search") and its title would be stored as the meeting's. For apps, titles only feed context (Zoom "Zoom Meeting" /
"Zoom Webinar", the Slack huddle window "Huddle in <channel>").

The false positives this is built against: Kleoth's own captures (PID), other dictation apps (never list),
voice memos and voice notes (never list; chat apps wait 30 s), games (not listed: 60 s, then "Never for
…" once), a mic test in a call app (the offer is withdrawn the moment the app releases the mic), a browser
tab doing voice typing (no peer connection, no meeting title: 60 s, then "Never for Chrome" silences
calls-not-seen in Chrome only).

#### 3.2.3 The offer

- **Text**: "Zoom call — record it?", "Google Meet call — record it?", "Slack huddle — record it?",
  "FaceTime call — record it?"; a browser call without a service name, "Call in Chrome — record it?"; a
  browser with no call seen, "Chrome is using the mic — record it?"; another app, "<App> is using the mic
  — record it?". For a call — a call app, or a `site:` / `webcall:` browser call — with a calendar event on
  now (calendar access given): "“Weekly sync” on Zoom — record it?" (the event title cut at 40 characters).
  A browser with no call seen, a chat app or another app never names the event: voice typing during "Focus
  time" is not that event.
- **Buttons**: **Record** (primary), **Never for Zoom** (quiet), ✕ (not now). Record starts the meeting
  exactly like the Meeting tile — without consent, track 4's window asks first.
- **Recording starts at the click.** The seconds of the call before it are not captured — Kleoth never
  records speculatively and discards on decline.
- **Lifetime**: the offer stays 30 s, longer while the pointer is on the pill (the deadline moves to 5 s
  after the pointer leaves). Then it sinks back to the resting pill.
- **Ignored or ✕** = "not for this call": no second offer while the same session continues, nor for the
  same source within 10 min of the answer (anarlog's field-tested cooldown — it covers a call app that
  drops and retakes the mic for longer than 8 s, a breakout room, a rejoin). After that, a new session is a
  new call and may be offered. The Meeting tile and menu row still start a recording at any time.
- **Withdrawn** when the source releases the mic (a mic test ended, the call was declined), when a
  meeting starts from anywhere, when a screen recording starts, and when the user hides the pill.
- **One offer at a time.** When several sources are due: call app > browser call > chat app > browser >
  other app; ties go to the earliest session. After a ✕ the next due source may be offered.
- **Never over a live dictation.** A prompt that a dictation phase replaces comes back once the pill is
  free (fresh 30 s), if its session is still on. It is also held back while the peek dock or the pill menu
  is open, so it never pulls the dock from under the pointer.
- **Not offered**: while a meeting or a screen recording runs; while the pill is hidden for the hour;
  when detection is off; for a session first seen more than 10 min ago (it was running while one of the
  above applied — the user evidently chose). Kleoth launched mid-call counts from its launch: offered once.
  **Ruled at implementation (§10):** when a recorded meeting ends, every session that held the mic during it
  is silenced for as long as it lasts — the user evidently chose, so the call they just recorded is not
  offered again at once; a new session of the same app (after an 8 s gap) is offered as usual. When
  suppression lifts or after a ✕, a due offer shows at once (from that event), not at the next observation.
- The prompt is the pill's own panel, non-activating — the call app keeps focus, as with every other pill
  phase. The offer shows even when the resting pill is off (dictation disabled): it rises from the edge
  and sinks back to nothing.

#### 3.2.4 Never for this app

**Never for Zoom** stores the source's key and name in `meeting_detection_ignored` (§4.5) and withdraws
the offer. Keys: `app:<bundle id>` for an app; `site:<service id>` for a browser call with a service name
("Never for Google Meet"); `webcall:<bundle id>` for an unnamed browser call ("Never for calls in Chrome");
`browser:<bundle id>` for mic use in a browser where no call was seen — "Never for Chrome" leaves Google
Meet and other calls in Chrome offered (the button's tooltip says so). Settings → Meetings lists every
entry with **Remove**. Context collection (§3.2.6) ignores the list: it records where a meeting happened,
it offers nothing.

#### 3.2.5 The stop suggestion

- A meeting links to one source: the offered one, or else the source holding the mic when the meeting
  started (by the class order above), or else the first source that takes the mic during the meeting.
- When the linked source has released the mic for **20 s** while the meeting still records, the pill asks
  **"Zoom released the mic — stop recording?"** with **Stop** and ✕, flat over the meeting bar, for 60 s.
- Withdrawn when the source takes the mic again (rejoined) or the meeting stops. If another call-class
  source holds the mic when the linked one lets go (the call moved from a huddle to Zoom), the meeting
  relinks to it silently.
- A suggestion only, once per release — Kleoth never stops a meeting by itself (Q5). Ignored, the bar
  keeps its elapsed time on screen, which is the reminder.
- **Ruled at implementation (§10):** the suggestion is made only while call detection is on (the house rule:
  nothing unasked while it is off; the silent relink and the meeting's context still run with it off) and
  never while a screen recording runs (its "Stop" over the screen bar would read as stopping that; it comes
  once the screen recording ends). A visible suggestion is withdrawn when detection is switched off, and when
  a new meeting starts. Switching detection on after the linked app let go more than 20 s ago shows it at once.

#### 3.2.6 Context: where the meeting happened

Collected for every meeting (whether detection is on or not):

- **The app and service**: the source that held the mic longest during the meeting (at least 20 s), else
  the linked one. For a browser, the service when a window title named it.
- **The window title**, only when it matched a meeting pattern (§4.1 `MeetingServiceMatcher`) — e.g.
  "Weekly sync | Microsoft Teams", "Weekly sync - Google Meet". Titles that match nothing are used for the
  match and dropped, never stored. Titles come from `CGWindowListCopyWindowInfo` (`kCGWindowName`) when Kleoth
  already has Screen Recording, else from Accessibility (`AXTitle` of the app's `AXWindows`, 0.5 s
  messaging timeout, off the main actor) when Kleoth already has it for dictation, else none. Kleoth asks
  for neither.
- **The calendar event** (calendar access already given), chosen by `CalendarEventMatcher` (§4.1) at the
  recording's start: all-day, cancelled and declined events are out; among the events overlapping ±5 min,
  one whose URL / location / notes name the detected service beats one with other attendees, which beats a
  solo block; then the closest start; then the shorter event.
- **How it started**: `pill`, `offer`, `menu` (popover), `shortcut` (hotkey, URL, App Intent).
- All of it is written into `meta.json` at stop (§4.5) — for every meeting, auto-transcribe on or off — so
  it survives until the meeting is transcribed. An untranscribed row then shows the title below instead of
  today's recovered "Recording · Sep 24, 14:05", and it can be renamed before transcription.

**Title**: the calendar event's title; else the placeholder **"Recording · Zoom · Sep 24, 14:05"** (the
service, when known, in the existing recovered-title form, which `isPlaceholderTitle` already treats as a
placeholder), so a summary's title still replaces it. Window titles never become titles in this version.

**Participants**: the event's attendees except the user (`isCurrentUser`) and rooms/resources, plus the
organizer if missing; an attendee with no name shows as the address's local part made readable
("anna.petrova@acme.com" → "Anna Petrova") when it has a separator, else the full address. Participants
already flow into the summary prompt and the Markdown header unchanged.

**Speakers**: when the event has exactly one other attendee — every attendee with an identity counts, named
or not (`calendar_other_attendees`), so one readable name among two people is not one-to-one — the system
channel's default name is that person instead of "Them" (the mic channel is the user, the system channel is everyone else — for a
one-to-one call, that one person) (Q6). A rename still overrides it.

**Screenshots are not needed.** App, service and calendar event come from Core Audio, window titles and
EventKit — all local, all cheap, none needing a new permission. A screenshot would need Screen Recording
for a different purpose, OCR or a vision model per meeting, and would capture other people's faces and
private windows. What it could add — participant names off a video grid — is out of scope (§7).

#### 3.2.7 Settings

Settings → Meetings, a new **Call detection** section under Calendar:

- **Offer to record calls** — off by default (Q3).
- **Never offered for** — one row per ignored source with **Remove**; hidden when empty.
- Footer: "When Zoom, Teams, Slack, FaceTime, Google Meet or another app starts using the microphone, the
  pill asks whether to record. Nothing is recorded until you click Record. With Accessibility or Screen
  Recording already allowed, Kleoth also reads the call window's title to tell a meeting tab from other
  sites."
- If the watcher cannot start (a Core Audio error): the toggle stays, with "Call detection isn't
  available: <OSStatus>" under it.
- **As built (§10):** each entry is its own row, worded as the pill's button was ("Never for Zoom", "Never for
  calls in Chrome", "Never for Chrome" — the last captioned "Google Meet and other calls in Chrome are still
  offered"), with **Remove**; no "Never offered for" label. The footer also says that no audio is read, that
  the pill suggests stopping and never stops on its own, that a title naming no meeting is never saved, that
  the offer names the calendar event only with calendar naming on, that no new permission is asked for, and
  that each meeting notes its app whether the toggle is on or off.

## 4 Contract

### 4.1 KleothCore

**Phase 1** — `Dictation/PillGeometry.swift`:

```swift
/// The field of a `count`-field peek dock under a pointer `along` points from the capsule's centre
/// (fields `pitch` apart, centred), clamped to 0..<count. Shared by `PeekDock` and the sandbox's film pointer.
public static func dockFieldIndex(along: CGFloat, pitch: CGFloat, count: Int) -> Int
/// The centre offset of field `index` — the inverse, for the sandbox.
public static func dockFieldCenter(index: Int, pitch: CGFloat, count: Int) -> CGFloat
```

**Phase 2** — a new folder `Sources/KleothCore/Meetings/`:

```swift
// MeetingContext.swift — stored in meta.json as `context` (§4.5)
public struct MeetingContext: Codable, Sendable, Equatable {
    public var startedFrom: String?     // MeetingStartOrigin raw value
    public var appName: String?
    public var appBundleId: String?
    public var service: String?         // "Zoom", "Google Meet", "Slack huddle"
    public var windowTitle: String?     // only a title that matched a meeting pattern
    public var calendarTitle: String?
    public var calendarStart: String?   // ISO 8601
    public var calendarEnd: String?
    public var calendarOtherAttendees: Int?  // the event's other people, nameless ones too (Q6)
    public var micSeconds: Double?      // how long the app held the mic during the recording
}
public enum MeetingStartOrigin: String, Sendable { case pill, offer, menu, shortcut }

// MeetingMetadata (Models/MeetingMetadata.swift) gains, default nil in init:
public var context: MeetingContext?

// MeetingNaming.swift
public enum MeetingNaming {
    /// "Recording · Zoom · Sep 24, 14:05" / "Recording · Sep 24, 14:05" (en_US_POSIX, "MMM d, HH:mm").
    public static func placeholderTitle(service: String?, startedAt: Date, timeZone: TimeZone = .current) -> String
}

// MeetingAppCatalog.swift — pure data + rules
public enum MeetingSourceClass: String, Sendable { case callApp, chatApp, browserCall, browser, otherApp }
public enum MeetingAppCatalog {
    public enum Verdict: Equatable, Sendable {
        case app(MeetingSourceClass, name: String, serviceName: String?)   // callApp / chatApp / otherApp
        case browser(name: String)
        case never
    }
    public static func verdict(bundleId: String, appName: String) -> Verdict
    /// "/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/Contents/MacOS/…"
    /// → "/Applications/Google Chrome.app"; nil outside any .app (daemons, XPC services in /System).
    public static func outermostAppPath(executablePath: String) -> String?
    /// Core Audio bundle ids of daemons that stand for an app: "com.apple.avconferenced" → FaceTime
    /// (or Phone, decided by the host from which of the two is running).
    public static func daemonStandIn(bundleId: String) -> [String]
    /// Power-assertion names that mean "a live call" in a browser: ["WebRTC has active PeerConnections"].
    public static let webCallAssertionNames: Set<String>
}

// MeetingServiceMatcher.swift
public enum MeetingServiceMatcher {
    public struct Match: Equatable, Sendable { public let id: String; public let name: String }  // "google-meet", "Google Meet"
    public static func match(windowTitle: String) -> Match?
    public static let maxStoredTitleLength = 120
}

// MeetingSource.swift
public struct MeetingSource: Sendable, Hashable {
    /// "app:us.zoom.xos" | "site:google-meet" | "webcall:com.google.Chrome" | "browser:com.google.Chrome"
    public var key: String
    public var name: String         // what the pill says: "Zoom", "Google Meet", "Chrome"
    public var sourceClass: MeetingSourceClass
    public var appBundleId: String
    public var appName: String
    public var windowTitle: String? // matched titles only, capped
    /// verdict + the owning app's window titles + whether it holds a web-call assertion → a source,
    /// or nil for `.never`.
    public static func make(bundleId: String, appName: String, windowTitles: [String], hasWebCall: Bool) -> MeetingSource?
}

// MeetingDetectionDefaults.swift
public enum MeetingDetectionDefaults {
    public static let callAppDwell: TimeInterval = 5
    public static let chatAppDwell: TimeInterval = 30
    public static let browserCallDwell: TimeInterval = 8
    public static let otherDwell: TimeInterval = 60        // browser with no call seen, other apps
    public static let releaseGrace: TimeInterval = 8
    public static let offerLifetime: TimeInterval = 30
    public static let hoverLinger: TimeInterval = 5
    public static let dismissCooldown: TimeInterval = 600
    public static let maxOfferAge: TimeInterval = 600
    public static let stopGrace: TimeInterval = 20
    public static let stopOfferLifetime: TimeInterval = 60
    public static let minContextSeconds: TimeInterval = 20
    public static let busyRetry: TimeInterval = 1
    public static let triggerRereads: [TimeInterval] = [0.3, 1.5]   // after a Core Audio notification
    public static let pollWhileHeld: TimeInterval = 3
    public static let pollIdle: TimeInterval = 10
    public static let titleCacheSeconds: TimeInterval = 30
}

// MeetingDetector.swift — the pure machine (the ScreenRecordingSessionMachine idiom: total, no traps)
public struct MeetingDetector: Sendable {
    public struct Environment: Sendable, Equatable {
        public var offersEnabled: Bool           // Settings toggle
        public var ignoredKeys: Set<String>
        public var pillHidden: Bool              // "Hide for 1 hour"
        public var screenRecording: Bool
        public var meetingSince: Date?           // a meeting records, any origin
    }
    public struct Offer: Sendable, Equatable {
        public enum Kind: Sendable { case start, stop }
        public let id: String                    // "offer-<n>", deterministic for tests
        public let kind: Kind
        public let source: MeetingSource
    }
    public enum Answer: Sendable { case accepted, dismissed, never, displaced, refused }
    public enum Event: Sendable {
        case observed(Set<MeetingSource>, at: Date)   // everything holding the mic now (Kleoth excluded)
        case environment(Environment, at: Date)
        case answered(offerId: String, Answer, at: Date)
        case tick(at: Date, pointerOnPill: Bool)
    }
    public enum Effect: Sendable, Equatable {
        case show(Offer)
        case withdraw(offerId: String)
        case ignore(key: String, name: String)       // the host persists "never"
    }
    public init()
    public mutating func handle(_ event: Event) -> [Effect]
    public var nextDeadline: Date? { get }           // when the host must send the next `.tick`
    /// The meeting's primary source (most mic time ≥ minContextSeconds, else the linked one) and its
    /// seconds — asked at stop, valid until the next meeting starts.
    public func meetingSource(at now: Date) -> (source: MeetingSource, micSeconds: Double)?
}

// CalendarEventMatcher.swift — EventKit-free, so it is testable
public struct CalendarCandidate: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var isCancelled: Bool
    public var declinedByUser: Bool
    public var otherAttendeeCount: Int          // excludes the user, rooms and resources
    public var linkText: String                 // URL + location + notes, for the service match
}
public enum CalendarEventMatcher {
    public static func best(_ candidates: [CalendarCandidate], at start: Date, serviceId: String?) -> CalendarCandidate?
}
public enum CalendarParticipants {
    public struct Attendee: Sendable { public var name: String?; public var email: String?; public var isUser: Bool; public var isRoomOrResource: Bool }
    /// Display names, the user and rooms dropped, organizer added if missing, deduplicated, calendar order.
    public static func names(attendees: [Attendee], organizer: Attendee?) -> [String]
    /// `names` plus each attendee it can't name with another URL (a `urn:uuid:`), once per URL (Q6).
    public static func otherAttendeeCount(attendees: [Attendee], organizer: Attendee?) -> Int
    public static func displayName(name: String?, email: String?) -> String?
}
```

`Config/Settings.swift` gains `meetingDetection: Bool` (strict `"true"` opt-in, the `auto_transcribe`
rule) and `meetingDetectionIgnored: [String: String]` (key → name; malformed JSON → empty), parsed from
`meeting_detection` / `meeting_detection_ignored`.

### 4.2 KleothCapture

**Phase 1** — `Recorder` gains `public var levels: AudioLevels` (mic and system RMS, 0…1, `.zero` when
stopped). `MicCapture` stores the RMS of each tap buffer's first channel, and `SystemAudioTap` the RMS of
each IO buffer, into a `LevelWord` (the screen recorder's lock-free slot, same module); both reset on stop.

**Phase 2** — new files:

```swift
// MicActivityMonitor.swift
public struct MicClient: Sendable, Equatable { public var pid: pid_t; public var bundleId: String?; public var executablePath: String? }
public final class MicActivityMonitor: @unchecked Sendable {
    public init()                                     // own serial queue
    /// Triggers (§3.2.1): the process-list listener, per-Process-object IsRunning + Devices listeners,
    /// ServiceRestarted (re-establishes everything). Each trigger → full re-reads at
    /// MeetingDetectionDefaults.triggerRereads; backstop polls at pollWhileHeld / pollIdle. A re-read
    /// reads IsRunningInput on every Process object (the truth), then PID and bundle id for the running
    /// ones. `onChange` gets the full set, this process excluded, only when it differs from the last one.
    public func start(onChange: @escaping @Sendable ([MicClient]) -> Void) throws   // throws OSStatus errors
    public func stop()                                // removes every listener and timer; idempotent
    public static func snapshot() -> [MicClient]      // one synchronous read (micwatch)
}

// MicOwnerResolver.swift (imports AppKit)
public struct MicOwner: Sendable, Equatable {
    public enum Method: String, Sendable { case direct, appBundlePath, parentProcess, responsibleProcess, daemonStandIn }
    public var bundleId: String; public var name: String; public var pid: pid_t; public var method: Method
}
public enum MicOwnerResolver {
    /// In order: NSRunningApplication(pid) with a regular activation policy; the outermost .app around
    /// proc_pidpath (MeetingAppCatalog.outermostAppPath); the parent chain via proc_pidinfo
    /// PROC_PIDTBSDINFO pbi_ppid, 3 levels; for com.apple.WebKit.* the responsible process through
    /// responsibility_get_pid_responsible_for_pid (dlsym once, RTLD_DEFAULT; missing → Safari only when
    /// it is the one WebKit browser running); MeetingAppCatalog.daemonStandIn. Cached per (pid, bundle id).
    public static func owner(of client: MicClient) -> MicOwner?
}

// WebCallAssertions.swift (imports IOKit.pwr_mgt)
public enum WebCallAssertions {
    /// PIDs holding a power assertion named in MeetingAppCatalog.webCallAssertionNames, from
    /// IOPMCopyAssertionsByProcess (public since 10.7, no permission). Read with each re-read.
    public static func pids() -> Set<pid_t>
}

// WindowTitleReader.swift (imports ApplicationServices)
public enum WindowTitleReader {
    /// Titles of `pid`'s normal-layer windows, front to back, any Space (a full-screen call is on its
    /// own): CGWindowListCopyWindowInfo(.optionAll) names when CGPreflightScreenCaptureAccess() is true,
    /// else AXWindows/AXTitle when AXIsProcessTrusted() (AXUIElementSetMessagingTimeout 0.5 s on the
    /// app AND on each window read), else [].
    /// Never prompts. Call off the main actor.
    public static func titles(ofProcess pid: pid_t) -> [String]
}
```

A new executable, **`micwatch`** (app `Package.swift`, depends on KleothCapture + KleothCore):
`micwatch [--seconds N] [--titles] [--detector]` prints every change — time, +/− input, PID, Core Audio
bundle id, resolved owner and method, web-call assertion, catalog class, matched service, and with
`--detector` the offers the real `MeetingDetector` would make. It runs the main run loop (a command-line
HAL client gets no notifications without one — RtAudio's note on `kAudioHardwarePropertyRunLoop`). The
calibration tool for §6 step 9; a shell-launched probe reads titles with the terminal's grants, not
Kleoth's.

### 4.3 KleothPillUI (`PillTypes.swift` is the contract)

**Phase 1:**

```swift
// DictationPillState
case meeting(since: Date)      // the meeting bar (backdrop); `since` fixed for the meeting
case meetingSaved(String)      // "Meeting saved · 42:10"; 4 s; a click → .meeting(.openLast)

// DictationPillBackdrop
case meeting(since: Date)

// DictationPillAction — ONE new case, so the dictation and screen-recording controllers each add a
// single `break` line now and nothing when phase 2 extends MeetingPillAction
case meeting(MeetingPillAction)

public enum MeetingPillAction: Equatable, Sendable {
    case start                      // dock field, menu row
    case stop                       // bar's Stop, menu row
    case openLast                   // click on .meetingSaved
    public var title: String        // "" for all three — no button with words
}

// PillMenuContent
public var meetingSince: Date?      // nil = no meeting recording
```

Every exhaustive switch gains the new cases — in `PillTypes.swift` (`autoHideAfter`: `.meetingSaved` 4 s,
`.meeting` nil; `showsText`: `.meetingSaved`; `DictationPillBackdrop.state`; `title`),
`DictationPillController.swift` (`isRestingFamily` + `.meeting`; `layoutState` — `.armed` over a
`.meeting` backdrop borrows the listening size; `isFlat` — `.meeting`, `.meetingSaved` always, every
dictation phase over a `.meeting` backdrop; `capsuleHeight` — 30 / 32; `layout` — the meeting bar from
`PillStyle.meetingContentWidth`, `.meetingSaved` measured like `.saved`; `referenceSize` — also covers the
meeting bar (bottom/top) and the four-field dock (every edge; at 275 pt it is now the longest shape), so the
anchor never creeps near a corner; `setRecordingLevels` accepts `.meeting`; `announce` — `.meeting`
silent; `pillText` "Recording the meeting"; `symbolName` `person.2.wave.2.fill`),
`DictationPillModel.apply(phase:)` (keeps the meters for `.meeting`), `DictationPillView.swift` (`content`;
the tap switch — `.meetingSaved` opens; a `MeetingToolbar` = `RecordingToolbar` plus the glyph slot,
`PillStyle.meetingGlyphWidth` 14 and `meetingContentWidth` = `recordingContentWidth + spacingXS +
meetingGlyphWidth`; `PeekDock` gains the Meeting field and hit-tests through `PillGeometry.dockFieldIndex`;
`PillDockMetrics.fieldCount = 4` and `size` from it), `PillMenu`/`menuEntries` (the meeting row), and
`pillsandbox`.

**Phase 2:**

```swift
// DictationPillState
case prompt(PillPrompt)        // a question with buttons; sticky with ✕; its owner withdraws it

public struct PillPrompt: Equatable, Sendable {
    public enum Tint: Sendable { case accent, record }
    public var id: String
    public var text: String                    // capped at DictationPillFault.maxMessageLength
    public var symbolName: String              // offers person.2.wave.2.fill, the stop suggestion stop.circle.fill
    public var tint: Tint
    public var primary: DictationPillAction
    public var secondary: DictationPillAction?
}

// MeetingPillAction
case acceptOffer(id: String)                   // "Record"
case neverOffer(key: String, name: String)     // "Never for <name>"
case acceptStop(id: String)                    // "Stop"

// DictationPillController
public var isInteracting: Bool { get }         // peeking or menu open — offers wait
public var isPointerOver: Bool { get }         // the offer's lifetime waits
```

`.prompt` in the switches: `showsText`; no auto-hide; `isFlat` over a capture backdrop; height 38; laid out
like `.failed` plus every button it shows; `isSticky` (the ✕); announced; the view draws symbol, label,
primary, the quieter secondary and ✕, and a tap on the capsule does nothing (a stray click must not
decline); `isDictationPhaseLive` is false for it.

### 4.4 KleothApp

**Phase 1:**

- `Meetings/MeetingCaptureTypes.swift` (new):

  ```swift
  public enum MeetingStartOutcome: Equatable, Sendable { case started(since: Date), alreadyRecording, needsConsent, failed(String) }
  public enum MeetingCaptureEvent: Equatable, Sendable {
      case started(since: Date, directory: URL)
      case finalizing(directory: URL)
      case saved(directory: URL, seconds: TimeInterval, transcribing: Bool)
      case stopFailed(message: String, directory: URL?)
  }
  ```

- `RecordingController` (hooks only, no pill knowledge):

  ```swift
  @Published public private(set) var recordingSince: Date?          // mirrors activeRecordingStartedAt
  @discardableResult public func start() async -> MeetingStartOutcome // existing callers unchanged
  func addCaptureObserver(_ observer: @escaping @MainActor (MeetingCaptureEvent) -> Void)
  var meetingLevels: AudioLevels { get }                              // (recorder)?.levels ?? .zero
  func openInHistory(directory: URL)   // selectedMeetingID + HistoryRouting.requestedScope + meetingsHistoryRequest
  ```

  Events fire from `start()` (success) and `stop()` (`.finalizing` as the slot frees, `.saved` after the
  combine, `.stopFailed` in its catch).

- `PillCoordinator` gains a third side:

  ```swift
  var onMeetingAction: ((MeetingPillAction) -> Void)?
  var onMeetingDismiss: (() -> Void)?                        // ✕ on a meeting-owned .failed
  func setMeetingBackdrop(since: Date?)                      // recompute(): recording > meeting > idle > hidden
  func setMeetingLevels(_ levels: AudioLevels)               // forwarded only while no screen recording runs
  @discardableResult func showMeetingPhase(_ state: DictationPillState) -> Bool   // false = not shown
  func dismissMeetingPhase()                                 // only meeting-owned phases
  ```

  `Owner` gains `.meeting`; `.saving` becomes owner-checked (both captures use it); the `.saved` queue
  generalizes to one queued confirmation with its owner, so `.meetingSaved` queues the same way; a meeting
  `.warning`/`.failed` over a live dictation is dropped (the recording side's rule); `route` sends
  `.meeting(_)` to `onMeetingAction`; `routeDismiss` sends a meeting-owned ✕ to `onMeetingDismiss`;
  `isDictationPhaseLive` is false for the new phases. The coordinator now installs `pill.menuContent`
  itself — the dictation face's closure plus `meetingSince`.
  Phase 2 adds: `onMeetingDismiss` carries the prompt id (`((String?) -> Void)?`),
  `var onMeetingPromptDisplaced: ((String) -> Void)?` (a dictation or recording phase replaced a meeting
  prompt), `var currentMeetingPromptId: String?`, `var isPillBusyForPrompts: Bool` (a dictation phase, a
  recording or meeting `.saving`/`.saved`/`.meetingSaved`/`.warning`/`.failed`, or `pill.isInteracting`),
  `var isPointerOverPill: Bool`. A prompt replaces only the resting family (`.hidden`, `.idle`,
  `.recording`, `.meeting`) or another meeting prompt.

- `Meetings/MeetingPillBridge.swift` (new, `@MainActor`, created in `applicationDidFinishLaunching`): the
  meeting side's face. It handles `MeetingPillAction`s (start → `start()`: `.needsConsent` → nothing, or
  the 3 s warning until track 4 lands (§3.1.2); `.failed` → the fault; stop → `stop()`; openLast →
  `openInHistory` + `dismissMeetingPhase()`), observes capture events, matched to the meeting by folder
  (§10) (started → `setMeetingBackdrop(since:)` FIRST, then `dismissMeetingPhase()` — as built, §10; a
  20 Hz level pump, the VoiceOver line; finalizing → pump off,
  `.saving`; saved → backdrop nil FIRST, then `.meetingSaved` — the `ScreenRecordingController.showSaved`
  order, :766-783; stopFailed → backdrop nil, the fault).
- `KleothApp.swift`: `KleothMenuBarLabel` also observes `meetingsHistoryRequest` to open History (a
  pill-driven request has no SwiftUI environment of its own).
- `DictationController.handlePillAction` and `ScreenRecordingController.handlePillAction` add `.meeting`
  to their never-routed `break` lists; `AppDelegate` creates the bridge.

**Phase 2:**

- `Meetings/MeetingDetectionController.swift` (new, `@MainActor ObservableObject`, a `@StateObject` in
  `KleothApp` injected into Settings, `start()` from `applicationDidFinishLaunching`):

  ```swift
  @Published private(set) var isEnabled: Bool
  @Published private(set) var ignored: [String: String]
  @Published private(set) var unavailableReason: String?
  func start()
  func setEnabled(_ on: Bool)                  // Keychain meeting_detection
  func unignore(key: String)                   // Keychain meeting_detection_ignored
  func context(startedAt: Date, stoppedAt: Date) -> MeetingContext   // service, app, title, micSeconds
  ```

  It runs the monitor while enabled or a meeting records; with each change resolves owners, reads
  `WebCallAssertions.pids()` and window titles (every non-never holder) — off the main actor. As built (§10):
  while a meeting records or the detector still has a session it could offer (`hasOfferableSession`), the held
  set is re-resolved every `pollWhileHeld` (3 s), titles coming from a `titleCacheSeconds` (30 s) per-PID cache
  (emptied once nothing holds the mic), so a tab whose meeting title or web-call assertion appears after it took
  the mic still upgrades its source; builds `MeetingSource`s; feeds `MeetingDetector`; schedules
  `.tick` at `nextDeadline` (the wait floored at 0.25 s, capped at 1 s while a prompt is up); turns
  `.show`/`.withdraw` into `showMeetingPhase(.prompt(…))` / `dismissMeetingPhase()` — a refused show becomes
  `.answered(.refused)`; persists `.ignore`; builds the
  `Environment` from `recordingSince` (capture observer), `ScreenRecordingController.isActive` and
  `DictationController.pillHiddenUntil` (Combine).
- `MeetingPillBridge` forwards `acceptOffer` (answer `.accepted`, then `start(origin: .offer)`),
  `neverOffer`, `acceptStop` (`.accepted`, then `stop()`), a meeting prompt's ✕ (`.dismissed`) and
  `onMeetingPromptDisplaced` (`.displaced`) to the detection controller.
- `Meetings/CalendarLookup.swift` (new): EventKit → `CalendarCandidate`s / `CalendarParticipants.Attendee`s
  → `CalendarEventMatcher`. Replaces the body of `calendarMeetingInfo(at:)`, which keeps its
  `calendarAuthorized` guard and gains the service hint.
- `RecordingController`:
  - `start(origin: MeetingStartOrigin = .menu)`; `handle(.record/.toggle)` and `KleothIntents` pass
    `.shortcut`, the bridge `.pill` / `.offer`, the popover and onboarding keep the default.
  - `var meetingContextProvider: ((Date, Date) -> MeetingContext)?`, set by the detection controller.
  - `stop()`: the context is read SYNCHRONOUSLY right after `isRecording = false`, before `recordingSince`
    goes nil and before the first `await` (§10: read after the combine, the detector has already forgotten
    the linked source). After the combine, for every meeting, resolve the calendar match, then write
    `meta.json` (title, date, `started_at`, participants, consent, `context`) BEFORE `.saved` and the
    auto-transcribe branch. The folder is no longer being recorded by then, so the "reverted" listing
    applies. Never earlier: a listed folder's duration is probed once and cached forever (`durationCache`), and a
    `meta.json` written at start would list the folder mid-recording (:1562 has no active-folder check). The
    no-calendar title is `MeetingNaming.placeholderTitle` on both branches (today's "Meeting <date>" from
    `defaultMeetingTitle()` stays only for imported files).
  - `runPipeline` reads an existing `meta.json` first: its `context` always, its participants when the new
    naming has none, its title when that is not a placeholder. `transcribeSaved`'s calendar recovery
    stays for folders without `meta.json` (older meetings).
  - The default speaker map (three sites, :1047, :1175, :1402) names `speaker_1` after the only
    participant when there is exactly one (participants already exclude the user and rooms) and the event
    had exactly one other attendee with any identity (`calendar_other_attendees`; nil = an older meeting,
    the names decide) (Q6).
- `Keychain.Account.meetingDetection = "meeting_detection"`, `.meetingDetectionIgnored =
  "meeting_detection_ignored"`; `AppConfig.mergeSettingsFromKeychain` reads both.
- `Views/SettingsMeetingDetectionSection.swift` (new); `SettingsView.pageSections(.meetings)` gains one
  line after `calendarSection`.

### 4.5 Stored keys and files

`meta.json` (phase 2) gains `context`, snake_case through `MeetingStore`'s strategies, every key
acronym-free and round-tripping:

```json
"context": {
  "app_bundle_id": "com.google.Chrome",
  "app_name": "Google Chrome",
  "calendar_end": "2026-09-24T10:30:00Z",
  "calendar_other_attendees": 3,
  "calendar_start": "2026-09-24T10:00:00Z",
  "calendar_title": "Weekly sync",
  "mic_seconds": 1712,
  "service": "Google Meet",
  "started_from": "offer",
  "window_title": "Weekly sync - Google Meet"
}
```

Every key is optional; an older `meta.json` decodes with `context == nil`. **Downgrade:** a build older than
phase 2 drops `context` whenever it rewrites `meta.json` (rename, re-transcription, variant switch). Meetings
recorded with auto-transcribe off now always have `meta.json` from the moment they stop.

Why a key in `meta.json` is safe here although the illustrations design (track 3, its Q3) moved its data to
a `cover.json` sidecar because every writer re-encodes `meta.json` whole from a snapshot that can be
minutes old: `context` is written once, at stop, before any job on that folder can take a snapshot, and
never changes afterwards. Every later writer decodes the whole struct and carries it — `runPipeline` too,
once it reads the existing file first (§4.4). A stale snapshot can only ever write back the same `context`.

Keychain (consolidated item): `meeting_detection` = `"true"`/`"false"`; `meeting_detection_ignored` = a
JSON object string, key → name, e.g. `{"app:com.hnc.Discord":"Discord","browser:com.google.Chrome":"Chrome"}`.
No new UserDefaults key.

### 4.6 Shared files and contracts this track touches

Sibling columns from the three sibling design docs now in `docs/plans/` (dictation context = 1,
illustrations = 3, summaries and consent = 4).

| File / contract | Phase | Change here | Siblings there |
|---|---|---|---|
| `app/Sources/KleothPillUI/PillTypes.swift` | 1, 2 | `.meeting`, `.meetingSaved`, backdrop, `MeetingPillAction`, `PillMenuContent.meetingSince`; phase 2 `.prompt`, `PillPrompt` | none (1 says untouched) |
| `DictationPillController.swift`, `DictationPillView.swift`, `DictationPillModel.swift`, `PillMenu.swift`, `pillsandbox/main.swift` | 1, 2 | switches, dock, bar, menu row; phase 2 the prompt | none |
| `PillCoordinator.swift` | 1, 2 | the meeting side | none (4 only cites it) |
| `RecordingController.swift` | 1, 2 | hooks; `start(origin:)`; `meta.json` at stop; `runPipeline` reads it; speaker map | 3; 4 (`start()` refusal branch, `consentRequest`, `summarize(_:)`, three pipeline branches) — land 4 first, rebase P2-app |
| `start()` consent semantics | 1 | relied on, not changed | 4 owns them |
| `KleothApp.swift` (`KleothMenuBarLabel` inputs, scenes), `AppWiring.swift` | 1, 2 | label observes `meetingsHistoryRequest`; bridge and detection controller created | 3, 4 (`consentRequest` input, consent window scene) |
| `DictationController.swift` | 1 | one `.meeting` `break` line | 1 (its main file) |
| `ScreenRecordingController.swift` | 1 | one `.meeting` `break` line | — |
| `KleothIntents.swift` | 2 | `start(origin: .shortcut)` | 4 (the intent's dialog) |
| `SettingsView.swift` | 2 | one line on the Meetings page | 3 |
| `Keychain.swift`, `AppConfig.swift`, `Sources/KleothCore/Config/Settings.swift` | 2 | two keys | 1, 3 |
| `MeetingMetadata.swift` / the `meta.json` schema | 2 | `context` | 4 (`model` / `summary_provider` only with a summary); 3 keeps out (`cover.json`) |
| `PillGeometry.swift` | 1 | `dockFieldIndex` / `dockFieldCenter` | — |
| `app/Package.swift` | 2 | the `micwatch` target | 3 |

Untouched on purpose: `Summarizer`, `MeetingPipeline` and `MarkdownRenderer` (4's), `MeetingDetailView` and
the History lists (3's and 4's), `OnboardingView` and `ConsentView` (4's), `MeetingStore`.

## 5 Error matrix

| Cause | User-visible behaviour | Files |
|---|---|---|
| Meeting tile / menu, consent never given | track 4's Before you record window (its "I understand — start recording" starts; the bar follows); before track 4 lands, a 3 s warning pointing at the Kleoth menu | — |
| `start()` throws, started from the pill (or an offer) | sticky `.failed(.message("Couldn't start the meeting recording — …"))`; popover line. Started anywhere else: the popover line only (§10) | folder removed as today |
| Start while already recording | nothing (bar already up) | — |
| System Audio grant missing | records; the system meter stays flat (silence, not an error — unchanged) | as today |
| Finalizing throws | backdrop gone; sticky "The meeting stopped with an error — its audio is in History"; History error card | audio kept; no `meta.json`, so the context is lost (§10) |
| Stop while a dictation phase is up | dictation untouched; `.meetingSaved` queued ≤ 10 s, then dropped | — |
| Meeting and screen recording together | screen bar shown; meeting Stop in menu / popover; meeting bar returns after `.saved` | — |
| Quit while a meeting records | unchanged from today (not handled here) | — |
| Core Audio listener fails to register (phase 2) | detection off; Settings: "Call detection isn't available: <OSStatus>"; logged | — |
| coreaudiod restarts | listeners rebuilt; a gap ≥ 8 s starts new sessions (a recording meeting is unaffected) | — |
| Process's owner unresolved | not a source, ignored; `micwatch` shows it | — |
| `com.apple.WebKit.GPU` and the responsibility symbol is gone (a future macOS) | Safari when it is the only WebKit browser running, else not a source; logged once | — |
| No Accessibility, no Screen Recording | no titles: a Chromium call is still a browser call by its WebRTC assertion ("Call in Chrome"); Safari and Firefox calls are "no call seen" (60 s, generic text); no `window_title` | — |
| AX call hangs (busy app) | 0.5 s timeout, no titles for that read | — |
| Calendar not authorized / no event | no calendar fields; title "Recording · Zoom · Sep 24, 14:05" | — |
| Offer: Record, consent missing | the offer goes; track 4's window asks, as for the Meeting tile; its start keeps `started_from: "offer"` (§10) | — |
| Offer: Record, start throws | the start fault | — |
| Offer while a dictation phase is up, the dock peeks or the menu is open | held; shown when free (1 s retries) with a fresh 30 s | — |
| Offer replaced by a dictation chord | comes back after the dictation, if the session is still on | — |
| Offer ignored 30 s / ✕ | sinks back; no second offer for that session, nor for that source within 10 min | — |
| Never for X | offer withdrawn; X listed in Settings | Keychain `meeting_detection_ignored` |
| Source releases the mic ≥ 8 s during its offer | offer withdrawn | — |
| Two sources due at once | one offer, class order | — |
| Linked source released ≥ 20 s | stop suggestion 60 s, only with detection on and no screen recording running (§3.2.5); Stop → normal stop | — |
| Stop suggestion ignored | bar stays; no second suggestion until the source takes the mic and releases it again | — |
| `meta.json` write at stop fails | logged; the row stays "Recording · …" without metadata; transcription rebuilds metadata (context lost) | as before phase 2 |
| Older build rewrites `meta.json` | `context` dropped | `context` gone |

## 6 Tests

Core (swift-testing, `Tests/KleothCoreTests`):

- **Phase 1** — `PillGeometryTests`: `dockFieldIndex` for 3 and 4 fields (centres, boundaries, far outside
  clamps, zero or negative pitch → 0); `dockFieldCenter` inverts it.
- `MeetingDetectorTests`: call app offered at 5 s, not at 4.9; chat app at 30 s; browser call at 8 s;
  browser with no call seen and other app at 60 s; never-class sources never; a 7 s gap keeps the session
  and its dwell, an 8 s gap ends it and withdraws a visible offer; ✕ silences the session, a new session of
  the same source inside 10 min is not offered and one after 10 min is; a browser session that gains a
  web-call assertion mid-dwell switches to the 8 s dwell from its start; `never` emits `.ignore` and an
  ignored key is never offered; each suppression
  (meeting, screen recording, pill hidden, offers off) blocks offers and withdraws a visible one; a session
  first seen > 10 min before suppression lifts is never offered; expiry at 30 s, deferred while
  `pointerOnPill` and 5 s after; `.refused` → retried at +1 s; `.displaced` → re-offered with a fresh
  lifetime; class priority and earliest-session ties; accepted offer links its source; a meeting started
  with no source links the first source to appear; stop offer at 20 s after the linked release, withdrawn on
  re-acquire and on meeting stop, once per release; relink to another call-class source instead of a stop
  offer; `meetingSource(at:)` returns the longest holder ≥ 20 s else the linked one, with its seconds;
  a session's class never goes down (a Meet title that disappears keeps it a Meet call);
  `nextDeadline` is the earliest pending deadline and nil when nothing is pending.
- `MeetingAppCatalogTests`: every catalog bundle id maps to its class and name; helper executable paths
  resolve to the outer app (Chrome's "Google Chrome Helper.app" nested in its framework, Edge, Brave, Arc,
  Slack, Discord, Teams, Firefox's plugin-container); a `/System/Library/…/XPCServices/…` path and
  `/usr/libexec/…` → nil; `com.apple.*` → never, including `com.apple.replayd`, except the
  `com.apple.avconferenced` stand-in (→ FaceTime, Phone); `com.electron.wispr-flow` and the other
  dictation tools → never; `dev.kleoth.*` → never; `webCallAssertionNames` holds Chromium's name.
- `MeetingServiceMatcherTests`: "Meet - abc-defg-hij" and "Weekly sync - Google Meet" → Google Meet; Teams
  "Weekly sync | Microsoft Teams" → Teams, but "Microsoft Teams", "Chat | …", "Calendar | …" → nil; "Anna's
  Zoom Meeting" → Zoom, but "Zoom", "Zoom Workplace", "Home" → nil; "… - Webex" → Webex; Whereby, Jitsi
  Meet, Telemost as the title's last words, but their search pages, mentions and bare names → nil; a plain page
  title → nil; case and whitespace; a stored title capped at 120 characters.
- `MeetingSourceTests`: `make` for an app; a browser with a matched title (`site:` key, service name, title
  kept); with only a web-call assertion (`webcall:` key, "Call in Chrome"); with neither (`browser:` key,
  no title); a never-class app → nil.
- `CalendarEventMatcherTests`: all-day, cancelled and declined dropped; an event with attendees beats a
  solo block spanning the start; a service-link event beats both; closest start wins ties, then the shorter
  event; empty → nil.
- `CalendarParticipantsTests`: user and rooms dropped; organizer added once; nil name → readable local
  part ("anna.petrova@acme.com" → "Anna Petrova", "ap@acme.com" kept whole); duplicates removed; order kept.
- `MeetingContextTests` (in `MetadataTitleTests` or new): `meta.json` round-trip with `context` — the exact
  snake_case key set above; absent `context` decodes nil; `MeetingNaming.placeholderTitle` output, and
  `isPlaceholderTitle` is true for it with and without a service.
- `SettingsTests`: `meeting_detection` strict opt-in; `meeting_detection_ignored` parsed, malformed → empty.

App (no test target): `swift build --package-path app`; `pillsandbox --film` strips of the new states;
`micwatch` against real calls (step 9).

Films (`app/.build/debug/pillsandbox --film <dir> …`, read `frames.tsv` + `sheet.png`):

- `--edge bottom --sequence idle,peek,hover:mic,hover:meet,hover:rec,hover:menu,unpeek` — four fields,
  each lighting under its own spot.
- `--edge right --fraction 0.3 --sequence idle,peek,hover:meet,unpeek` — the upright 275 pt dock.
- `--edge bottom --backdrop meeting --sequence meeting,armed,listening,transcribing,done,meeting,saving,meetingsaved,idle`
  — the bar is centred on the anchor; `meeting→armed` is one reshape; `done→meeting` is a morph with no
  panel move; `saving→meetingsaved` one reshape; `meetingsaved→idle` a sink.
- `--edge left --backdrop meeting --sequence meeting,peek,unpeek` — flat on a side edge, Stop lights up.
- Phase 2: `--edge bottom --sequence idle,offer,idle`, `--edge right --sequence idle,offer,idle` and
  `--backdrop meeting --sequence meeting,stopoffer,meeting` — text width, both buttons and ✕ inside the
  capsule, no clipping, upright on the side edge, flat over the meeting bar.

### Manual checklist

Phase 1:

1. Hover the resting pill → four fields; Meeting → the bar rises, digits count, both meters move when you
   talk and when a video plays; a `meeting-…` folder appears.
2. Stop on the bar → wave → "Meeting saved · 0:42" → click → History opens on that meeting.
3. Start from the popover, then stop from the pill menu; start with the global hotkey, stop from the bar.
4. With track 4's `-KleothSimulateFirstRun YES` launch argument (consent reads as not given): Meeting →
   the Before you record window → I understand — start recording → the bar appears.
5. During a meeting: a dictation (pastes, bar returns); a screen recording (screen bar; stop it → meeting
   bar back); both meeting files and the movie are intact; Bluetooth headset case once.
6. Dictation turned off in Settings: start from the popover → the bar shows; stop → pill gone again.

Phase 2 (detection on):

7. Zoom test meeting → offer after about 5 s; Record → bar; leave the meeting → about 20 s later the stop
   suggestion → Stop → saved; `meta.json` has `context` with `service: "Zoom"`, `started_from: "offer"`.
8. Google Meet in Chrome, then Safari → "Google Meet call — record it?"; ✕ → no second offer until the
   call ends; "Never for Chrome" on a voice-typing page → Meet in Chrome still offered.
9. **Calibration** with `micwatch --titles --detector` during: Zoom, Meet (Chrome, Safari, Arc), FaceTime,
   a Slack huddle, Teams, Discord, a Telegram call; and Voice Memos, Wispr Flow / Superwhisper, macOS
   Dictation, Siri — the last four must show no offer. Check: owners and methods (Safari through the
   responsible process, FaceTime through `avconferenced`), the WebRTC assertion during Meet in Chrome and
   its absence during voice typing, how fast a start is seen with the poll at 10 s. Fix the catalog from
   what it prints. Also the window-title shapes of a Whereby, Jitsi Meet, Telemost, Kontur.Talk, VK Calls and
   Jazz call and of the Zoom web client (matched only as the title's last words / the whole title), and that
   the services' own non-call pages ("Pricing | Whereby") don't read as calls.
10. A calendar event with one other attendee → title = event, participants = that person, `speaker_1` =
    that person; an all-day event on the same day is not chosen.
11. Auto-transcribe off: stop → the row is still "Recording · …" and can be renamed; transcribe it later →
    `context` and participants survive.

## 7 Out of scope

Recording automatically without a click; buffering audio before the click; notifications instead of the
pill; a resting pill for dictation-off users (still the screen-recording §9 decision); a combined bar for
meeting + screen recording; participant names from screenshots, OCR or a call's own UI; window titles as
meeting titles (measure calendar misses first); the app or service in the summary prompt and the Markdown
header (`Summarizer` / `MarkdownRenderer` belong to track 4 now — a one-line follow-up after it lands);
showing the service in History rows (track 3 is in those views — a follow-up); reading a tab's URL
(`AXURL` on the web area, as anarlog and Wispr do — it wakes Chromium's accessibility tree for every tab;
titles plus the WebRTC assertion cover the common cases); the call apps' own power assertions (Teams "call in
progress", Webex "On a call") as a sharper end-of-call signal; hiding the pill from other apps' screen
shares; auto-stop after silence; a stop confirmation; a global "record meeting" hotkey (the existing one
toggles meetings already).

## 8 Tasks

Lanes an Opus subagent can each own. A lane lists the files it owns; nobody else edits them in that phase.

**Phase 1**

1. **P1-contract** (lands first, small): `PillTypes.swift` (§4.3 phase 1 types and every switch in that
   file), `PillGeometry.swift` + `PillGeometryTests`. Depends on nothing.
2. **P1-pill**: `DictationPillController.swift`, `DictationPillView.swift`, `DictationPillModel.swift`,
   `PillMenu.swift`, `pillsandbox/main.swift` — dock, bar, menu row, switches, sandbox items (`meeting`,
   `meetingsaved`, backdrop `meeting`, hover and click spots `mic|meet|rec|menu` through
   `PillGeometry.dockFieldCenter`, the `.meeting(_)` case in the driver's `handle` simulating start →
   bar → stop → saving → saved, ControlPanel buttons) and the phase-1 films. Depends on P1-contract.
3. **P1-levels**: `Recorder.swift`, `MicCapture.swift`, `SystemAudioTap.swift`. Depends on nothing.
4. **P1-app**: `Meetings/MeetingCaptureTypes.swift`, `Meetings/MeetingPillBridge.swift`,
   `PillCoordinator.swift`, the `RecordingController` hooks, `KleothApp.swift` label, `AppWiring.swift`
   (bridge creation), the `.meeting` break lines in `DictationController` / `ScreenRecordingController`.
   Depends on P1-contract and P1-levels; builds against P1-pill's API, not its visuals.
5. **P1-docs**: README (pill section, the dock), CHANGELOG, CLAUDE.md (architecture: `Meetings/`, the
   bridge; gotcha: backdrop precedence), pointers from the screen-recording design §6.2/§6.3.

**Phase 2**

6. **P2-core-detect**: `Meetings/MeetingSource.swift`, `MeetingAppCatalog.swift`,
   `MeetingServiceMatcher.swift`, `MeetingDetector.swift`, `MeetingDetectionDefaults.swift` + their tests.
   Depends on nothing.
7. **P2-core-context**: `Meetings/MeetingContext.swift`, `MeetingNaming.swift`,
   `CalendarEventMatcher.swift` (+ `CalendarParticipants`), `MeetingMetadata.context`, `Settings` keys +
   tests. Depends on nothing.
8. **P2-capture**: `MicActivityMonitor.swift`, `MicOwnerResolver.swift`, `WindowTitleReader.swift`,
   `WebCallAssertions.swift`, the `micwatch` target in `app/Package.swift`. Depends on P2-core-detect's
   catalog signatures (stub-able). **Runs first against real calls**: step 9's calibration — including
   whether `IsRunning` triggers really fire and what WebKit/FaceTime report on this Mac — feeds
   P2-core-detect's tables before P2-app starts.
9. **P2-pill**: `PillTypes.swift`, `DictationPillController.swift`, `DictationPillView.swift`,
   `pillsandbox/main.swift` — `.prompt` / `PillPrompt` and their switches, the phase-2 `MeetingPillAction`
   cases, `isInteracting` / `isPointerOver`, sandbox items `offer` / `stopoffer`, the phase-2 films.
   Depends on phase 1 only.
10. **P2-app**: `Meetings/MeetingDetectionController.swift`, `Meetings/CalendarLookup.swift`, the
    `RecordingController` phase-2 changes, the `PillCoordinator` phase-2 additions, `MeetingPillBridge`
    forwarding, `Keychain.swift`, `AppConfig.swift`, `KleothIntents.swift`, `KleothApp.swift` /
    `AppWiring.swift` wiring. Depends on lanes 6–9 — and on track 4 having landed its `RecordingController`
    changes (rebase, don't interleave).
11. **P2-settings**: `Views/SettingsMeetingDetectionSection.swift` + the one line in `SettingsView.swift`.
    Depends on P2-app's controller API.
12. **P2-docs**: README (permissions table: no new permission; privacy: `context`), CHANGELOG, CLAUDE.md
    (data on disk: `meta.json` at stop, `context`; stale "No `meta.json` = Untranscribed" line fixed).

## 9 Open questions

1. **Dock layout.** Four fields — Dictate · Meeting · Screen · More, "Record" renamed "Screen" — or keep
   three and put meetings in the menu only? *Recommended: four.* The ask is a one-click button, and two
   recording fields need names that say what they record.
2. **Meeting bar for every meeting**, also started from the popover or hotkey, and also with dictation off?
   *Recommended: yes* — it is the hot-mic indicator the screen recording already gets. Users who never
   use the pill will see a bar during meetings.
3. **Call detection by default**: off (a toggle in Settings → Meetings) or on? *Recommended: off* — the
   house rule for anything that acts unasked (`auto_transcribe`, dictation); you switch it on once.
4. **Apps outside the catalog**, and browsers using the mic with no call seen: offer after 60 s with
   "Never for …", or never? *Recommended: offer* — it catches calls in apps the catalog misses (a desktop
   Telemost or Jazz, next year's tool) at the cost of one "Never" per noisy app.
5. **When the call app lets go of the mic**: a one-time "stop recording?" suggestion, or stop by itself?
   *Recommended: suggestion only* — a call can continue in the room after the app hangs up. (Wispr makes
   auto-stop an option; it can become a toggle later.)
6. **One-to-one calendar calls**: label the other side with the sole other attendee instead of "Them"?
   *Recommended: yes* — right in the common case, renameable when wrong.

## 10 Deviations (2026-09-25 and 2026-09-26, at implementation)

Both phases as built on `feat/meetings-in-the-pill`, where they differ from §3–§6, each with its reason.
Phase 1: items 1–13; phase 2 (plan Tasks 9–16, the pre-flight's verified fixes and the review rounds): 14–44.

**Settled before the build**

1. **§9, every recommendation taken:** four dock fields (Dictate · Meeting · Screen · More); the meeting bar
   for every meeting (popover, hotkey, `kleoth://`, intent; with dictation off or the pill hidden for the
   hour too); call detection off by default; apps outside the catalog and browsers with no call seen → 60 s
   and "Never for …"; the stop suggestion only; one-to-one calendar calls label the other side. The last four
   are phase 2.
2. **Live help deferred** (`2026-09-24-live-help.md`): nothing here exists only for it — no context choice
   under Meeting, no context name on the bar.
3. **Landed on `main` since `bb2563e`:**
   - hands-free mid-hold (`ChordEdgeDetector` latch; a click on the push-to-talk pill latches) — untouched;
   - demo mode (`-KleothDemo`): `MeetingPillBridge` is created only from `applicationDidFinishLaunching`, and
     `install()` also returns on `DemoMode.isOn` (phase 2 plans the same for the detection controller, which
     is injected into Settings only);
   - meeting covers: the `CoverController` hooks in `RecordingController` are untouched;
   - the secure-input holder (`PillTypes.swift` `.secureInput(holder:)`) — untouched;
   - the consent window (track 4): the pill's Meeting button calls `start()` and shows nothing on
     `.needsConsent`; "Before you record" asks, and the bar rises once it starts the recording. §3.1.2's
     "3 s warning until track 4 lands" (also in §4.4 and §5) was never built.
4. **Calibration** (§6 step 9, phase 2) can't run against real calls unattended: the plan runs it against a
   microphone that a new probe, `micopen`, holds, and every real-call check stays in the manual checklist.
   Detection ships off, so an uncalibrated catalog entry costs a missed offer, not a wrong recording.

**Changed while building phase 1**

5. **`.started` sets the backdrop FIRST, then dismisses** (§4.4 had the reverse; its text above is fixed).
   The pill applies `model.phase` one main-queue turn after a transition begins, and `setBackdrop` takes over
   only a resting-family phase: a `setMeetingBackdrop` right after `dismissMeetingPhase()` still saw the stale
   phase and merely stored the new backdrop, so the pill settled on `.idle`, hidden, or the previous meeting's
   clock while the new meeting recorded.
6. **The bridge matches capture events by meeting folder.** `stop()` frees the capture slot before it
   finalizes, so the next meeting's `.started` can land before the previous one's `.saved` / `.stopFailed`.
   Only the current meeting's events touch the bar. An earlier meeting's `.saved` shows "Meeting saved" for 4 s
   over the new bar (skipped while the new one is itself saving); its stop failure is logged, not shown in the
   pill — History's error card and the popover line carry it. A folder-less `.stopFailed` (the unreachable
   "no active recording" guard, the one `.stopFailed` with no `.finalizing` before it) takes the bar down and
   shows nothing.
7. **A rising capture clears the other side's leftover phase** (`PillCoordinator.clearCapturePhaseBlocking`,
   after `recompute()`): any sticky `.failed` (a dictation's too, since item 47), and the meeting's own
   `.saving` / `.meetingSaved` / `.warning`, are withdrawn when a capture's bar becomes due — otherwise the
   backdrop is only stored behind them and a hot microphone has no bar. `ScreenRecordingController.start(from:)`'s
   rule, extended to both captures. Never a live dictation phase or a dictation `.warning`; a meeting rising
   under a running screen recording changes nothing.
8. **`finishHide` shows a backdrop that rose during the fade-out** (the 0.18 s `hideCompletely` window): it
   was only stored behind the fading phase, so a capture started in that window got no bar.
9. **`.saving` over a meeting keeps the 240 pt meeting bar** (not the screen bar's 222 pt), so the stop does
   not jolt.
10. **While a screen recording runs, a meeting's `.saving` and `.meetingSaved` are skipped**, and a queued
    `.meetingSaved` is dropped if one starts while it waits: the screen bar stays; the popover and History
    carry the saved meeting. A meeting fault still shows over the screen bar until ✕.
11. **Elapsed text uses `ElapsedFormatter`** — "Meeting saved · 00:42", the menu's "Recording · 12:03"
    (§6 checklist item 2's "0:42" reads "00:42").
12. **`referenceSize` takes the dock metrics** (it was static; the dock's size is instance state) and folds
    in the four-field dock on every edge, and the meeting bar on bottom/top. A pill parked near a corner now
    sits a little further in: about 82 pt on a side edge, about 17 pt on the bottom/top.
13. **A failed start shows in the pill only for a start from the pill** (the §5 row is reworded): no capture
    event carries a failed start, so one from the popover, hotkey, `kleoth://` or the intent shows in the
    popover line and the intent's dialog, as before.

**Known gaps, phase 1 (for the §6 checklist)**

- A fresh fault from one capture covers the other capture's live bar until ✕ (item 5).

**Changed while building phase 2** (768 core tests at the end)

14. **The API grew where the host needed it.** `MeetingDetector.visibleOffer` and `linkedSource` are public (a
    "Never for …" click carries key + name, not the offer id); `MeetingOfferText` builds the prompt copy;
    `MeetingServiceMatcher.storedTitle` / `linkTokens(forService:)`; `CalendarEventMatcher.best(_:at:serviceId:)`
    takes the service id or its name; `MeetingNaming.defaultSpeakerNames` lives in KleothCore, tested there
    (Q6); `MeetingDetectionIgnored.parse` / `encode` for the Keychain string.
15. **Safari is a browser.** The call, chat and browser lists are consulted before the never rules: the
    `com.apple.` prefix had made Safari `.never`, and every Meet call in Safari was dropped.
16. **Safari web apps** (`com.apple.Safari.WebApp.<id>`, a site added to the Dock) are browsers named after
    themselves ("Teams is using the mic", "Never for Teams"), checked before the never rules. The id shape is
    unverified (§6 step 9).
17. **A Google Meet title may end with an em dash** ("Weekly sync — Google Meet").
18. **Participants are one per address**: `mailto:` stripped and lowercased, a real name replaces one read off
    the address; `displayName` is nil without an `@` (a `urn:uuid:` attendee) and drops a `+tag`; a blank
    service id is no service. Without this, an organizer listed again as an attendee made a one-to-one call look
    like two people (Q6). Two people sharing a display name at two addresses stay two.
19. **`nextDeadline` is nil or later than now after every tick.** The dwell candidate is skipped while an offer
    is visible, bounded by the ✕ cooldown and `retryAt`, dropped past `maxOfferAge`; the stop-grace candidate is
    bounded by `retryAt`; `evaluate` clears a passed `retryAt` and first silences sessions older than
    `maxOfferAge`; a hovered tick moves the deadline to `now + hoverLinger`. A past deadline made the host tick
    in a zero-wait loop on the main actor for whole calls (pre-flight C-1); a seeded sweep (120 random runs,
    random hover and ignored keys) pins the rule.
20. **An offer shows from the event that makes it due** — the `.environment` that lifts a suppression, the
    answer that frees the pill — not at the next observation (§3.2.3).
21. **`.displaced` and `.accepted` set `retryAt` (+1 s):** a displaced offer is never re-shown inside the call
    that displaced it (it would paint under the dictation), and Record never flashes the next due source's offer
    before the meeting starts.
22. **Rejoining withdraws the stop suggestion.** The check no longer needs the linked session, which the 8 s
    grace had already removed, so a stale "stop recording?" stayed up after the user rejoined.
23. **The stop suggestion needs detection on and no screen recording** (§3.2.5); the gate is in
    `nextDeadline` too, or a meeting with detection off kept a past deadline (item 19's loop).
24. **Sessions held during a recorded meeting are silenced when it ends** (§3.2.3).
25. **Ties are deterministic:** every choice goes by (class rank, session start, key, app), never by `Set` or
    `Dictionary` order; the batch link picks the best session after the loop.
26. **The ending meeting's last stretch counts.** The mic seconds were accrued after the environment had already
    changed, so their guard always failed; they are accrued first.
27. **`.direct` only for a regular app.** A pid is taken as the app itself only with a `.regular` activation
    policy, so `com.apple.WebKit.GPU` and accessory helpers resolve to their host (Safari, a menu-bar app that
    embeds WebKit, a browser's helpers); the responsible-process and parent steps accept any non-prohibited app.
    An accessory main app (a dictation tool) still resolves to itself through its `.app` path.
28. **Listeners are C procs.** `AudioObjectRemovePropertyListenerBlock` called from Swift removed nothing, so
    listeners stacked with each start (4, then 12 after three starts): every add and remove uses
    `AudioObjectAddPropertyListener` / `AudioObjectRemovePropertyListener` with one `@convention(c)` proc and a
    retained context. Re-reads are coalesced: one leading at 0.3 s, one trailing at 1.5 s that each
    notification pushes back.
29. **The "one WebKit browser running" fallback** also runs when the responsibility symbol gives no usable
    answer; daemon stand-ins are never cached, and a cached owner's pid must still be alive.
30. **`micopen`, a second probe**, holds the mic from another process for the calibration (§6 step 9 can't
    run against real calls unattended, item 4): it never prompts (exit 3 without an existing grant) and discards
    every sample. `micwatch` prints bundle ids, pids, booleans and timings — no path, no window title — and
    floors its tick wait like the app.
31. **Held mics are re-resolved every 3 s** (§4.4). Resolving titles only when the set of mic holders changed
    left a Chrome lobby that joined a call as `browser:` — offered at 60 s, and silenced by "Never for Chrome".
32. **The host floors its tick wait at 0.25 s** (`max(0.25, min(deadline − now, promptUp ? 1 : 3600))`), a
    second guard behind item 19.
33. **One controller, fed at start.** `MeetingDetectionController.sharedInstance()` serves the delegate and
    the Settings scene alike (the `@StateObject` alone would not exist until Settings was built), and `start()`
    feeds the initial environment: the detector starts with offers off and hears only changes.
34. **Displacement is reported after the new phase is asked for**, its id read before the owner flips.
    Reported first, the machine's re-offer passed the busy check and painted a prompt under the dictation. A
    meeting prompt withdrawn by `clearCapturePhaseBlocking` (a capture bar rising) is reported the same way.
35. **"Busy" for prompts** = a live dictation phase, the dock or menu open, a queued confirmation, or a phase
    that holds prompts back, showing now or asked for in the last 0.5 s — not "the last owner was the
    dictation", which outlives a `.done` that auto-hides without a callback. A prompt yields to a running
    screen recording (refused, retried each second).
36. **Answers are idempotent:** only the visible offer's id counts, so a double click never starts twice. The
    machine withdraws nothing on Record, Never or Stop; what follows takes the prompt down (the bar, the fault,
    `.saving`), else the bridge dismisses it.
37. **`isPointerOver` is geometric** (the capsule's rect contains the mouse, the panel up): `model.hovered` could
    stay true after the pointer left and hold an offer past its 30 s. `finishHide` also clears hover and peeking
    ("Hide for 1 hour" from a peeking pill came back with the dock out, refusing every offer).
38. **A same-turn dismiss works.** The pill remembers the phase a transition has yet to apply (`pendingPhase`),
    so `show(.prompt)` then `dismiss()` in one turn no longer leaves the prompt stuck — for every phase.
39. **Prompt targets** are padded to the reserved widths and 30 pt tall; a `webcall:` key's button reads "Never
    for calls in Chrome"; the tooltip only on a `browser:` key.
40. **The context is captured synchronously at stop** (§4.4): read after the combine, as planned, the detector
    had already forgotten the linked source, and a call that held the mic under 20 s got no app at all.
41. **A consent-refused start keeps its origin:** Record on an offer before consent → the "Before you record"
    window starts the meeting as `offer`.
42. **The calendar hint is the service**, for the offer's text and the naming at stop alike; one lookup at stop
    gives both the title and the `calendar_*` fields.
43. **`runPipeline` keeps a stored placeholder title** when the incoming title is a placeholder too, so "Recording
    · Zoom · …" is not traded for the service-less recovered form; `meta.json` at stop uses `MeetingStore`'s
    encoder options (`.withoutEscapingSlashes`); `localtranscribe` carries `context`.
44. **Settings** as in §3.2.7's "As built" note.
45. **The 3 s re-resolve backs off** (final fix batch): it runs only while a meeting records or
    `MeetingDetector.hasOfferableSession(at:)` holds — a held session not yet offered, silenced or answered, no
    older than `maxOfferAge`, with detection on; an ignored key counts only while a browser session can still
    move to a `webcall:`/`site:` key. An app holding the mic all day stops waking Kleoth after 10 min or an
    answer; the chain restarts from any event that makes a session offerable again (a displaced offer, detection
    switched on). The title cache empties once nothing holds the mic. The back-off is the controller's: the
    monitor itself (detection on, or a meeting recording) still re-reads Core Audio every 3 s on its own queue
    while ANY process holds the mic — an app never listed included — and every 10 s when none does; it wakes the
    main actor only when the set of holders changes.
46. **Final fix batch, the rest:** a new meeting's mic seconds start at the meeting, not at the poll before it;
    the deadline sweep allows one tick (the real bound); a `PillPrompt` prints as its id only, so the opt-in pill
    trace can never log an offer's text (a calendar title); the web-call assertion lookup reads a bare pid's
    executable path, so an accessory app resolves; the Raycast extension lists only meetings with a
    `transcript.json` (an untranscribed one has `meta.json` since stop, and was listed as "On-device").

**Branch fix round** (2026-09-26, after both whole-branch reviews; 777 core tests)

47. **A rising bar clears any sticky `.failed`**, a dictation's too (§3.1.5): it is terminal. A stale "Add an
    ElevenLabs key" no longer hides a new meeting's bar, clock and Stop until ✕ — the phase-1 gap is closed, for
    the screen bar too. A live dictation phase and a dictation `.warning` stay.
48. **The phase still to land counts.** `setBackdrop` reads `pendingPhase ?? model.phase`; the coordinator's
    `isDictationPhaseLive` and `clearCapturePhaseBlocking` read the pill's `upcomingState` (`dismissingState ??
    pendingPhase ?? model.phase`). A backdrop no longer paints over an `.armed` asked for in the same turn, and a
    meeting `.saving` no longer pre-empts it.
49. **No live-looking bar after the stop.** A dictation over the meeting's `.saving` drops the meeting's
    backdrop, so it collapses onto the resting pill; from `.finalizing` the pill menu's meeting row reads
    "Record meeting" (`PillCoordinator.meetingDidStopRecording`), no longer "Stop meeting recording" for a
    meeting that is being combined. The phase-1 gap is closed.
50. **An offer the pill would refuse is refused before it is composed** (`PillCoordinator.acceptsMeetingPrompt`):
    the 1 s busy retry ran an `EKEventStore` fetch on the main actor every second while a dictation held the offer
    back. The calendar title is also kept per source key for `offerLifetime`, so an offer shown again (displaced,
    then back) doesn't ask EventKit again.
51. **AX title reads time out per window**: `AXUIElementSetMessagingTimeout` 0.5 s on each window element too, not
    only the app's, so a hung app costs 0.5 s per read instead of the ~6 s default.
52. **Service titles by their last words** (§3.2.2): Whereby, Jitsi Meet, Telemost, Kontur.Talk, VK Calls and Jazz
    match only as "<head> <separator> <service>", Zoom web only as the whole title. A search page no longer counts
    as a call or has its title stored; the old guessed shapes "Jitsi Meet", "Контур.Толк — встреча", "VK Звонки"
    and "SberJazz: Sync" no longer match (step 9 checks the real ones).
53. **The calendar event names calls only** (`MeetingOfferText.namesCalendarEvent`): a call app or a
    `site:`/`webcall:` browser call. There is no lookup at all for a browser without a call, a chat app or an
    unknown app — a Slack huddle is not named after the event either (the call class, as the stop suggestion's
    relink uses it).
54. **Q6 counts people** (`CalendarParticipants.otherAttendeeCount`, stored as `context.calendar_other_attendees`):
    an attendee with no readable name but another URL (`urn:uuid:`, a principal path) counts, so a three-person
    event with one readable name keeps "Them". Older meetings (no count) keep the names rule.
55. **Docs:** README "What does leave" names the title, date and participants that go to the summary provider
    with the transcript; item 45 and CLAUDE.md cover the monitor's own 3 s re-read.

**Known gaps, phase 2 (for the §6 checklist)**

- A finalize that throws writes no `meta.json` (§5): the folder lists as a recovered row, its context lost.
- `calendar_*` are filled only at stop: a placeholder title that a calendar event found at transcription
  replaces leaves them empty.
- Switching detection on mid-meeting, after the linked app let go more than 20 s earlier, shows the stop
  suggestion at once (true; kept).
- With consent never given, Record on an offer delays the next due source by only 1 s: a second offer can
  rise beside the "Before you record" window.
- During every meeting (detection off too), while an app holds the mic, the host wakes every 3 s for the
  assertion read and the cached owner lookups. Outside a meeting it does so only while a session can still be
  offered (item 45).
- The `browser:` caption is written twice: in Settings and in the pill's tooltip.
- Unverified until the §6 step 9 calibration on an awake Mac: every real call, WebKit → Safari live, the Safari
  web-app ids, FaceTime through `avconferenced`, the catalog ids marked "unverified". The `micopen` timings so
  far (listener trigger 0.05–0.21 s on take, ≤ 0.34 s on release) come from a locked screen.
