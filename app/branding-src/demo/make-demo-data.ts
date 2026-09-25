#!/usr/bin/env bun
// Demo data for the README's app films: a stand-in for ~/Kleoth, made fresh each run.
//
//   bun app/branding-src/demo/make-demo-data.ts <out-dir> [--provider claude-code|codex|local|openrouter]
//
// Every meeting and the recording are fictional (meetings/*.txt, recording.txt), and every
// artifact is produced by Kleoth's own code:
// - meetings: each line is spoken by a macOS `say` voice onto its speaker's channel
//   (mic.m4a = you, system.m4a = them, meeting.m4a = both, as the recorder lays them out),
//   then the `localtranscribe` probe transcribes them ON DEVICE and summarizes them with
//   --provider (default claude-code: the fictional transcripts go to your Claude Code
//   account; `local` keeps them on this Mac if a local server is running);
// - the screen recording: the Q4 roadmap slide from demo-screen.gif (pillsandbox --slides)
//   with a spoken narration, and its word timings from the app's on-device recording
//   pipeline (screenrec --sidecar).
// Nothing is read from or written to your real ~/Kleoth. Needs ffmpeg; ~5 min.
import { $ } from "bun";
import { mkdirSync, mkdtempSync, readdirSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";

const args = process.argv.slice(2);
const outArg = args.find((a, i) => !a.startsWith("--") && args[i - 1] !== "--provider");
if (!outArg) {
  console.error("usage: bun make-demo-data.ts <out-dir> [--provider claude-code|codex|local|openrouter]");
  process.exit(2);
}
const provider = args.includes("--provider") ? args[args.indexOf("--provider") + 1] : "claude-code";
const OUT = resolve(outArg);
const HERE = dirname(new URL(import.meta.url).pathname);
const ROOT = resolve(HERE, "../../..");
const REAL = resolve(process.env.HOME ?? "", "Kleoth");
if (OUT.toLowerCase() === REAL.toLowerCase() || OUT.toLowerCase().startsWith(REAL.toLowerCase() + "/")) {
  throw new Error("refusing to write demo data into your real ~/Kleoth");
}
// A folder is ours only if it is new, empty, or already carries the marker that
// make-app-demos.sh and DemoDirector require: never overwrite anything else.
const MARKER = join(OUT, ".kleoth-demo");
if (existsSync(OUT) && readdirSync(OUT).length > 0 && !existsSync(MARKER)) {
  throw new Error(`${OUT} is not empty and was not made by this script (no .kleoth-demo); pick a new folder`);
}

const RATE = 48000;
const GAP = 0.45; // seconds between turns
const scratch = mkdtempSync(join(tmpdir(), "kleoth-demo-data-"));
process.on("exit", () => rmSync(scratch, { recursive: true, force: true }));
mkdirSync(OUT, { recursive: true });
writeFileSync(MARKER, "Demo data from app/branding-src/demo/make-demo-data.ts — fictional, safe to delete.\n");

for (const product of ["localtranscribe", "screenrec", "pillsandbox"]) {
  await $`swift build --package-path ${join(ROOT, "app")} --product ${product}`.quiet();
}
const BIN = join(ROOT, "app/.build/debug");

// Filter graphs go to ffmpeg as single interpolated arguments: Bun's shell would
// treat their brackets as glob patterns.
const MIX_ROOM_TONE = "[0:a][1:a]amix=inputs=2:duration=first:normalize=0";
const JOIN_STEREO = "[0:a][1:a]join=inputs=2:channel_layout=stereo";
const ROOM_TONE = `anoisesrc=color=pink:amplitude=0.0012:sample_rate=${RATE}`;
const SILENCE = `anullsrc=r=${RATE}:cl=mono`;

// ---------------------------------------------------------------------------------------

type Script = { headers: Record<string, string>; lines: { speaker: string; text: string }[] };

async function parse(file: string): Promise<Script> {
  const headers: Record<string, string> = {};
  const lines: Script["lines"] = [];
  for (const raw of (await Bun.file(file).text()).split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const turn = line.match(/^(YOU|THEM):\s*(.+)$/);
    const header = line.match(/^([a-z]+):\s*(.+)$/);
    if (turn) lines.push({ speaker: turn[1], text: turn[2] });
    else if (header) headers[header[1]] = header[2];
    else lines.push({ speaker: "YOU", text: line });
  }
  return { headers, lines };
}

/** `when: <day offset> HH:MM` → a local Date. */
function when(spec: string): Date {
  const [offset, clock] = spec.split(/\s+/);
  const [h, m] = clock.split(":").map(Number);
  const d = new Date();
  d.setDate(d.getDate() + Number(offset));
  d.setHours(h, m, 0, 0);
  return d;
}

const pad = (n: number) => String(n).padStart(2, "0");
const stamp = (d: Date) =>
  `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;

let clip = 0;
/** One spoken line as 48 kHz mono WAV; returns its path and length in seconds. */
async function speak(voice: string, text: string): Promise<{ path: string; secs: number }> {
  const n = clip++;
  const aiff = join(scratch, `line-${n}.aiff`);
  const wav = join(scratch, `line-${n}.wav`);
  await $`say -v ${voice} -o ${aiff} ${text}`.quiet();
  await $`ffmpeg -loglevel error -y -i ${aiff} -ar ${RATE} -ac 1 -c:a pcm_s16le ${wav}`.quiet();
  const secs = Number((await $`ffprobe -v error -show_entries format=duration -of csv=p=0 ${wav}`.text()).trim());
  return { path: wav, secs };
}

async function silence(secs: number): Promise<string> {
  const wav = join(scratch, `silence-${clip++}.wav`);
  await $`ffmpeg -loglevel error -y -f lavfi -i ${SILENCE} -t ${secs.toFixed(3)} -c:a pcm_s16le ${wav}`.quiet();
  return wav;
}

/** Concatenates WAV pieces and lays a quiet room tone under them (a real mic is never digital silence). */
async function track(pieces: string[], out: string) {
  const list = join(scratch, `list-${clip++}.txt`);
  writeFileSync(list, pieces.map((p) => `file '${p}'`).join("\n") + "\n");
  const joined = join(scratch, `joined-${clip++}.wav`);
  await $`ffmpeg -loglevel error -y -f concat -safe 0 -i ${list} -c:a pcm_s16le ${joined}`.quiet();
  await $`ffmpeg -loglevel error -y -i ${joined} -f lavfi -i ${ROOM_TONE} -filter_complex ${MIX_ROOM_TONE} -ac 1 -c:a pcm_s16le ${out}`.quiet();
}

// --- Meetings ----------------------------------------------------------------------------

const meetingFiles = readdirSync(join(HERE, "meetings")).filter((f) => f.endsWith(".txt")).sort();
for (const file of meetingFiles) {
  const script = await parse(join(HERE, "meetings", file));
  const [themName, themVoice] = script.headers.them.split("|").map((s) => s.trim());
  const youVoice = script.headers.you;
  const dir = join(OUT, `meeting-${stamp(when(script.headers.when))}`);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  console.log(`meeting   ${file} → ${dir}`);

  const mic: string[] = [];
  const system: string[] = [];
  for (const line of script.lines) {
    const you = line.speaker === "YOU";
    const spoken = await speak(you ? youVoice : themVoice, line.text);
    const quiet = await silence(spoken.secs);
    const gap = await silence(GAP);
    mic.push(you ? spoken.path : quiet, gap);
    system.push(you ? quiet : spoken.path, gap);
  }
  const micWav = join(scratch, "mic.wav");
  const systemWav = join(scratch, "system.wav");
  await track(mic, micWav);
  await track(system, systemWav);
  await $`ffmpeg -loglevel error -y -i ${micWav} -c:a aac -b:a 64k ${join(dir, "mic.m4a")}`.quiet();
  await $`ffmpeg -loglevel error -y -i ${systemWav} -c:a aac -b:a 64k ${join(dir, "system.m4a")}`.quiet();
  // meeting.m4a: mic hard left, system hard right — Recorder.combine's layout.
  await $`ffmpeg -loglevel error -y -i ${micWav} -i ${systemWav} -filter_complex ${JOIN_STEREO} -c:a aac -b:a 128k ${join(dir, "meeting.m4a")}`.quiet();

  // Names for the two channels, as a rename in the app would set them.
  const speakers = { names: { speaker_0: "You", speaker_1: themName } };
  writeFileSync(join(dir, "speakers.json"), JSON.stringify(speakers, null, 2) + "\n");

  const run = await $`${join(BIN, "localtranscribe")} ${dir} --provider ${provider}`.nothrow().text();
  const notable = run.split("\n").filter((l) => /Engine|Summary|Saved|FAILED/.test(l));
  console.log(notable.map((l) => "          " + l).join("\n"));
  for (const need of ["transcript.json", "summary.json", "meta.json"]) {
    if (!existsSync(join(dir, need))) throw new Error(`${file}: no ${need} — localtranscribe said:\n${run}`);
  }
}

// --- Screen recording --------------------------------------------------------------------

{
  const script = await parse(join(HERE, "recording.txt"));
  const voice = script.headers.voice;
  const lead = 0.8;
  const tail = 1.6;
  const pieces: string[] = [await silence(lead)];
  const marks: number[] = [];
  let t = lead;
  for (const line of script.lines) {
    marks.push(Number(t.toFixed(2)));
    const spoken = await speak(voice, line.text);
    pieces.push(spoken.path, await silence(GAP));
    t += spoken.secs + GAP;
  }
  pieces.push(await silence(tail));
  const length = t + tail;
  const narration = join(scratch, "narration.wav");
  await track(pieces, narration);

  const frames = join(scratch, "slides");
  // The first four sentences turn to the title, then to each bar.
  await $`${join(BIN, "pillsandbox")} --slides ${frames} --length ${length.toFixed(2)} --marks ${marks.slice(0, 4).join(",")}`.quiet();
  const dir = join(OUT, "screen-recordings");
  mkdirSync(dir, { recursive: true });
  const movie = join(dir, `screen-${stamp(when(script.headers.when))}.mp4`);
  const pattern = join(frames, "frame-%04d.png");
  await $`ffmpeg -loglevel error -y -framerate 30 -i ${pattern} -i ${narration} -c:v libx264 -pix_fmt yuv420p -crf 20 -r 30 -c:a aac -b:a 128k -ac 2 -shortest -movflags +faststart ${movie}`.quiet();
  console.log(`recording ${movie} (${length.toFixed(1)} s)`);
  const sidecar = await $`${join(BIN, "screenrec")} --sidecar ${movie} --title ${script.headers.title}`.nothrow();
  console.log(sidecar.text().split("\n").map((l) => "          " + l).join("\n"));
  if (sidecar.exitCode !== 0) throw new Error("screenrec --sidecar failed");
}

console.log(`demo data ready in ${OUT}`);
