# Kleoth — brand brief for generated imagery

Read this before generating any image for Kleoth (the `/gpt-images` skill looks for it here).
It records the visual family the user chose on 2026-09-06 over the earlier golden-lyre-on-purple
set, and the prompts that produced the accepted pieces.

The product: a restrained native macOS meeting recorder and transcription utility. "Kleoth" is
Greek *kleos* — "that which is heard". In dictation the user may say "Cleos"; it is the same thing.

## The family

- **Objects, not scenes.** One or two small sculptural objects that stand for the state
  (a microphone, a transcript sheet, a document with a clock). Nothing ambient, no desks, no people.
- **Material:** satin silver / brushed aluminium and pale ceramic. Softly bevelled edges, simple
  geometries, minimal industrial design, "quiet precision". Recessed graphite details for lines.
- **Accent:** muted teal, used only for the thing that carries meaning (waveform bars, one
  highlighted line). Roughly `#5f9c93` in the renders; the app itself is system-accent-driven, so
  the illustrations must not depend on a specific UI accent.
- **Light:** broad, diffuse studio lighting; neutral silver and graphite shading that reads on
  both a white and a charcoal interface. No exaggerated chrome reflections.
- **View:** near-front with a slight three-quarter depth. Objects occupy ~75 % of the canvas with
  generous transparent margin. Strong silhouette readable at 132 px (the empty-state slot).
- **Canvas:** square, genuinely transparent alpha. The app shows these floating, with its own
  soft shadow — never bake a ground shadow, platform or enclosing tile into the art.
- **The mark:** the Greek lyre, in the "green stone" carved silhouette
  (`app/branding-src/kleoth-lyre/`, SwiftUI `LyreMark`). Generated imagery may reference it
  (e.g. the app icon) but the in-app glyphs are vector, not generated.

## Forbidden

No words or letters. No platform or pedestal. No enclosing square or app tile (except the app
icon, which is the tile). No scenery. No sparkles, glow, bokeh or particles. No purple, no gold
(the retired palette). No glass refraction. No tiny perforations or fine detail that dies at 132 px.
No extra props beyond the named objects. One isolated illustration, never a sheet or a mockup.

## Surfaces and sizes

| Surface | Slot | Asset | Notes |
|---|---|---|---|
| Empty states (History, detail, not-transcribed) | 132 pt (120 pt for not-transcribed) | `Sources/KleothApp/Resources/Empty*.png`, 528 px | source at 1254 px in `branding-src/cleos-v2/src/` |
| App icon | 1024 × 1024 opaque | `branding-src/Kleoth.iconset` → `bundle/Kleoth.icns` | full-bleed, subject at ~60 %, macOS masks the squircle |
| Menu bar | 18 pt template | `Resources/MenuBarGlyph.png` | derived from the lyre vector, never generated |
| README hero / social preview | 1600×420 / 1280×640 | `docs/assets/` via `readme-images/generate.swift` | composed from the icon; regenerate after an icon change |

## App icon (chosen 2026-09-08)

`branding-src/icon-v2/icon-a-charcoal.png` — the satin-silver lyre with teal strings on a deep
charcoal graphite backdrop (candidates A–D and their prompts in `icon-v2/`; `dock-preview.html`
shows them masked). Built into `Kleoth.iconset` + `bundle/Kleoth.icns` by
`swift app/branding-src/make-iconset.swift <artwork.png>` (Apple's 824-px rounded body on a
transparent 1024 canvas). Lesson: the image model cannot count strings — the same prompt gave
six, seven and (as an edit asking for seven) five — so never re-roll an accepted icon for a
string count; the in-app `LyreMark` has seven and nobody will compare.

## Canonical prompts (accepted 2026-09-06, Codex built-in image_gen)

Reuse the sentences verbatim and change only the subject line.

**EmptyNoMeetings** — "Create a production-ready raster spot illustration for the empty meeting
library in Kleoth, a restrained native macOS meeting recorder and transcription utility. Square
composition, genuinely transparent alpha background. One small sculptural silver satin aluminum
desktop microphone, upright, with a simple rounded capsule head and slim stand, paired with a
single flat pale-silver speech bubble subtly behind it. Muted teal only in five short recessed
waveform bars on microphone front. Quiet precision, minimal industrial design, softly beveled
edges, broad diffuse studio lighting, clean strong silhouette readable at 132px. Near-front view
with very slight three-quarter depth. Objects occupy 75% of canvas with generous transparent
margin. Neutral silver and graphite shading compatible with both white and charcoal interfaces.
No platform, no enclosing square, no scenery, no lettering, no sparkles, no glow, no purple, no
gold, no exaggerated chrome reflections, no tiny perforations, no extra props. Output one
isolated illustration, not a sheet or interface mockup."

**EmptySelect** — same family sentence; subject: "exactly two slightly offset upright silver
transcript sheets, front sheet with three neatly recessed horizontal graphite lines and one short
teal line, back sheet mostly hidden; a small simple satin silver pointer arrow rests against the
lower right corner to imply selection."

**EmptyNotTranscribed** — same family sentence; subject: "one upright softly beveled silver
document sheet, with five recessed muted teal vertical waveform bars across its upper half and
two short recessed graphite horizontal transcript lines below. A small satin silver clock dial
overlaps its lower right corner, with just two graphite hands, no numbers or ticks, suggesting
pending transcription." Readable at 112 px.

Full texts: `app/branding-src/cleos-v2/prompts.json`.
