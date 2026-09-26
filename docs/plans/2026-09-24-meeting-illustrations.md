# Meeting covers: one cuddly illustration per meeting — design

_2026-09-24. Built 2026-09-25 on `feat/meeting-covers`; §10 lists the deviations. One track of the 2026-09-24
planning round; siblings: context-aware dictation, meetings in the pill + mic-usage detection, truncated
summaries + the onboarding Skip dead end._

## 1 The ask

User (dictated): "Explore generating illustrations for meetings using image generation (e.g., DALL-E 3
with images via Codex for local builds, supporting various cuddly styles depending on the meeting
content, or OpenRouter providers)."

The recommendation already given: a cover per meeting, drawn once its summary exists, shown in History,
stored in the meeting folder; Apple's on-device `ImageCreator` first, OpenRouter / Codex as cloud
fallbacks; a small language-model step turns the summary into a safe scene and a style.

What this design keeps, and what it changes:

- **Keep:** one square cover per meeting, drawn after the summary, a file in the folder, a scene step
  through the existing `ChatCompleting` providers, opt-in.
- **Change — no `ImageCreator`.** Apple deprecated it on 2026-06-11. It stops working in macOS 27, which
  has been public since 2026-09-14. On macOS 26 it also refuses to draw while the app is in the background,
  and that is exactly when a finished meeting would get its cover (§2.4). No on-device Apple engine can run
  unattended any more. What Apple still offers is the interactive Image Playground sheet (open question 1).
- **Change — DALL-E 3 is gone** (OpenAI shut it down on 2026-05-12). Codex's built-in `image_gen` draws with
  OpenAI's GPT Image models over the ChatGPT login, and that is the "via Codex" path.
