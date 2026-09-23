# Dictation: a Scribe budget that scales, one retry, and kept audio — design

_2026-09-23. Follows `2026-09-03-dictation.md` (v1). Binding for the `feat/dictation-retry` branch;
§5 replaces the matching rows of the v1 error matrix._

## 1 The ask

User, 2026-09-22 (dictated): dictations into ElevenLabs time out, "three or four times today alone.
It polls and then times out, and I end up losing my dictation." Wanted:

1. the voice never disappears;
2. re-dictate right from the bubble;
3. see untranscribed dictations in History.

Decisions taken with the user:

- After a Scribe failure, **retry Scribe once automatically, then keep** the audio.
- The pill's action **retries the saved audio** (no re-speaking).
- Audio is kept **only until the dictation is transcribed**. A dictation that pastes keeps no audio,
  exactly as before.

## 2 Root cause

The unified log for 2026-09-22 has three `transcription failed: KleothTimeoutError(seconds: 25.0)`.
That day's dictations ran 29–140 s (median 58 s); the pill timings put two of the failed clips at
about 41 s and 79 s. The 25 s budget is flat while Scribe's processing time grows with the clip, so
long dictations lose the race even on a healthy day. A second, latent cap sits under it: the
dictation `URLSession` allows 30 s between bytes and 60 s per request, and Scribe sends no byte
while it transcribes, so simply raising the budget would have hit URLSession's own timeout next.

## 3 Behaviour

### 3.1 Budget and retry — every Scribe call a dictation makes

- **Budget per attempt** = `min(120, 25 + 0.5 × clip seconds)`: 10 s → 30 s, 41 s → 45.5 s,
  78 s → 64 s, 190 s and longer → 120 s.
- **Up to two attempts.** The second runs 1 s after a *transient* first failure: a timeout; a
  network-class `URLError` (`timedOut`, `networkConnectionLost`, `notConnectedToInternet`,
  `cannotConnectToHost`, `cannotFindHost`, `dnsLookupFailed`, `secureConnectionFailed`,
  `badServerResponse`, `cannotLoadFromNetwork`, `dataNotAllowed`, `internationalRoamingOff`);
  HTTP 408, 429 or 5xx; a non-HTTP response. Never retried: cancellation, any other 4xx (bad key,
  payment, 422), an undecodable answer.
- The pill stays `.transcribing` across the retry. Each failed attempt is logged (`Dictation`
  category) with its elapsed time.
- The dictation `URLSession` allows 130 s between bytes and 150 s per request, so the budget is
  always the timeout that fires.
- A transcribed row records `transcription_seconds`, the wall clock of the attempt that produced
  the transcript (diagnostic, like `polish_seconds`).
- The on-device engine (History only, §3.4) gets one attempt and no budget: its first model load
  after a new build takes minutes.

### 3.2 When a dictation is kept

After the clip is committed (the chord released, or the hands-free session stopped), the clip is
kept when:

- transcription fails — after the retry, whatever the error;
- audio preparation fails — the **raw** clip is kept and a retry uploads it as is;
- the run is cancelled while transcribing — Esc, or dictation turned off in Settings. Not on quit:
  `shutdown()` still deletes the clip synchronously.

Not kept, as before: Esc or cancel while *listening* (abandoned before it was finished), clips
under 0.5 s, an empty transcript (silence), and anything after a transcript exists (the polish falls
back to the raw text and a refused paste to the clipboard; both still log the row).

Keeping = the clip is **moved** to `<output>/dictations/audio/<id>.m4a` and a **pending row** with that
id is appended to today's day file: empty `raw_text` / `polished_text`, `insert_method: "none"`,
`audio_file_name`, `transcription_error` (a sentence for History), `duration_seconds`, the app. If
the move fails, the old behaviour applies (the clip goes with the run, plain failure pill). If the
move succeeds but the append fails, the file stays in `audio/` (the launch sweep moves it to the
Trash a day later, so it is never silently destroyed) and the plain failure pill shows.

### 3.3 The pill

- **Kept after a failure:** sticky `.failed(.transcriptionKept("<cause> — saved to History",
  dictationId:))` with a **Retry** button. The pending row's id rides on the button's action
  (`.retryTranscription(dictationId:)`), so a retry never depends on host state that a dismissal
  could clear. Orange `exclamationmark.arrow.circlepath` instead of the red octagon: nothing
  was lost. Causes: "Timed out", "No internet connection", "Network error", "ElevenLabs rejected
  the key" (401), "Scribe is busy" (429), "Scribe error <status>" (5xx), "Transcription failed
  (HTTP <status>)", "Unreadable answer from Scribe", "Couldn't prepare the audio",
  "Transcription failed".
