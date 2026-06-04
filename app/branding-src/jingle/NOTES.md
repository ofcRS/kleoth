# Kleoth welcome chime — provenance

Asset: `app/Sources/KleothApp/Resources/WelcomeChime.m4a`
Referenced by app code via `Bundle.module` (`WelcomeChime.m4a`). The SwiftPM
`KleothApp` target already `.process`-es the whole `Resources/` dir, so no
`Package.swift` change was needed.

## Which plan succeeded: Plan B (offline synthesis)

**Plan A (ElevenLabs Sound Effects API) failed — not viable on this key.**
`POST https://api.elevenlabs.io/v1/sound-generation` returned **HTTP 401**
for all three prompt candidates, body `detail.status = "missing_permissions"`
(the account's key is scoped and lacks the `sound_generation` permission —
consistent with the known-scoped key whose `/v1/user/subscription` also 401s).
No bytes were ever produced; the 146-byte JSON error files were deleted.

The three prompts that *would* have been used (kept for the record):
1. "Short elegant harp glissando rising upward, warm and inviting, clean studio
   recording, gentle reverb tail, app startup logo sound"
2. "Three soft ascending plucked lyre notes, ancient Greek kithara, intimate,
   warm room tone, short app welcome chime"
3. "Gentle harp arpeggio flourish, bright but calm, premium app onboarding
   sting, fades naturally"

**Plan B — `synth_chime.swift` (run with `swift synth_chime.swift`).**
Karplus-Strong plucked-string synthesis, pure AVFoundation + Accelerate, no
deps, deterministic (seeded LCG noise burst → reproducible output).

- Notes: ascending **D-major arpeggio D4 · F#4 · A4 · D5** (equal-tempered,
  A4 = 440 Hz) — a warm kithara/lyre flourish fitting the Greek-lyre brand
  ("kleos = that which is heard").
- 0.18 s between plucks; each note rings ~1.25 s with an exponential amplitude
  envelope; 4 ms soft attack (no click); higher notes a hair brighter and
  slightly quieter so the top note doesn't dominate.
- Master: smooth quadratic fade-out tail, then **peak-normalized to −3 dBFS**.
- Intermediate: `WelcomeChime.wav` — 44.1 kHz, mono, Float32.
  Measured: **2.340 s**, peak −3.00 dBFS, RMS −14.13 dBFS, **0 clipped
  samples**, 76.5% non-zero frames (rings throughout, decays to silence).

  ⚠️ Build gotcha (fixed in the script): `AVAudioFile` only finalizes the
  RIFF/`data` chunk sizes in the WAV header when the object is **deallocated**.
  A top-level `let file` in a Swift script lives until process exit and the
  flush was unreliable → first run produced a 0-duration WAV (`afinfo`:
  "audio bytes: 0"). Fix: write inside a `func writeWav()` scope so the file
  releases (and flushes the header) before we read it back.

## Final encode
`afconvert -f m4af -d aac -b 96000 WelcomeChime.wav WelcomeChime.m4a`
Result: m4af / AAC, **1 ch, 44 100 Hz, 2.340 s**, ~15 KB, `afplay` exit 0.
(Reported bitrate ~38 kbps because AAC VBR encodes this sparse plucked signal
well below the 96 kbps ceiling — expected, fine for a chime.)

## Files here
- `synth_chime.swift` — the generator (re-run anytime; output is deterministic).
- `WelcomeChime.wav` — intermediate, peak-normalized −3 dBFS source.
- `WelcomeChime.m4a` — the AAC encode (copied to Resources/).
- `NOTES.md` — this file.

No API keys are stored in this directory or in the script.

## Update 2026-06-04 (later): Plan A retried and SUCCEEDED

The user added the missing `sound_generation` permission to the API key.
All three prompts generated successfully (HTTP 200, ~2.5 s each):
`eleven-1.mp3` (harp glissando) · `eleven-2.mp3` (three plucked lyre notes) ·
`eleven-3.mp3` (harp arpeggio flourish).

**Bundled chime = `eleven-1.mp3`** (the rising harp glissando — closest to the
"app startup logo sound" brief), converted via
`afconvert -f m4af -d aac -b 96000 eleven-1.mp3 ../../Sources/KleothApp/Resources/WelcomeChime.m4a`.

To audition and swap: `afplay eleven-2.mp3`, then re-run the afconvert line
with the preferred file and rebuild (`bash app/make-app.sh release`).
The original offline synthesis is kept as `synth-chime.m4a` (+ the script).

## Final choice 2026-06-04: `chime3-feltpiano-3chords.mp3`

The eleven-* harp candidates were rejected by ear ("scary"); a second batch of
notification-style timbres (chime2-*) surfaced felt piano as the keeper, and a
third batch added the requested extra note. **Bundled chime = three warm felt-
piano chords rising (2.4 s)**, chosen by ear from 12 generated candidates:

  afconvert -f m4af -d aac -b 96000 chime3-feltpiano-3chords.mp3 \
    ../../Sources/KleothApp/Resources/WelcomeChime.m4a

Prompt: "Soft felt piano, three warm major chords rising one after another,
cozy reassuring app welcome sound, intimate, gentle touch, clean and dry"
(duration_seconds 2.4, prompt_influence 0.6).