- **Unattended engines:** a **local server** (Ollama's image models: free, on this Mac), **Codex** (the
  user's ChatGPT plan: free per image, about a minute each) and **OpenRouter** (paid per image, 1–7 ¢).
- **Prove the look before building anything** (Lane 0). The last generated art put into the app was
  rejected on sight (§2.2).

## 2 Current state

### 2.1 Where a summary lands

- `MeetingPipeline.run` summarizes best-effort (`Sources/KleothCore/Pipeline/MeetingPipeline.swift:49-66`) and
  saves through `MeetingStore.save` (`:101-109`), which rewrites `meta.json` every time
  (`Sources/KleothCore/Storage/MeetingStore.swift:63-65`).
- The app saves a summary in four places, all in `app/Sources/KleothApp/RecordingController.swift`:
  `runPipeline` (`:1016-1120`, success at `:1102-1108`), `runFullTranscription` (`:1146-1313`, success
  `:1282-1289`), `runOnDeviceTranscription` (`:1338-1471`, success `:1442-1448`) and `summarizeLatestMeeting`
  for `kleoth://summarize-latest` (`:340-407`, save `:392-401`). `kleoth summarize` and the
  `summarize-meeting` skill write summaries outside the app.
- `meta.json` is always re-encoded whole from a snapshot: `MeetingStore.save` (pipeline runs, speaker
  renames, summarize-latest, the CLI), `renameMeeting` (`:132-162`), `activateVariant` (`:252-344`, which swaps
  `cost` for the variant's own, `:312-315`) and `removeTranscription` (`:356-377`, which nils `cost`).
  `runPipeline` starts from a fresh `MeetingMetadata` (`RecordingController.swift:1068-1077`), and
  `runFullTranscription` takes its snapshot (`:1203-1216`) minutes before it saves. `CostBreakdown`
  (`Sources/KleothCore/Models/MeetingMetadata.swift:112-144`) belongs to the transcript variant, not to the
  meeting.
- The serial pipeline queue (`RecordingController.swift:201-205`, `:943-949`) exists so that two heavy
  on-device models never run at once. A queued meeting counts as processing (`processingPaths`, `:116-120`),
  which shows the "Transcribing…" spinner and disables that meeting's actions.
- The output-folder watcher sees only the top level (`:1819-1843`). A file written inside a meeting folder
  does not reload the list. `RecentMeeting` (`:13-66`) is built in `loadRecentMeetings` (`:1538-1624`).

### 2.2 Surfaces

- History row: `MeetingSidebarRow` shows the title, then time · duration · size, then a status badge
  (`app/Sources/KleothApp/Views/HistoryView.swift:405-484`). The context menu is at `:232-262`.
- Detail header: a title plus a row of chips (`Views/MeetingDetailView.swift:130-168`). The toolbar
  (`:362-422`) is already full.
- Settings → Meetings page (`Views/SettingsView.swift:245-249`). Accounts → Usage (`:482-535`) is
  "deliberately the only money surface" and its footer says "Kleoth keeps no tally of its own". The usage
  clients fetch account totals only (`Sources/KleothCore/Usage/ProviderUsage.swift:7-13`). OpenRouter's
  per-model spend endpoint (`GET /api/v1/activity`) needs a management key.
- Provider layer: `AppConfig.makeSummarizer` (`app/Sources/KleothApp/AppConfig.swift:138-145`),
  `ProviderFactory.client(for:)` (`Sources/KleothCore/Providers/ProviderFactory.swift:77-98`), the Codex runner
  arguments (`CodexClient.swift:58-67`) and the Codex probe (`ProviderDetector.swift:82-101`). This account's
  OpenRouter guardrails reject `openai/`, `mistralai/`, `qwen/` and `x-ai/` slugs (`SettingsView.swift:92`).
- Brand: in `app/branding-src/BRAND.md`, generated brand imagery is sculptural objects with "no scenery",
  and Settings and forms are never a surface. On 2026-09-10, generated 3D banner art in Settings was
  "rejected on sight … 3D art looks like generic AI/SaaS stock" (`docs/SESSION-LOG.md:387-393`).
- Image calls this repo has already made:
  - `app/branding-src/generate.mjs` used OpenRouter `chat/completions` with `modalities` to draw 8 images with
    `google/gemini-3.1-flash-image-preview` on 2026-06-02 (`gen.log`).
  - The `/gpt-images` skill drives Codex `image_gen` and got a 1254 px PNG in about 45–60 s
    (`docs/SESSION-LOG.md:622-627`).
  - On this Mac: Codex 0.153.4 reports "Logged in using ChatGPT", and the feature flag `image_generation` is
    stable and on. Ollama is not installed.

### 2.3 Engines (checked 2026-09-24)

| Engine | Draws where | Per cover | Time per image | Status |
|---|---|---|---|---|
| Apple `ImageCreator` | on device | free | — | **Rejected.** Dead on macOS 27; foreground-only on 26 (§2.4) |
| Apple Image Playground sheet | on device (26), Private Cloud Compute (27) | free, within Apple's usage limit | interactive | manual only (open question 1) |
| Local server: Ollama `x/flux2-klein` (4B) | this Mac (MLX) | $0 | not measured; a cold model load is slower | Ollama's image generation has been experimental and macOS-only since 2026-01-20. `POST /v1/images/generations`; 5.7 GB download; 10–12 GB RAM minimum, 16 GB comfortable |
| Codex `image_gen` (GPT Image, ChatGPT plan) | OpenAI | $0 per image; counts against the plan's 5-hour and weekly limits | **45–60 s measured** (2026-09-08) | works here; PNG lands in `~/.codex/generated_images/<thread>/` |
| OpenRouter `google/gemini-3.1-flash-lite-image` (proposed default) | Google | $0.0336 (1,120 tokens × $30/M) | not measured | Google image models passed this account's policy in June |
| OpenRouter `google/gemini-2.5-flash-image` | Google | $0.039 | not measured | same family |
| OpenRouter `google/gemini-3.1-flash-image` | Google | ≈ $0.067 | not measured | higher quality |
| OpenRouter `recraft/recraft-v4.1-flash` | Recraft | ≈ $0.007 | "~1.5 s" (per the listing) | account policy unknown |
| OpenRouter `black-forest-labs/flux.2-klein-4b` | BFL | ≈ $0.014 | not measured | account policy unknown |
| OpenRouter `openai/gpt-image-*` | OpenAI | $0.002–0.04 | — | `openai/` is blocked on this account |

The scene step (§3.3) adds one small call to the summary provider:

- **Cost:** about $0.0002 on OpenRouter's default summary model; $0 on every other provider.
- **Time:** 2–12 s. Measured on this Mac for comparable calls: dictation polish took 2.3–4.9 s on OpenRouter
  and 8–10 s on Claude Code; a trivial Codex call took 12 s.
- **Catalogue:** OpenRouter lists 56 image-output models today (`/api/v1/models?output_modalities=image`).
  The "≈" prices are derived from per-token rates: 4,175 output tokens = one image, which is the example
  OpenRouter's own Images API reference gives.

Sources: [Apple — Deprecation of the ImageCreator class](https://developer.apple.com/news/?id=dz9wvq0r) ·
[WWDC26 — Create high-quality images using Image Playground](https://developer.apple.com/videos/play/wwdc2026/375/) ·
[9to5Mac — macOS 27 on September 14](https://9to5mac.com/2026/09/09/apple-confirms-macos-27-golden-gate-launch-date-september-14/) ·
[OpenAI — DALL·E shut down May 12, 2026](https://community.openai.com/t/deprecation-reminder-dall-e-will-be-shut-down-on-may-12-2026/1378754) ·
[Ollama — image generation](https://ollama.com/blog/image-generation) ·
[Ollama image models: sizes and memory](https://localaimaster.com/blog/ollama-image-generation-models) ·
[OpenRouter — Generate an image](https://openrouter.ai/docs/api/api-reference/images/generate-an-image.md) ·
[OpenRouter — activity (management key)](https://openrouter.ai/docs/api/api-reference/analytics/get-user-activity-grouped-by-endpoint.md) ·
[Nano Banana 2 Lite pricing](https://www.eesel.ai/blog/nano-banana-2-lite-pricing).

### 2.4 Image Playground, read from the SDK on disk

This Mac runs macOS 26.6.2 with Xcode 26.6 and `MacOSX26.5.sdk`; no 27 SDK is installed. The file read is
`ImagePlayground.framework/…/arm64e-apple-macos.swiftinterface`.

- `ImageCreator` is `@available(macOS 15.4)` (`:274-289`):
  - `init() async throws` throws when the Mac cannot draw or the models are not ready.
  - `availableStyles`, `images(for:style:limit:)` (at most 4 images), and
    `images(for:style:options:limit:)` from 26.4.
- Styles (`:196-222`): `.animation` ("animated images"), `.illustration` ("a 2D cartoon style") and `.sketch`
  ("a hand-drawn sketch"). `.externalProvider` (26.0+) is a third-party provider such as ChatGPT, so it is
  never private.
- Errors (`:147-183`):
  - `backgroundCreationForbidden`: "the app is hidden or in the background. Apps must perform image creation
    only when running in the foreground."
  - Also `unsupportedLanguage` and `conceptsRequirePersonIdentity` (26.0+).
- The interactive sheet `imagePlaygroundSheet(isPresented:concepts:…)` is macOS 15.1+ (`:17-35`).
  `imagePlaygroundGenerationStyle(_:in:)` is 15.4+. `imagePlaygroundOptions(_:)` with `personalization` is 26.4+.
- What follows for Kleoth:
  - An unattended cover would be drawn while a menu-bar agent is in the background, which 26 forbids.
  - On 27 the class no longer works at all.
  - On 27 Apple offers only the sheet or view controller, running on Private Cloud Compute with a usage
    limit (WWDC26).

## 3 Behaviour

### 3.1 Settings → Meetings → Covers

This is a plain grouped section after Summarization, with no artwork.

- **Covers**: `Off` (default) · `Local server` · `Codex` · `OpenRouter`.
  - Each engine shows a live status line: "Ollama at localhost:11434 · x/flux2-klein ready" /
    "… · run `ollama pull x/flux2-klein`" / "No server at http://localhost:11434"; "Codex 0.153.4 · signed in" /
    "Not installed"; "API key set" / "No API key".
  - Picking an engine is the opt-in. Nothing is preselected.
- **Draw automatically after the summary**: a toggle, on once an engine is picked. Off means covers are drawn
  only when asked for in History.
- **Style**: `Automatic` (the scene step picks by mood) · `Animation` · `Illustration` · `Sketch` · `Clay`.
- **Image model** (Local server and OpenRouter only): free text. Empty means `x/flux2-klein` or
  `google/gemini-3.1-flash-lite-image`.
- **Caption per engine** (no prices; money stays in Usage):
  - Local server: "Drawn on this Mac by your local server. The scene is written from the summary by your
    summary provider."
  - Codex: "Kleoth sends Codex a one-sentence scene written from the summary — no names, quotes or
    transcript. About a minute per cover; it uses your ChatGPT plan's limits."
  - OpenRouter: "Kleoth sends OpenRouter a one-sentence scene written from the summary — no names, quotes or
    transcript. Each cover is billed to your OpenRouter account (Accounts → Usage)."

Why Off by default:

- Every engine spends something: money, plan quota, or several GB of GPU memory.
- The last generated art in the app was rejected on sight.
- An on-device default is no longer possible: the only on-device engine is a 5.7 GB model the user must
  install.

A cloud engine never receives the summary, only the scene. The summary goes only to the provider that
already summarized the whole transcript.

### 3.2 When a cover is drawn

- **Automatically**, right after a summary is saved:
  - Triggers: the first transcription, Transcribe / Transcribe in cloud from History, Fully transcribe,
    Transcribe on device, and `kleoth://summarize-latest`.
  - Condition: the meeting folder has neither a cover picture nor a `cover.json`.
  - As a result a meeting is never drawn twice, and a re-summary never replaces its cover. Meetings
    summarized before covers were turned on are not backfilled. A meeting whose cover the user removed never
    gets another one automatically.
- **On request**: from History (§3.5) or `kleoth illustrate` (§3.7).
- **Order**: the scene step, then the image.
- **Queues:**
  - A local-server cover joins the pipeline queue (`enqueuePipelineJob`). It waits for a running
    transcription and holds up the next one, because two heavy local models never run at once.
  - Codex and OpenRouter covers run on their own one-at-a-time queue and never delay a transcription.
- **Never blocks the meeting.** A cover never marks the meeting as processing: rename, re-transcribe, Remove
  Transcription and delete stay available. If the meeting is deleted mid-draw, the result is dropped.
- **Covers are decoration.** No popover status line, no "Last attempt failed" card, no notification.
  Failures show only on the cover (§3.5).
- **Covers → Off** cancels queued and running cover jobs.
- **Unsummarized meetings get no cover.** There is nothing safe to draw from: the transcript never goes to the
  scene step. Their tile stays neutral until a summary exists.

### 3.3 The scene

The scene is one call through the summary task's provider: the same `ProviderResolver` resolution and model
as summaries.

- **Input:** the title, the TL;DR, and the first 1,500 characters of the overview. Never the transcript, the
  action items, the per-speaker highlights or the participants.
- **Output:** strict JSON, schema `cover_scene`:
  - `sensitive` (bool);
  - `style` (one of the four);
  - `scene` (English, at most 45 words, whatever language the meeting was in).
- **Rules** (in the system prompt; Lane 0 settles the wording):
  - One to three cute animal characters (otters, foxes, owls, rabbits, bears, hedgehogs, penguins, red pandas)
    or everyday objects act out the meeting's main topic as a gentle metaphor.
  - Never people, faces or hands.
  - Never real names, companies, brands, products, places or events.
  - Nothing to read: no text, letters, numbers, signs, screens or charts.
  - Nothing violent, medical, political or religious.
  - Only what is visible; no art-style words.
- **Sensitive meetings:**
  - `sensitive: true` when the meeting is mainly about health, a person's performance, pay, hiring or firing,
    layoffs, legal disputes, grief, family or relationships, personal money, therapy or coaching, a security
    incident, or anything a participant would not want pictured. When unsure: true.
  - Sensitive means no image call. The meeting keeps the neutral tile (§3.5) and `cover.json` records
    `skipped`. This neutral tile is the neutral fallback for sensitive and unsummarized meetings alike.
- **Style by mood** when the style is Automatic:
  - Animation: upbeat, launches, celebrations.
  - Illustration: planning, reviews, decisions — the usual choice.
  - Sketch: brainstorms, research, retros.
  - Clay: building, fixing, operations.
  - A style fixed in Settings or chosen from New Cover ▸ wins.
- **New Cover** passes the previous scene with the instruction "pick a clearly different idea".
- **Clean-up:** Kleoth strips quotes and digits from the scene (both invite lettering) and caps it at
  400 characters.

### 3.4 The picture

The wording below is the look test's settled text (Lane 0, the user's verdict of 2026-09-25: prompt
revision 3; the scene prompt has since moved to revision 4, §10 addendum). It replaces this section's first draft in two places: the image template drops "generous
margins" and adds the edge-to-edge sentence (a baked-in mat, card or border showed in 10 of 23 test images,
and a matted picture reads as a pale square at 40 pt), and Sketch's washes now fill the square ("on warm
off-white paper" drew a paper margin in 3 of 4 sketches).

- **Prompt:** "A square cover illustration for a meeting. ‹scene› Style: ‹style sentence› One clear focal
  scene, centred, simple uncluttered background; it must read as a small thumbnail. The picture fills the
  whole square edge to edge: no border, frame, mat, card or vignette. Strictly no text, letters, numbers,
  logos, signs, watermarks or captions. No humans, human faces or hands."
- **Style sentences:**
  - Animation: "soft 3D animated-film look, rounded plush-toy characters, warm pastel colours, soft even light."
  - Illustration: "flat 2D storybook illustration, simple rounded shapes, soft pastel palette, subtle paper
    grain, clean outlines."
  - Sketch: "friendly hand-drawn pencil sketch with light watercolour washes that fill the square, warm
    off-white paper tone."
  - Clay: "handmade clay-and-felt miniature diorama, stop-motion look, tactile textures, soft studio light."
- **The scene prompt:** its current text is `CoverSceneWriter.systemPrompt` (revision 4; the §10 addendum
  quotes the two bullets it added to revision 3). Revision 3 is §3.3's rules plus what the test images showed: leave out things that usually carry writing or numbers (clocks,
  calendars, banners, flags, maps, tickets, boxes, books or packages with printed covers, app icons, buttons
  or menus); show the topic as a physical situation, never as software; show feelings through posture, never
  with question marks or other symbols; one close moment with at most two props against a simple backdrop; no
  ribbons, badges, flags or colour pairs that could read as a symbol.
- **Size and file:**
  - Requested at 1:1, about 1K.
  - Whatever comes back (PNG, JPEG or WebP, 1024–1254 px) is centre-cropped to a square and scaled to at most
    1024 px.
  - Saved as `cover.jpg` (quality 0.85, metadata stripped, about 150–300 KB) in the meeting folder, next to
    `cover.json` (§4.1).
  - Metadata: the picture is redrawn into a fresh sRGB bitmap, which strips the source's metadata. ImageIO then
    adds its own bare `{Exif}` dictionary (colour space and pixel dimensions only), next to the sRGB profile
    and `{JFIF}`. No capture metadata survives: no camera, GPS, IPTC or TIFF fields.
- **Retries:**
  - HTTP engines: one attempt, plus one retry 2 s after a transient failure (timeout, network, 408/429/5xx).
  - Codex: a single attempt.
- **Budgets:** OpenRouter 90 s, local server 300 s (allows for a cold 5.7 GB model load), Codex 240 s.
- **Not brand art.** Covers are user content. BRAND.md's object family still governs Kleoth's own imagery;
  Lane 8 gives covers their own section in BRAND.md.

### 3.5 History

**Rows** (only when Covers ≠ Off):

- Every meeting row has a 40 pt rounded-square tile at its trailing edge, in one of three states:
  - the cover;
  - a neutral tile (the still `LyreMark` on a quiet fill) when there is no cover;
  - a small spinner over the neutral tile while a cover is being drawn.
- The tile is trailing so that titles line up whether or not a row has art.
- The tooltip is the scene that was sent.

**Detail header:** a 112 pt tile on the trailing side of the header card, with the same three states. A click
opens a menu:

- With a cover:
  - a disabled line naming the style and engine, e.g. "Illustration · OpenRouter";
  - **New Cover ▸** Automatic Style / Animation / Illustration / Sketch / Clay;
  - **Remove Cover**;
  - **Show in Finder**.
- Without one:
  - **Draw Cover ▸** with the same styles;
  - disabled, with the tooltip "Needs a summary", when there is no summary;
  - preceded by "Skipped: the meeting looked personal" when the scene step said so. Drawing again asks again.
- After a failure:
  - the first line is the reason ("Couldn't draw a cover — No internet connection"), followed by **Try Again**;
  - the neutral tile carries an orange dot;
  - kept in memory only.

**Context menu:** "Draw Cover" or "Draw Covers for N Meetings" for the selected summarized meetings that have
no cover picture. With OpenRouter and N ≥ 5, a confirmation first: "Draw 12 covers with OpenRouter? Each one is
billed to your OpenRouter account." It names no amount.

**What the actions do:**

- **New Cover** keeps the old picture until the new one is saved, then moves the old one to the Trash. A failed
  New Cover changes nothing.
- **Remove Cover** moves the picture to the Trash, turns the tile neutral and writes `removed` to
  `cover.json`. From then on no cover is drawn automatically for that meeting; Draw Cover still works.
- **Remove Transcription** keeps the cover, as it keeps the title. **Move to Trash** takes the whole folder.
- A `cover.jpg` or `cover.png` the user drops into a meeting folder is shown like a drawn one.

**Covers = Off:** no tiles, no header slot, no menu items. The files stay on disk.

**Fit with the planned History redesign:** the tile is a single reusable view (`MeetingCoverTile`) and square
at every size. The planned single timeline can put it in the same trailing slot; a screen recording's poster
frame could use that slot later.

### 3.6 Usage

Settings → Accounts → Usage gets one new row, shown only when covers created in the last 30 days cost
something: "Meeting covers · $0.41 in the last 30 days (12 covers)".

- The amount is the sum of each cover's `cost` as OpenRouter reported it (image plus scene step).
- Codex and local covers cost Kleoth nothing and are not listed.
- The footer becomes: "Account-wide numbers reported live by ElevenLabs and OpenRouter; the covers row adds up
  what OpenRouter reported for each cover."
- This is Kleoth's only tally of its own, because OpenRouter's per-model spend needs a management key.

### 3.7 CLI

```
kleoth illustrate <meeting-dir>... [--engine local|codex|openrouter] [--model <id>]
                  [--style auto|animation|illustration|sketch|clay]
                  [--provider openrouter|local|claude-code|codex] [--force] [--dry-run]
```

- **Defaults:** engine, model and style come from `cover_engine`, `cover_models` and `cover_style` in
  `config.json`. If covers are off there, `--engine` is required. `--provider` picks the scene provider, as it
  does for `summarize`.
- **Skips:**
  - folders without `summary.json` ("no summary");
  - folders with a picture, or a `skipped` or `removed` record ("has a cover — use --force").
  - `--force` replaces the cover; the old picture goes to the Trash.
- **`--dry-run`** runs only the scene step and prints `sensitive`, the style, the scene and the final image
  prompt. It writes nothing and spends one scene call. It is how the prompts get tuned.
- **Output:** one line per meeting, e.g. `drew cover.jpg — Illustration · OpenRouter
  google/gemini-3.1-flash-lite-image · 7.4 s · $0.0341`. The CLI prints costs, as `summarize` already does.
  Exit status 1 if any meeting failed.
- **Why build it:**
  - Backfill: the app never backfills on its own.
  - A live probe for Lanes 1–3: the app package has no test target.

## 4 Contract

### 4.1 KleothCore — `Sources/KleothCore/Covers/` (new)

```swift
public enum CoverStyle: String, Codable, CaseIterable, Sendable {
    case animation, illustration, sketch, clay
    public var displayName: String
    public var promptSentence: String                  // §3.4, verbatim
}

public enum CoverEngine: String, Codable, CaseIterable, Sendable {
    case localServer = "local", codex = "codex", openRouter = "openrouter"   // AIProvider's raw values
    public var displayName: String
    public var defaultModel: String      // "x/flux2-klein" · "" (Codex's own tool) · "google/gemini-3.1-flash-lite-image"
    public var budget: TimeInterval      // 300 · 240 · 90
    public var retries: Int              // 1 · 0 · 1
}

public struct CoverSettings: Sendable, Equatable {
    public var engine: CoverEngine?                    // cover_engine; nil = Off
    public var automatic: Bool                         // cover_automatic; default true
    public var style: CoverStyle?                      // cover_style; nil = Automatic
    public var models: [CoverEngine: String]           // cover_models
    public static func load(config: [String: String]) -> CoverSettings
    public func model(for engine: CoverEngine) -> String
    public var modelsJSON: String
}
```

`Settings` gains `coverSettings: CoverSettings`, parsed in `Settings.load(config:)`.

`cover.json` holds a `CoverRecord`, encoded with MeetingStore's snake_case strategies. The keys are `state`,
`reason`, `engine`, `model`, `style`, `scene`, `scene_provider`, `scene_model`, `created_at`, `cost` and
`seconds`, all acronym-free.

```swift
public struct CoverRecord: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case drawn, skipped, removed }
    public var state: State
    public var reason: String?          // skipped: "sensitive"
    public var engine: String?          // CoverEngine raw value
    public var model: String?
    public var style: String?           // CoverStyle raw value
    public var scene: String?           // exactly what was sent
    public var sceneProvider: String?   // AIProvider raw value
    public var sceneModel: String?
    public var createdAt: String        // ISO-8601 with time
    public var cost: Double?            // USD as reported (image + scene); nil = free
    public var seconds: Double?         // wall clock of the image call (diagnostic)
}

public struct CoverStore: Sendable {
    public static let imageFileName = "cover.jpg"
    public static let recordFileName = "cover.json"
    public static let displayableImageNames = ["cover.jpg", "cover.png"]
    public init()
    public func imageURL(in meetingDir: URL) -> URL?
    public func record(in meetingDir: URL) -> CoverRecord?                 // nil: none or undecodable
    /// `summary.json` present, no picture, no record.
    public func isEligibleForAutomaticCover(in meetingDir: URL) -> Bool
    /// Temp file inside the folder → trash the previous picture → rename → write the record. Never creates
    /// `meetingDir`: a folder deleted mid-draw fails instead of being resurrected.
    public func install(jpeg: Data, record: CoverRecord, in meetingDir: URL, trash: (URL) throws -> Void) throws
    public func writeRecord(_ record: CoverRecord, in meetingDir: URL) throws          // skipped
    public func remove(in meetingDir: URL, now: Date, trash: (URL) throws -> Void) throws   // picture → Trash, record → removed
    public func tally(meetingDirs: [URL], since: Date) -> CoverTally
}
public struct CoverTally: Sendable, Equatable { public var covers: Int; public var cost: Double }

public enum CoverImageFile {
    public static let maxPixelSize = 1024
    /// PNG/JPEG/WebP → centre-cropped square, ≤ 1024 px, JPEG 0.85, no metadata (ImageIO).
    public static func normalize(_ data: Data) throws -> Data
}
```

The scene step:

```swift
public struct CoverScene: Sendable, Equatable {
    public var sensitive: Bool
    public var style: CoverStyle
    public var scene: String                           // sanitized; "" when sensitive
}

public struct CoverSceneWriter: Sendable {
    public static let schemaName = "cover_scene"
    public static let maxOverviewCharacters = 1_500
    public let client: any ChatCompleting
    public let model: String
    public init(client: any ChatCompleting, model: String)
    /// `.jsonSchema(cover_scene)`, maxTokens 1_000, temperature nil, reasoning `.low`.
    public func write(title: String, summary: MeetingSummary, fixedStyle: CoverStyle?,
                      previousScene: String?) async throws -> (scene: CoverScene, cost: Double)
    static func userContent(title: String, summary: MeetingSummary, fixedStyle: CoverStyle?, previousScene: String?) -> String
    static func parse(_ content: String, fixedStyle: CoverStyle?) throws -> CoverScene
    static func sanitize(_ scene: String) -> String    // strips quotes and digits, collapses spaces, caps at 400
}

public enum CoverPrompt {
    public static func imagePrompt(scene: String, style: CoverStyle) -> String   // §3.4
}

public enum CoverError: Error, LocalizedError, Equatable {
    case noSummary, sceneUnreadable(String), noImage, unreadableImage
    case http(status: Int, body: String), refused(String)
}
```

`parse` accepts fenced JSON through `Summarizer.stripCodeFences` (internal to this module; reused as is).
`sensitive` and, when it is false, a non-empty `scene` are required. A missing or unknown `style` falls back to
the fixed style, else `illustration`.

The engines:

```swift
public protocol CoverImageGenerating: Sendable {
    func generate(prompt: String, model: String) async throws -> GeneratedImage
}
public struct GeneratedImage: Sendable { public let data: Data; public let cost: Double? }

/// One client, two dialects of the same Images API.
public struct ImageGenerationClient: CoverImageGenerating {
    public enum Dialect: Sendable { case openRouter, openAICompatible }
    public init(baseURL: URL, apiKey: String?, dialect: Dialect, transport: HTTPTransport)
    // .openRouter:        POST https://openrouter.ai/api/v1/images
    //                     {model, prompt, n: 1, aspect_ratio: "1:1", resolution: "1K", output_format: "jpeg"}
    //                     + HTTP-Referer / X-Title; no `provider` object
    // .openAICompatible:  POST <local_server_url>/images/generations
    //                     {model, prompt, n: 1, size: "1024x1024", response_format: "b64_json"}
    // Response: data[0].b64_json, usage.cost when present. Non-2xx → CoverError.http; a local 404 naming
    // the model → ProviderError.modelMissing(model:hint: "ollama pull <model>").
}

public struct CodexImageClient: CoverImageGenerating {
    public init(executable: URL, runner: any ProcessRunner, environment: [String: String],
                scratchDirectory: URL, codexHome: URL, timeout: TimeInterval = 240)
    /// exec --json --skip-git-repo-check -s read-only --color never -C <scratch> [--ephemeral] -
    public static func arguments(workingDirectory: URL) -> [String]
    /// The /gpt-images wrapper, verbatim: use image_gen exactly once, touch no files, answer with the path.
    public static func prompt(imagePrompt: String) -> String
    // Output: `thread.started` → the newest PNG in <codexHome>/generated_images/<thread>/ (the final
    // message's path as fallback); `turn.failed` / `error` → ProviderError.backend. The thread folder is
    // deleted afterwards. Cost nil.
}

public struct CoverEngineFactory: Sendable {
    public init(settings: Settings, credentials: Credentials, runner: any ProcessRunner, locator: ToolLocator,
                cloudTransport: HTTPTransport, localTransport: HTTPTransport)
    public func generator(for engine: CoverEngine) throws -> any CoverImageGenerating
    // OpenRouter without a key → ProviderError.noProvider; no codex → .notInstalled(tool: "Codex");
    // local uses local_server_url / local_server_key.
    public static let localTransport: URLSessionTransport  // ephemeral, no waitsForConnectivity, 300 s / 600 s
}

public struct CoverDrawing: Sendable {
    public struct Request: Sendable {
        public var meetingDir: URL
        public var engine: CoverEngine
        public var model: String
        public var fixedStyle: CoverStyle?
    }
    public enum Outcome: Sendable, Equatable { case drawn(CoverRecord), skipped(CoverRecord) }
    public init(sceneWriter: CoverSceneWriter, sceneProvider: AIProvider, generator: any CoverImageGenerating,
                store: CoverStore = .init(), retryDelay: TimeInterval = 2,
                now: @escaping @Sendable () -> Date = Date.init,
                trash: @escaping @Sendable (URL) throws -> Void)
    /// Loads summary.json + the meta title, writes the scene, then skips or draws, normalizes and installs.
    /// Uses `engine.budget` / `engine.retries`; cancellation is rethrown as is, never wrapped.
    public func draw(_ request: Request) async throws -> Outcome
    public static func isTransient(_ error: any Error) -> Bool  // KleothTimeoutError, network URLErrors, 408/429/5xx
    public static func message(for error: any Error) -> String  // the History line (§5)
}
```

Nothing changes in `MeetingMetadata`, `MeetingStore`, `MeetingPipeline`, `Summarizer`, `MarkdownRenderer` or
the provider types.

### 4.2 KleothCapture

Nothing.

### 4.3 KleothOnDevice

Nothing, because `ImageCreator` is rejected. If open question 1 flips: a `CoverPlaygroundSheet` view modifier
goes here, with `-weak_framework ImagePlayground` next to FoundationModels (`app/Package.swift:57-68`).

### 4.4 KleothApp

```swift
@MainActor final class CoverController: ObservableObject {       // Covers/CoverController.swift (new)
    static private(set) var shared: CoverController?
    @Published private(set) var busyPaths: Set<String>           // spinner on the tile
    @Published private(set) var failures: [String: String]        // path → §5 line; in memory only
    @Published private(set) var revision: Int                     // bumped on every install / skip / remove
    func summaryWritten(in dir: URL)                               // the automatic hook
    func draw(_ meetings: [RecentMeeting], style: CoverStyle?)     // Draw Cover(s), New Cover, Try Again
    func remove(_ meeting: RecentMeeting)
    func record(for dir: URL) -> CoverRecord?
    func cancelAll()                                               // Covers → Off
}
```

- **Queues:** its own serial `Task` tail (the `pipelineQueueTail` idiom) for Codex and OpenRouter jobs, and
  `RecordingController.enqueuePipelineJob` for the local server. A generation counter drops jobs that were
  queued before Covers was turned Off.
- **`AppConfig` gains:**
  - `makeSceneWriter() async throws -> (CoverSceneWriter, ProviderFactory.Selection)`: the `.summary`
    resolution through the same detector;
  - `coverEngineFactory() -> CoverEngineFactory`;
  - `coverStatus() async -> [CoverEngine: ProviderAvailability]`: local is "ready" when the snapshot's model
    list contains the image model (unverified that Ollama lists image models in `/v1/models`; if it does not,
    the status says only that the server is up, and the first draw reports a missing model); Codex uses the
    snapshot's `.codex`; OpenRouter checks for a key;
  - the Keychain overlay of the four keys.
- **`Keychain.Account`:** `coverEngine = "cover_engine"`, `coverAutomatic = "cover_automatic"`,
  `coverStyle = "cover_style"`, `coverModels = "cover_models"`.
- **`RecordingController`:**
  - calls `CoverController.shared?.summaryWritten(in:)` after each of the four summary saves (§2.1) when that
    save wrote a summary. Once the summary-completeness fix (`2026-09-24-summary-truncation-and-onboarding-skip.md`)
    has landed, summarize-latest and the per-meeting Summarize button both run through its
    `RecordingController.summarize(_:)` — the hook for those two goes there;
  - `RecentMeeting` gains `coverImageURL: URL?` and `coverModifiedAt: Date?`, filled in `loadRecentMeetings`
    (two `stat`s per folder);
  - `coverChanged(in:)` invalidates the folder size and reloads the list, because the watcher cannot see inside
    folders.
- **`KleothApp`:** `@StateObject private var covers = CoverController()` and `.environmentObject(covers)` on
  each scene (next to `KleothApp.swift:18-20`).
- **Views:**
  - `Views/MeetingCoverTile.swift` (new): the three states, the menus, and a thumbnail cache built on ImageIO
    `CGImageSourceCreateThumbnailAtIndex`, keyed by path + mtime + pixel size.
  - `HistoryView`: the trailing tile in `MeetingSidebarRow`, the context-menu items, the batch confirmation.
  - `MeetingDetailView`: the header card becomes an `HStack` with the 112 pt tile.
  - `Views/SettingsCoversSection.swift` (new).
  - `SettingsView`: the section on the Meetings page, the Usage row and footer, and load/commit of the four
    keys. Pickers commit when operated; the model field commits on Return and in `commitAll()`.
- **Logging:** `/usr/bin/log`, subsystem `dev.kleoth`, category `Covers`.

### 4.5 Stored keys and files

| Key | Values | Default |
|---|---|---|
| `cover_engine` | `off` / `local` / `codex` / `openrouter` | `off`, written as `"off"`, never empty (an empty Keychain write deletes the key) |
| `cover_automatic` | `true` / `false` | `true` (anything but `"false"`) |
| `cover_style` | `auto` / `animation` / `illustration` / `sketch` / `clay` | `auto` |
| `cover_models` | JSON `{"local": "…", "openrouter": "…"}` | `{}` |

Meeting folder: `cover.jpg` (the picture) and `cover.json` (`CoverRecord`). `meta.json` is unchanged: there is
no `cover` key (open question 3). Older builds ignore both files, so a downgrade loses nothing.

## 5 Error matrix

Failures show only on the cover's own tile and menu, plus the `Covers` log.

| Cause | What the user sees | `cover.json` |
|---|---|---|
| No summary | neutral tile; Draw Cover disabled with "Needs a summary"; nothing automatic | — |
| No provider can write the scene | "Couldn't draw a cover — No AI provider for the scene (‹reason›)" + Try Again | — |
| Scene answer unreadable | "Couldn't draw a cover — The scene came back unreadable" | — |
| Scene says sensitive | neutral tile, "Skipped: the meeting looked personal"; no image call | `skipped`, `sensitive` |
| Transient image failure on the first attempt (timeout, network, 408/429/5xx) | still drawing; retried once after 2 s (HTTP engines) | — |
| Image fails twice, or with a non-transient error | "Couldn't draw a cover — ‹reason›" + Try Again; an existing cover is untouched | — |
| OpenRouter 401 / 402 | "OpenRouter rejected the key" / "Out of OpenRouter credits" | — |
| OpenRouter 404, data policy | "OpenRouter's data policy on this account allows no endpoint for ‹model› — pick another image model in Settings → Meetings" | — |
| The model refused the prompt (400/403 moderation) | "The image model refused this scene — try New Cover" | — |
| Local server down | "No server at http://localhost:11434 — is Ollama running?" | — |
| Local model missing | "Model 'x/flux2-klein' is not on the local server — run `ollama pull x/flux2-klein`" | — |
| Codex not installed / not signed in | the provider layer's own copy | — |
| Codex usage limit or other refusal | Codex's message verbatim | — |
| Codex finished without an image | "Codex didn't draw an image" | — |
| Undecodable bytes | "The image model returned an unreadable image" | — |
| Write fails (disk full, folder gone, meeting deleted mid-draw) | nothing half-written; the temp file is removed; a deleted meeting shows nothing | — |
| App quits mid-draw | nothing written; the automatic job is not resumed; a Codex child may finish and leave its own thread folder | — |
| Covers → Off mid-draw | job cancelled, nothing written | — |
| New Cover succeeds / fails | old picture → Trash / the old cover stays | `drawn` (new) / unchanged |
| Remove Cover | picture → Trash, neutral tile | `removed` |

## 6 Tests

Core tests (swift-testing, `Tests/KleothCoreTests`):

- **`CoverSettingsTests`**
  - Defaults: off, automatic, Automatic style.
  - `cover_engine` values; garbage reads as off.
  - `cover_automatic` is off only for `"false"`.
  - An unknown `cover_style` reads as auto.
  - `cover_models` parses leniently and round-trips.
  - `model(for:)` defaults per engine.
- **`CoverRecordTests`**
  - A fully populated record encodes exactly the eleven keys of §4.1 and round-trips under MeetingStore's
    strategies.
  - A minimal record (`state` + `created_at`) decodes.
- **`CoverStoreTests`**
  - `imageURL` prefers `cover.jpg` over `cover.png`.
  - The eligibility table: no summary, picture, skipped, removed, fresh.
  - `install` replaces through the injected trash and leaves no temp file.
  - `install` into a missing folder throws and creates nothing.
  - `remove` writes `removed`.
  - `tally` sums cost inside the window and skips removed and older records.
- **`CoverImageFileTests`**
  - A 1254² PNG becomes a 1024² JPEG.
  - 1536×1024 is centre-cropped to a square.
  - Garbage throws.
  - The output carries no metadata properties.
- **`CoverSceneWriterTests`**
  - The request: schema `cover_scene`, `maxTokens` 1_000, no temperature, reasoning low.
  - The user content has the title, the TL;DR and at most 1,500 overview characters, and never action items,
    highlights or speaker names.
  - The previous scene and a fixed style appear when given.
  - Parsing:
    - sensitive → empty scene;
    - a bad style → the fixed style or `illustration`;
    - a missing `sensitive` or an empty non-sensitive scene → `sceneUnreadable`;
    - fenced JSON is accepted.
  - `sanitize` strips quotes and digits and caps at 400.
  - The cost is `usage.cost`.
- **`CoverPromptTests`**
  - For every style, the prompt holds the scene, the style sentence and the no-text / no-humans sentence.
- **`ImageGenerationClientTests`** (MockTransport)
  - OpenRouter:
    - `…/api/v1/images`, bearer header;
    - body keys exactly `model`, `prompt`, `n`, `aspect_ratio`, `resolution`, `output_format`, and no
      `provider`;
    - b64 and `usage.cost` are decoded;
    - 401 / 402 / 404 (data policy) / 400 (moderation) map to the right error.
  - OpenAI-compatible:
    - `…/v1/images/generations`;
    - no `Authorization` header without a key;
    - `size` and `response_format` in the body;
    - an Ollama-style 404 → `modelMissing` with the pull hint.
  - An empty `data` array → `noImage`.
- **`CodexImageClientTests`** (MockProcessRunner, temporary CODEX_HOME)
  - The arguments.
  - The wrapper holds the image prompt verbatim.
  - `thread.started` → the newest PNG is returned and the thread folder removed.
  - The final-message path fallback.
  - `turn.failed` → `ProviderError.backend` with the inner message.
  - No PNG → `noImage`.
- **`CoverEngineFactoryTests`**
  - OpenRouter without a key → `noProvider`.
  - No Codex → `notInstalled`.
  - Local uses `local_server_url` and the key.
- **`CoverDrawingTests`** (MockChatClient + a stub generator)
  - The happy path installs `cover.jpg` and a `drawn` record with cost = image + scene and the scene provider.
  - Sensitive → `skipped`, and the generator is never called.
  - One transient failure → one retry.
  - A non-transient failure → no retry, and the old cover is untouched.
  - Codex (`retries` 0) → no retry.
  - The budget firing → a retry.
  - Cancellation is rethrown unwrapped.
  - No summary → `noSummary`.

App and live checks:

- `swift build --package-path app`.
- `kleoth illustrate --dry-run` on the synthetic set, and by the user on a copy of a real meeting.
- `kleoth illustrate` once per engine on a synthetic meeting folder (local needs a human with Ollama).

### Manual checklist

1. Covers Off (a fresh install): History looks exactly as today. `log stream` shows no `Covers` activity after a
   meeting.
2. Covers → OpenRouter. Record a 1-minute meeting with auto-transcribe on. After the summary the row's tile
   spins, then shows the cover. The folder has `cover.jpg` and `cover.json` (`cost` > 0), and Accounts → Usage
   shows the covers row.
3. New Cover ▸ Sketch gives a sketch; the old picture is in the Trash.
4. Remove Cover gives a neutral tile with the picture in the Trash. Fully transcribe that meeting afterwards: no
   new cover is drawn.
5. A synthetic "performance review" meeting gets a neutral tile, the "Skipped: the meeting looked personal" line,
   and no image call in the log.
6. Covers → Codex, then New Cover: about a minute later there is a cover, and no new folder is left in
   `~/.codex/generated_images/`.
7. Wi-Fi off, then New Cover (OpenRouter): "Couldn't draw a cover — No internet connection", and nothing in the
   popover. That line is expected when the scene provider is OpenRouter or a local server; with Claude Code or
   Codex writing the scene, the line is the CLI's own error, or "Timed out after 60 s" (§10).
8. Select six old meetings → Draw Covers → the confirmation appears → the covers draw one at a time.
9. Local server (needs Ollama with `x/flux2-klein`): start a long on-device transcription, then Draw Cover on
   another meeting. The cover waits for the transcription, then draws.
10. Drop a `cover.png` into an old meeting's folder: it shows after the next list reload.
11. The 112 pt header tile renders full size and opens its menu on click. On a meeting without a summary, the
    disabled Draw Cover ▸ shows the "Needs a summary" tooltip. If possible, check both on macOS 14 or 15 too:
    the menu uses `.menuStyle(.button)` (§10).
12. With an `anthropic/*` summary model on OpenRouter, a cover's scene call succeeds without a relaxed retry
    (the request carries no `reasoning`, §10).
13. Turn Covers → Off while a cover is drawing: the spinner stops, and nothing is written to the folder.

## 7 Out of scope

- Apple `ImageCreator` (dead on macOS 27, foreground-only on 26). The Image Playground sheet, unless open
  question 1 says otherwise.
- Covers for dictations and screen recordings.
- Covers in the popover, the pill or notifications; Quick Look.
- Automatic backfill of older meetings, retrying failed automatic covers later, and a spend cap.
- The cover inside `summary.md` or any other export.
- Image-to-image refinement, reference images, people or personalization, photorealism.
- Local servers without `/v1/images/generations` (LM Studio today, Draw Things' own API).

## 8 Tasks

0. **Spike: prove the look before any product code.** This gates every other lane.
   - Where: throwaway scripts in `.scratch/cover-spike/`.
   - Six synthetic meetings, no real meeting content:
     - an English planning meeting;
     - an English launch;
     - a Russian product review;
     - an English brainstorm;
     - two sensitive ones: a performance review and a doctor's call.
   - The §3.3 prompt runs through the user's summary provider.
   - Four scenes × four styles on OpenRouter `google/gemini-3.1-flash-lite-image` through `POST /api/v1/images`.
     If that endpoint refuses the model, fall back to `chat/completions` with `modalities`, the June path.
   - One image each from `recraft/recraft-v4.1-flash` and `black-forest-labs/flux.2-klein-4b`, to learn this
     account's data policy.
   - Four images through Codex with the `/gpt-images` runner, plus one `--ephemeral` run (does the PNG still
     land?).
   - Record: latency, `usage.cost`, output format, any lettering that leaks into the picture.
   - Deliverable: a contact sheet at 40 pt, 112 pt and 512 px, in light and dark, for the user's verdict.
   - Needs the user's OK to spend about $0.70 and about 5 Codex images.
1. **Core types and storage.**
   - Files: `Covers/CoverTypes.swift` (`CoverStyle`, `CoverEngine`, `CoverSettings`), `CoverRecord.swift`,
     `CoverStore.swift`, `CoverImageFile.swift`; `Config/Settings.swift` gains `coverSettings`.
   - Tests: `CoverSettingsTests`, `CoverRecordTests`, `CoverStoreTests`, `CoverImageFileTests`.
   - Land `CoverTypes.swift` first so that Lanes 2 and 3 can start.
2. **Scene step.**
   - Files: `Covers/CoverSceneWriter.swift`, `Covers/CoverPrompt.swift`, with the wording Lane 0 settled.
   - Tests: `CoverSceneWriterTests`, `CoverPromptTests`.
   - Needs Lane 1's types.
3. **Engines and orchestration.**
   - Files: `Covers/ImageGenerationClient.swift`, `CodexImageClient.swift`, `CoverEngineFactory.swift`,
     `CoverDrawing.swift`.
   - Tests: `ImageGenerationClientTests`, `CodexImageClientTests`, `CoverEngineFactoryTests`,
     `CoverDrawingTests`.
   - Needs Lane 1; `CoverDrawing` also needs Lane 2.
4. **CLI.**
   - Files: `Sources/kleoth/Illustrate.swift`, plus one entry in the subcommand list in `Kleoth.swift`.
   - Live runs per engine on synthetic folders; this is the probe for Lanes 1–3.
   - Needs Lanes 1–3.
5. **App plumbing.**
   - Files: `app/Sources/KleothApp/Covers/CoverController.swift` (new), `AppConfig.swift`, `Keychain.swift`,
     `RecordingController.swift` (the four hooks, the `RecentMeeting` fields, `coverChanged`), `KleothApp.swift`.
   - Needs Lanes 1–3.
6. **History UI.**
   - Files: `Views/MeetingCoverTile.swift` (new), `Views/HistoryView.swift`, `Views/MeetingDetailView.swift`.
   - Needs Lane 5; can start against a stub controller.
7. **Settings and Usage.**
   - Files: `Views/SettingsCoversSection.swift` (new), `Views/SettingsView.swift`.
   - Needs Lane 5; runs in parallel with Lane 6.
8. **Docs.** Last.
   - README: the feature, and for each engine what leaves the Mac.
   - CHANGELOG.
   - BRAND.md: a "Meeting covers" section — user content, not the object family — with the style and guardrail
     sentences.
   - CLAUDE.md: data on disk, the `ImageCreator` decision, the `Covers` log category.
   - This doc's deviations.

Files shared with sibling tracks (merge with care):

- `Settings.swift`, `AppConfig.swift`, `Keychain.swift`, `KleothApp.swift`.
- `RecordingController.swift`: meetings in the pill; the summary flows of the truncated-summary fix.
- `HistoryView.swift` and `MeetingDetailView.swift`: the truncated-summary fix, and the later History redesign.
- `SettingsView.swift`: its Meetings page (pill track), Dictation page (dictation track) and Accounts page.

The provider layer and `Summarizer.stripCodeFences` are used read-only; the truncated-summary track edits
`Summarizer`.

## 9 Open questions

1. **Apple.** `ImageCreator` is out. Should Kleoth add a manual "Make with Image Playground…" item? It is Apple's
   sheet: free within Apple's limit, private, never automatic, and on macOS 27 it draws on Private Cloud Compute.
   **Recommended: not in v1.** It would be a second, interactive way to get a cover, and its look differs from the
   automatic engine's. Revisit if you want a free path without Ollama.
2. **Your engine.** **Recommended: Codex on this Mac.** It is free on your plan, it produces the GPT image look you
   preferred for the brand art, and a minute is fine for a background job. OpenRouter is the fast paid alternative,
   defaulting to `google/gemini-3.1-flash-lite-image` ($0.034 per cover), the only image family proven on this
   account's policy. Switch to Recraft (≈ $0.007) or FLUX.2 klein (≈ $0.014) only if the spike shows they pass the
   policy and look as good.
3. **Where the cover's details live.** **Recommended: a `cover.json` sidecar, not a `cover` key in `meta.json`.**
   Every writer re-encodes `meta.json` whole from a snapshot that can be minutes old: a Fully-transcribe run would
   silently drop a cover recorded during its upload, and older builds drop unknown keys. If you want one file, the
   key is `cover` (the same fields) plus a merge-before-save in every writer.
4. **History rows.** **Recommended: a tile on every row while covers are on** (the neutral lyre where there is no
   cover), plus the header tile. The row is where a picture helps you find a meeting; in the header alone it is
   decoration.
5. **Usage.** **Recommended: yes, one Kleoth-summed row for cover spend.** OpenRouter's per-model spend needs a
   management key, and a per-image opt-in feature should show what it costs.
6. **Spike first.** **Recommended: approve about $0.70 of OpenRouter credit and about 5 Codex images on synthetic
   meetings before any product code.** The styles and their wording are settled from the resulting contact sheet.

## 10 Deviations (implementation, 2026-09-25)

Where the build differs from §3–§5, one line each with its reason. The wording changes from the look test are
in §3.4 itself.

**Core API (§4.1)**

- `CoverError.dataPolicy(model:)` added: §5's data-policy line names the model, and `.http` carries none.
- `CoverDrawing.message(for:engine:)` gained an optional `engine`, plus `reason(for:engine:)` (the line without
  the prefix, for the CLI's `failed — …`), `failurePrefix` (for the app's own "No AI provider for the scene (…)"
  line) and
  `budgetOverride` (tests only: 90–300 s budgets can't be waited out in a test). The engine tells a Codex "no
  image" from an HTTP one, and a local server's HTTP error from OpenRouter's.
- `CoverDrawing.loadInputs(meetingDir:)` added: `draw` and `kleoth illustrate --dry-run` read the scene's inputs
  the same way. The title is the summary's own, then `meta.json`'s, then the folder name (blank counts as
  missing), because the meta title may still be a placeholder.
- `CoverSettings` gained `parseModels`, `settingModel(_:for:)` and `engineStorageValue`/`styleStorageValue`:
  the app has to persist a per-engine model, and to write Off as `"off"` and Automatic as `"auto"`, never empty.
- `settingModel(_:for:)` drops the override for the engine's own default, as it does for an empty value: the
  default is the field's placeholder, so retyping it is not a pick, and a pinned copy would shadow a later
  change of default.
- `CoverDrawing.sceneBudget` = 60 s (scene calls measured 2–12 s) bounds the scene step, which §3.4 left
  unbounded: the chat clients' `URLSessionTransport()` waits for connectivity with a 1,200 s request timeout, so
  with the scene on OpenRouter and the Wi-Fi off a cover spun until the network came back and held up the cloud
  queue. The scene step is not retried (the retry is the image call's), so a hang reads "Timed out after 60 s";
  `budgetOverride` replaces this budget too, and `kleoth illustrate --dry-run` runs its scene call under it.
- `CoverStore` gained `hasSummary(in:)`, `hasRecord(in:)` and `CoverStoreError.meetingFolderMissing`: History
  and the CLI need the checks one by one, and a folder deleted mid-draw must fail with a named error, never be
  recreated.
- Small additions: `CoverStyle`/`CoverEngine` are `Identifiable` (SwiftUI pickers), `CoverEngine.offValue` and
  `takesModel`, `CoverPrompt.guardrail`, `CoverTally.empty`, `CoverEngineFactory.codexHome` and
  `codexScratchDirectory`, and `CodexImageClient.arguments(workingDirectory:ephemeral:)`.

**Engines**

- `CodexImageClient.usesEphemeral = true`, from the look test's verdict: the PNG still lands where the client
  looks, and Codex keeps no session transcript of the prompt. The thread folder is still deleted. (Planning
  finding F4, a fallback for a missing verdict, is moot.)
- `CODEX_HOME` is set for the child to the folder the client reads, so the two can't disagree. An empty
  `CODEX_HOME` counts as unset, because `URL(fileURLWithPath: "")` is the working directory.
- The Codex thread id must be alphanumerics, `-` and `_` only: it is joined onto `generated_images/` and that
  folder is deleted afterwards, so an empty, `..` or NUL-carrying id could delete them all. The last-message
  path fallback must be a regular file.
- OpenRouter's image calls go over `CoverEngineFactory.cloudTransport` (no `waitsForConnectivity`, 100 s request,
  120 s resource; both above the 90 s budget) in the app and the CLI. `URLSessionTransport()` waited for
  connectivity, so offline meant two 90 s budgets and "Timed out"; now it fails at once with
  `URLError(.notConnectedToInternet)`, which is transient: one retry after 2 s, then "No internet connection".
  The scene call gets the same session (`ProviderFactory.transport`, set in `AppConfig.makeSceneWriter()` and
  `kleoth illustrate`; only the OpenRouter chat client reads it), so an offline OpenRouter scene fails at once
  too, unretried; summaries keep the waiting transport. "No internet connection" is therefore the expected line
  when the scene provider is OpenRouter or a local server; with Claude Code or Codex writing the scene, the line
  is the CLI's own error, or "Timed out after 60 s".
- A local server that refuses the connection is `ProviderError.unreachable(url:)`, not transient: §5's line
  needs the URL, and retrying a server that isn't listening only costs 2 s.
- A local server's HTTP error reads "The local server answered HTTP N" (F5): OpenRouter's copy ("rejected the
  key", "Out of credits") would be wrong for it.
- `anthropic/*` scene models get no `reasoning` (§4.1 says `.low`): OpenRouter turns `low` into a 1,024-token
  thinking budget, which is above the 1,000-token cap, so the strict request would fail and only the relaxed
  retry, without the schema, would save it.
- A 200 answer that isn't JSON is `.noImage`; base64 that decodes to nothing is `.unreadableImage`.
- The scene step's HTTP error reads "The scene model answered HTTP N": `OpenAICompatibleClient` throws
  OpenRouter's error for a local scene server too, and its copy would name OpenRouter and carry the raw body.
- A `CocoaError` (disk full, a failed Trash move) reads as its `localizedDescription`, not a raw `NSError` dump.
- The cancel wins in both steps: a failure that arrives while the job is cancelled (Covers → Off) is rethrown
  as `CancellationError`, so no error line shows for it.
- A signed-out Codex surfaces as Codex's own message; Settings shows "Not signed in" (F13). The image path
  doesn't check the login first, so §5's "provider layer's own copy" appears only in Settings.

**Behaviour**

- A sensitive answer on New Cover, for a meeting that already has a picture, writes nothing: the picture and
  its record stay as they are (§3.5: a failed New Cover changes nothing).
- Local status lines carry the "Ollama at " prefix (§3.1), and `<model>:latest` also counts as ready (F10):
  Ollama's `/v1/models` lists `name:tag`, so a pulled default shows as `x/flux2-klein:latest`.
- The covers Usage row sits inside the keys-present branch of Accounts → Usage (F6). The tally is computed
  before the key check, but with no key the section shows only its "add a key" state. An OpenRouter cover
  needs a key anyway. The footer changes in both branches.

**CLI (§3.7)**

- Each output line starts with `<path>: `, e.g. `…/planning-en: drew cover.jpg — Clay · OpenRouter
  google/gemini-3.1-flash-lite-image · 5.1 s · $0.0336`: a multi-folder backfill has to say which line is whose.
- "Covers are off" exits 1 (a config state, as `summarize` does); argument errors exit 64.
- An explicit `--style auto` means Automatic and overrides a style fixed in `config.json`; only an absent
  `--style` falls back to `cover_style`.
- `--dry-run` is exempt from the has-a-cover skip (not from "not a directory" or "no summary"), and it always
  shows the first-draw prompt: it passes no previous scene, so it can't preview New Cover's.
- A sensitive skip on a meeting that already has a picture prints "skipped — the meeting looked personal (the
  existing cover was kept)", since nothing was written.

**App (§4.4, §3.5)**

- `RecentMeeting.hasSummary`: the tile has to know whether Draw Cover is enabled ("Needs a summary") without
  reading files in a view.
- `CoverController` gained `engine` (published, so views follow Settings), `settingsChanged()` and
  `forget(_:)`, which drops a deleted meeting's state and cancels its running job.
- `draw(_:style:)` takes a `CoverStyleChoice` (`.settings` / `.automatic` / `.fixed`), not `CoverStyle?`: nil
  couldn't tell "use Settings" from "Automatic". An explicit New Cover ▸ or Draw Cover ▸ pick wins over the
  Settings style, Automatic included; Try Again, the batch and the automatic hook use Settings. The enum lives
  in KleothCore beside `CoverStyle`, so its mapping is tested.
- "One at a time" holds per generation: a job queued before Covers → Off is dropped, and one started after
  Covers is turned back on can overlap a cancelled job's last moments.
- The header menu is its own view, `MeetingCoverMenu`, around `MeetingCoverTile`.
- The menus use `.menuStyle(.button)` with `.buttonStyle(.plain)`: on macOS 26 a `.borderlessButton` menu kept
  only a label's text or image and collapsed the 112 pt tile to an empty button of about 6 × 14 pt. Unverified
  on macOS 14–15 (§6 item 11).
- "Draw Covers for N Meetings" and the batch confirmation leave out meetings already busy: the controller
  skips them anyway, so counting them would overstate N.
- Remove Cover is disabled while that meeting's cover is drawing: otherwise the running job would install over
  `removed` and undo the removal.
- Settings → Covers: the toggle and the Style picker write only a real change, so a re-seed writes nothing;
  the model field is compared trimmed; each status line shows "…" until its first check, as the AI-provider
  rows do.

**Known gaps (accepted)**

- The covers Usage row sums the current `drawn` records: a replaced or removed cover, and a sensitive skip's
  scene call, drop out, so it can count less than was spent. It is computed when Settings opens and on Refresh.
- A Codex run that hits its budget can leave its thread folder behind.
- A kill in the millisecond between the temp file and the rename can leave a `.cover-<uuid>.tmp` in the folder
  until it is an hour old; then the next launch, or the next cover saved in that folder, removes it (addendum).

**Addendum (2026-09-25): the full-width cover** — plan `.scratch/step1/2026-09-25-covers-hero-plan.md` (local).
The user's verdict after a day with covers: the animals are the best part ("even more abstract" is welcome); the
tile was too small to notice and could not be opened full size. Wanted: the cover full width at the top of the
meeting page, the title and headline under it, parallax on scroll. Each deviation this brought from §3–§7, with
its reason:

*Meeting page (§3.5 "Detail header", §4.4)*

- The 112 pt header tile is gone. The page opens with the cover across the detail pane's full width, cropped to
  a 2:1 band: height = width ÷ 2, clamped to 200–400 pt (`CoverHeroGeometry`). Under it, on the page background
  (no card): the title (`.title`, semibold), the TL;DR as its headline, then the chip row. The picture is drawn
  band height + 2 × 80 pt tall and lags the page by 0.35 into that hidden 80 pt, so the slide never shows a gap;
  pulled past the top, the band stretches about its bottom edge. Neither happens under Reduce Motion. Measured
  with `visualEffect` + `.scrollView` (macOS 14), with no `GeometryReader` in the scroll content. Why this and not
  a blurred ambient band or the title over the picture: the user asked for the picture itself full width, with
  the text under it (the plan records both rejected patterns).
- The band rests below the toolbar, not under it: the toolbar keeps the title legible, macOS 26's soft scroll
  edge would fog the top of the art, and the crop already shows only the middle half of the square. On macOS 26
  the band's `.scrollView` minY is 0 at rest although the page's `NSScrollView` has a 52 pt top inset (probed).
- The band takes the width the scroll content offers (narrower with "Show scroll bars: Always"); only its height
  follows the pane. The picture is decoded once, at the file's own size (a constant 2,048 px request), so a live
  resize never decodes it again.
- One scroll for every page state: the audio player, the progress banner and the failure card are scroll content
  now (they were pinned above the summary), and "Not transcribed yet" and the load error scroll too, centred when
  they fit. The plan kept those two states out of the scroll; but a reverted meeting keeps its cover, and a 400 pt
  band would push the Transcribe buttons off a default-size window. One view tree also keeps the player playing
  when a meeting finishes transcribing, loses its transcript or switches variant.
- The TL;DR card is dropped on this page (`MeetingSummaryView.showsTLDR`): the headline is the TL;DR. Copy Summary
  still includes it.
- Quick Look is in (§7 had it out of scope): a click on the band shows the picture full size in the system panel
  (`.quickLookPreview`; Esc closes it). The panel closes when the picture changes or goes (New Cover, Remove
  Cover). `import QuickLook` autolinks `_QuickLook_SwiftUI`, which links QuickLookUI; no
  Quartz link is needed.
- The menu is unchanged in wording and enablement (`MeetingCoverMenuItems`), behind three doors: the band's
  right-click, a `…` button in its bottom-trailing corner, and, without a picture, a chip in the chip row:
  "Draw Cover", "No cover" (skipped; its menu leads with "Skipped: the meeting looked personal"), "Cover failed"
  (orange; its menu leads with the reason and Try Again), or a "Drawing cover…" spinner. A New Cover over a
  picture keeps the old one and shows a "Drawing a new cover…" capsule by the `…` button, not a wash: a wash over
  a 400 pt band is heavy. The band's tooltip is the scene, as before.
- No chip without a summary: there is nothing to draw from, and the "No summary yet" pill already says so. §3.5's
  disabled Draw Cover with the "Needs a summary" tooltip can no longer be reached. A running job still shows its
  spinner chip.
- No chip while Covers is Off, a demo launch included: nothing can be drawn there. The menu entries that change a
  cover (Draw Cover, New Cover, Remove Cover, Try Again) are disabled with no engine, and `CoverController.remove`
  returns without one; Show in Finder stays.
- VoiceOver: the band is one button, "Meeting cover, show full size", with the click as its action; the chip says
  its state as its value.

*History (§3.5 "Rows")*

- The tile is 56 pt, not 40, and only on rows with a picture or a running job; a row with neither has no tile.
  At 56 pt the neutral lyre repeated down the list would be the loudest thing in the sidebar, and the art is what
  should be noticed. The lyre stays under a first cover's spinner (and for an unreadable file).
- A failure no longer dots the row's tile: the page's chip carries it.
- The context menu's Draw Cover / Draw Covers for N Meetings still needs an engine, so a demo launch shows neither.

*Scene prompt (§3.3, §3.4): revision 4*

`CoverSceneWriter.systemPrompt` gains two bullets, verbatim (each one line in the prompt):

> - No photos, photographs, picture frames, framed pictures, posters, paintings, portraits, mirrors, or screens
>   showing a picture — a picture inside the picture invites faces and lettering, and often comes out blank.
>   Never these words in the scene, even when the meeting is about them.
> - Prefer the abstract to the literal: one physical metaphor for the main topic, built from the characters and
>   their one or two props, rather than a re-staging of the conversation. Take the setting from the meeting's
>   own world (a riverbank, a workshop, a garden, a kitchen, a hillside) and let the action carry the idea —
>   something joined, balanced, mended, carried across, shared out, sorted, grown or set free. Invent it for this
>   meeting; do not repeat a stock image. Never a meeting room, office, desk, conference table or laptop.

- Why: one live run drew blank picture frames. "Never these words…" came after a dry run named photos because
  the summary was about a photo upload queue. The metaphor bullet names kinds of action, not objects: a first
  draft's example objects (stacked stones, a lantern, nests) came back in every dry-run scene.
- Checked free with `kleoth illustrate --dry-run --provider claude-code` on three fictional fixture meetings,
  before and after: no scene names a picture, a screen, a room or a desk, and the sensitive meeting stays
  `skipped`. Still loose, as in revision 3: the prop cap and "no lighting words". The model still reaches for
  nests and lanterns unprompted, and once drew a fictional product's name as a picture puzzle.
- Unchanged: the characters, the sensitivity rule, the style rules, the schema and the "tiny thumbnail" line (the
  row tile still needs it). The image prompt (§3.4) is unchanged.

*Core (§4.1)*

- `MeetingStore.makeEncoder()` writes `.withoutEscapingSlashes`, so `cover.json` no longer reads `google\/gemini…`.
  It is the encoder of every meeting file and, through `DictationLogStore`, of the dictation day files; every
  reader decodes both forms.
- `CoverStore.sweepTemporaryFiles(in:now:maxAge:)` removes `.cover-*.tmp` files older than an hour (a younger one
  may be a draw in flight, the CLI's or the app's). `install` sweeps its own folder first; the app sweeps every
  `meeting-*` folder once at launch, off the main actor (`CoverController.sweepTemporaryFilesAtLaunch()`, called
  from `AppDelegate`, so a demo launch never sweeps). This closes the last known gap above for files an hour old.
- `CoverHeroGeometry` added: the band's rules as pure, tested math. Core tests: 664 → 673.

*Demo mode (`docs/plans/2026-09-24-demo-mode.md`)*

- `CoverController.showsCovers` (an engine is picked, or this is a demo launch) gates every surface that only
  shows a cover. A demo launch keeps Covers Off, so it shows the pictures its folder holds and can draw or remove
  none.
- A `cover` director script films the page with a cover at rest, at 140 pt and at 320 pt, in light and dark, then
  a page without one: seven stills, written by `make-app-demos.sh` when `KLEOTH_DEMO_FRAMES=<dir>` is set.
  Scroll offsets are now measured from the page at rest (the toolbar inset added back): the one-scroll page
  runs under the toolbar, and the `meeting` film's scroll stops need the same correction.

*Manual checklist (§6)*

- Item 11 now reads: click the band → Quick Look with the full square, Esc closes it; right-click and `…` open the
  menu; a summarized meeting without a picture has the chip. Add: Reduce Motion (no slide, no stretch), the rubber
  band at the top, a window resize, "Show scroll bars: Always", a History row at 56 pt.

*Follow-ups, not built*

- Landscape (16:9) covers: a paid look test (OpenRouter `aspect_ratio`, Codex `image_gen` sizes, and whether "one
  close moment" survives the format), a change to `CoverImageFile.normalize` (it centre-crops to a square) and a
  rule for the 56 pt row tile (crop or letterbox).
- A bottom-pinned mini-player (`safeAreaInset(edge: .bottom)`), now that the player scrolls away with the page.
- A cover in the README demo data and screenshot: `make-demo-data.ts` draws none, since that is a paid call.
- The band's rest position on macOS 14–15: probed on macOS 26 only. If those report the toolbar inset inside
  `.scrollView`, the band would rest slightly stretched (about 1.16 at a 330 pt band).