- **Kept after Esc:** `.warning("Stopped — saved to History")` for 3 s. Esc no longer dismisses a
  transcribing pill by itself; the run's cancellation path settles it (at most the preparation
  step's second or two later).
- **Esc once the transcript is in:** the session turns `.polishing` (and the pill shows it) as soon
  as the gate decides to polish — before the polish model is resolved — so Esc from then on pastes
  the text as heard, the existing polish rule. Before, Esc in the gap between the transcript and a
  cold-cache model resolution cancelled the run and the dictation was lost.
- **Not kept** (move failed): today's `.failed(.message(…))`; after Esc, `.failed(.message("Stopped —
  the audio couldn't be saved."))` rather than a silent dismissal.
- **Retry** starts a new session over the kept clip: `.transcribing` → `.polishing` → paste into
  the frontmost app → `.done` / `.warning`. The polish context is the app the dictation was made
  in (the row's app). Success rewrites the row in place — same id and timestamp; text, language,
  models, costs, insert method and seconds filled in; `audio_file_name` / `transcription_error`
  cleared — and deletes the audio. Failure shows the kept pill again and updates the row's
  `transcription_error`. Esc during a retry dismisses the pill and leaves the row as it was.
- Retry while another session is live: the 1 s "Finishing the previous dictation…" refusal. Retry
  of a row that is gone, already transcribed or running from History: the pill is dismissed
  (History shows the state).
- A click on the capsule or ✕ dismisses the pill; the row stays in History.

### 3.4 History (Dictations scope)

- **Sidebar row** of a pending dictation: "Not transcribed" in place of the text, the usual
  time · app · duration line, and an orange "Audio saved" chip whose tooltip is the reason
  ("Transcribing…" while it runs). The detail header carries the same chip.
- **Detail pane:** the usual header; a failure card "Not transcribed" + the reason; **Try again in
  cloud** (prominent) and **Try again on device** (its tooltip says the AUDIO stays on this Mac — the
  clean-up pass may still use a cloud provider); **Show Audio in Finder**; a caption: "The text is
  copied to the clipboard when it's ready. Kleoth keeps the audio until then." While the row is
  running — from here or from the pill — a "Transcribing…" row replaces the buttons. Missing audio
  file: the card says so and only Delete remains.
- **History runs are background jobs:** no pill, no session, never a paste — the text is copied to
  the clipboard and the pane says "Copied to the clipboard." Polished exactly like a dictation into
  the row's app. On device goes through `RecordingController.enqueuePipelineJob` (never two
  WhisperKit engines); the cloud runs directly. One run per row at a time.
- **Delete:** the confirmation adds "Saved audio goes to the Trash."; the kept audio of every
  deleted row is moved to the Trash — never erased outright: a clip the Trash refuses stays for the
  launch sweep. Delete is disabled (and ⌫ beeps) for a row that is being transcribed; the controller
  also skips busy rows, the backstop for a pill Retry that started while the dialog was up.
- A History run never writes the clipboard while a live session is `.inserting` — between the
  inserter's own clipboard write and its ⌘V, it would be pasted into the frontmost app.
- Copy actions are disabled for a pending row. The empty-state copy drops "never audio".

### 3.5 Housekeeping

- At launch, files in `dictations/audio/` older than 24 h that no record names go to the Trash.
  "Names" is a TEXT match over every `.json` file in `dictations/` — day files, quarantined
  `.corrupt-` copies and hand-broken files alike — so a day file that no longer decodes still
  protects its clips; and when any file can't be read at all, the sweep trashes nothing.
- A pending row is stamped (and filed) with the time its clip was committed, not the time it was
  kept (two long attempts can be minutes apart).
- "Paste last dictation" and the pill menu's preview skip pending rows.

## 4 Contract

### 4.1 KleothCore

`DictationDefaults` (`scribeTimeout` is removed):

```swift
public static let scribeBaseBudget: TimeInterval = 25
public static let scribeBudgetPerAudioSecond: Double = 0.5
public static let scribeMaxBudget: TimeInterval = 120
public static let scribeAttempts = 2
public static let scribeRetryDelay: TimeInterval = 1
public static let keptAudioDirectoryName = "audio"
public static let orphanedAudioMaxAge: TimeInterval = 24 * 3600
public static func scribeBudget(forAudioSeconds seconds: Double) -> TimeInterval
```

`Dictation/DictationTranscription.swift` (new):

```swift
public enum DictationTranscription {
    public struct Policy: Sendable, Equatable {
        public var attempts: Int
        public var budget: TimeInterval?        // nil = no wall-clock bound
        public var retryDelay: TimeInterval
        public static func scribe(audioSeconds: Double) -> Policy
        public static let onDevice: Policy
    }
    public struct Result: Sendable { public let response: ScribeResponse; public let seconds: Double; public let attempts: Int }
    /// Thrown when every attempt failed; cancellation is rethrown as is, never wrapped.
    public struct Failure: Error, Sendable { public let underlying: any Error; public let attempts: Int }
    public struct Summary: Sendable, Equatable { public let cause: String; public let detail: String }

    public static func run(_ transcriber: any Transcriber, fileURL: URL, options: ScribeOptions,
                           policy: Policy,
                           onAttemptFailed: @escaping @Sendable (Int, any Error, TimeInterval) -> Void = { _, _, _ in }
    ) async throws -> Result
    public static func isTransient(_ error: any Error) -> Bool
    public static func isCancellation(_ error: any Error) -> Bool
    public static func summary(of error: any Error, attempts: Int) -> Summary
}
```

`DictationLogEntry` gains `audioFileName: String?` (`audio_file_name`), `transcriptionError: String?`
(`transcription_error`), `transcriptionSeconds: Double?` (`transcription_seconds`), `isPending`
(`audioFileName != nil`) and `static func pending(id:timestamp:appBundleId:appName:durationSeconds:audioFileName:transcriptionError:)`.
`DictationInsertMethod` gains `.notInserted` (raw `"none"`); an older build reads it as `paste`.

`DictationLogStore` gains:

```swift
public nonisolated func entry(id: String) -> DictationLogEntry?
/// The candidates some .json file here names, matched as text; nil = a file was unreadable (fail closed).
public nonisolated func audioFileNamesMentioned(among candidates: Set<String>) -> Set<String>?
@discardableResult public func replace(_ entry: DictationLogEntry) throws -> Bool   // false: no such id
```

**Downgrade:** a build older than this one rewrites a whole day file with only its own keys when
it appends or deletes. Pending rows in that file then become empty "pasted" rows and their clips
are orphaned; after an upgrade the launch sweep moves those clips to the Trash a day later
(recoverable from there, but no longer in History).

`Dictation/DictationAudioStore.swift` (new) — the kept-audio folder:

```swift
public struct DictationAudioStore: Sendable {
    public let directory: URL                                   // <dictations>/audio
    public init(dictationsDirectory: URL)
    public func url(forFileNamed name: String) -> URL?              // nil unless a plain file name
    public func keep(_ source: URL, id: String) throws -> String    // moves; returns "<id>.<ext>"
    public func remove(fileNamed name: String)                      // permanent; missing is fine
    @discardableResult public func trash(fileNamed name: String) -> Bool   // false: nothing there / refused
    public func orphans(referenced: Set<String>, olderThan age: TimeInterval, now: Date = Date()) -> [URL]
}
```

### 4.2 KleothCapture

`LocalTranscriber.modelIdentifier(for:)` returns `"whisperkit/<model>"` instead of the type name.

### 4.3 KleothPillUI

```swift
DictationPillFault.transcriptionKept(String, dictationId: String)   // text (length-capped); action .retryTranscription(dictationId:)
DictationPillFault.symbolName: String          // octagon for the rest, circle-path for kept
DictationPillFault.isRecoverable: Bool         // true only for .transcriptionKept → orange tint
DictationPillAction.retryTranscription(dictationId: String)          // button title "Retry"
```

### 4.4 KleothApp

`PillCoordinator.route` sends `.retryTranscription` to the dictation side. `DictationController`:

```swift
@Published private(set) var busyPendingIds: Set<String>
enum PendingTranscriptionOutcome: Equatable { case copied, failed(String) }
func transcribePending(id: String, onDevice: Bool) async -> PendingTranscriptionOutcome
func keptAudioURL(for entry: DictationLogEntry) -> URL?
func deleteDictations(ids: Set<String>) async throws   // now also trashes kept audio
```

Internally the pipeline splits into `run(clip:target:)` (prepare, then a session job) and
`runSession(_:key:settings:)` (steps 6–10), shared by the first run and the pill's Retry; the
polish step becomes a helper shared with the History job.

## 5 Error matrix (replaces the matching rows of the v1 §7)

| Cause | User-visible behaviour | Row |
|---|---|---|
| Scribe times out on the first attempt (length-scaled budget) | pill stays `.transcribing`; retried once after 1 s | — |
| Transient first failure (network, 408/429/5xx) | same | — |
| Scribe fails twice, or once with a non-transient error (401, 422, bad JSON) | audio kept; kept pill with Retry | pending row |
| Audio preparation failed | raw clip kept; kept pill "Couldn't prepare the audio — saved to History" | pending row |
| Esc while transcribing | audio kept; `.warning("Stopped — saved to History")` 3 s | pending row |
| Esc after the transcript, while the polish model is resolved | pasted as heard, like Esc during the polish | ✓ (skipped) |
| Dictation turned off mid-transcription | audio kept silently | pending row |
| Quit mid-transcription | clip deleted (unchanged) | — |
| Keeping failed (move error) | `.failed(.message(…))` as before, clip deleted | — |
| Retry succeeds | pasted; row rewritten in place; audio deleted | resolved |
| Retry fails | kept pill again with the new cause | reason updated |
| Retry of a deleted / transcribed / busy row | pill dismissed | — |
| Row deleted while its pill Retry runs, and the retry fails | plain `.failed(.message(…))` — no Retry for a row that is gone | — |
| Row deleted while its pill Retry runs, and the retry succeeds | pasted; logged as a new row | new row |
| Esc while transcribing, but the clip can't be kept | `.failed(.message("Stopped — the audio couldn't be saved."))` | — |
| History run succeeds | copied to the clipboard; "Copied to the clipboard." | resolved |
| History run fails | the reason under the buttons | reason updated |
| Kept clip transcribes to nothing | pill `.warning("Nothing was heard — the audio is still in History")` / History says so | reason updated |
| Kept audio missing on disk | History says so; only Delete | — |
| Pending row deleted | kept audio → Trash | removed |

## 6 Tests

Core (swift-testing, `Tests/KleothCoreTests`):

- `DictationTranscriptionTests` — the budget table; first-try success; transient then success (two
  attempts, one `onAttemptFailed`); non-transient fails at once; two transients throw `Failure`
  with the last error; cancellation is not retried and not wrapped; a tiny budget times out then
  succeeds; the `isTransient` table; `summary` wording for timeout / offline / 401 / 429 / 503.
- `DictationLogStoreTests` — the key set gains the three keys; a pending row round-trips; `"none"`
  round-trips; `replace` rewrites the right day file among several and keeps order; an unknown id
  → false; `entry(id:)`; `audioFileNamesMentioned(among:)` counts broken and quarantined files and
  fails closed on an unreadable one.
- `DictationAudioStoreTests` — `keep` moves and names the file; `remove` is idempotent; `orphans`
  skips referenced and young files.

App: `swift build --package-path app`; a `pillsandbox --film` strip of the kept pill on the bottom
and right edges; the `dictate` probe's `--file <audio> [--fail-first N]` mode runs a real clip
through the real policy (and, with `--fail-first 1`, through one injected failure and the retry).

### Manual checklist

1. Dictate about a minute of speech → pasted; the day-file row has `transcription_seconds`.
2. Turn Wi-Fi off and dictate a few words → after about a second the pill says "No internet
   connection — saved to History" with Retry; History shows a "Not transcribed" row;
   `~/Kleoth/dictations/audio/` holds one file.
3. Turn Wi-Fi on and click Retry → the text is pasted into the frontmost app; the row now has text;
   the `audio/` file is gone.
4. Start a long dictation, press Esc while it transcribes → "Stopped — saved to History"; the row is
   pending.
5. History → that row → Try again in cloud → "Copied to the clipboard."; ⌘V pastes it.
6. Another pending row → Try again on device → the same through WhisperKit.
7. Delete a pending row → its audio is in the Trash.
8. Pill menu → Paste last dictation pastes the last *transcribed* dictation.

## 7 Out of scope

Keeping audio of dictations that pasted; playing audio in History; keeping a clip on quit; carrying
the "microphone changed mid-dictation" warning over to a retry; Scribe realtime.

## 8 Tasks

1. Core: `DictationDefaults` budget, `DictationTranscription` (+ tests).
2. Core: log entry keys + `pending`, store `entry` / `replace` / `audioFileNamesMentioned`,
   `DictationAudioStore` (+ tests).
3. `LocalTranscriber.modelIdentifier`.
4. Pill contract, view, coordinator route, sandbox `kept` item.
5. `DictationController`: session job split, keep, Esc, pill Retry, History jobs, delete, sweep,
   paste-last; transport timeouts.
6. History UI: sidebar row, detail pane, delete copy, empty state.
7. `dictate --file [--fail-first N]`.
8. Docs: README, CHANGELOG, v1 design doc §6.3 / §6.5 / §7 pointers, CLAUDE.md.
