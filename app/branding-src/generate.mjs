#!/usr/bin/env bun
// Kleoth branding image generator (OpenRouter, Gemini image models).
//
// Usage:  bun app/branding-src/generate.mjs <jobs.json>
//
// Reads the OpenRouter key from ~/.config/kleoth/config.json — the key is NEVER
// printed (only sent in the Authorization header). Progress goes to stderr; a
// JSON result summary goes to stdout. Idempotent: a job whose `out` file already
// exists is skipped, so re-running only fills in what's missing.
//
// jobs.json: [{ out, prompt, aspect?, size?, input? }]
//   out    – output PNG path
//   prompt – text prompt
//   aspect – "1:1" | "16:9" | "9:16" | "3:2" | "2:3" | ... (default "1:1")
//   size   – "0.5K" | "1K" | "2K" | "4K" (default "1K")
//   input  – optional path to a source PNG for image-to-image editing
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "fs";
import { homedir } from "os";
import { dirname } from "path";

const CONFIG = `${homedir()}/.config/kleoth/config.json`;
function apiKey() {
  const cfg = JSON.parse(readFileSync(CONFIG, "utf8"));
  const k = cfg.openrouter_api_key;
  if (!k) throw new Error("no openrouter_api_key in config.json");
  return k;
}

const DEFAULT_MODELS = [
  "google/gemini-3.1-flash-image-preview",
  "google/gemini-2.5-flash-image",
];

async function genOne(job, key) {
  const { out, prompt, aspect = "1:1", size = "1K", input = null, models = DEFAULT_MODELS } = job;
  const content = input
    ? [
        { type: "image_url", image_url: { url: `data:image/png;base64,${readFileSync(input).toString("base64")}` } },
        { type: "text", text: prompt },
      ]
    : prompt;

  let lastErr = "";
  for (const model of models) {
    let res, text;
    try {
      res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${key}`,
          "Content-Type": "application/json",
          "HTTP-Referer": "https://kleoth.dev",
          "X-Title": "Kleoth",
        },
        body: JSON.stringify({
          model,
          messages: [{ role: "user", content }],
          modalities: ["image", "text"],
          image_config: { aspect_ratio: aspect, image_size: size },
        }),
      });
      text = await res.text();
    } catch (e) {
      lastErr = `fetch error: ${String(e).slice(0, 200)}`;
      continue;
    }
    if (!res.ok) { lastErr = `HTTP ${res.status}: ${text.slice(0, 400)}`; continue; }
    let json;
    try { json = JSON.parse(text); } catch { lastErr = `bad JSON: ${text.slice(0, 200)}`; continue; }
    const msg = json?.choices?.[0]?.message;
    const imgs = msg?.images ?? [];
    const url = (imgs[0]?.image_url?.url) || "";
    const m = url.match(/^data:image\/\w+;base64,(.*)$/s);
    if (!m) { lastErr = `no image data; text=${(msg?.content || "").slice(0, 160)}`; continue; }
    const buf = Buffer.from(m[1], "base64");
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, buf);
    return { out, ok: true, model, bytes: buf.length };
  }
  return { out, ok: false, error: lastErr };
}

const jobsFile = process.argv[2];
if (!jobsFile) { console.error("usage: bun generate.mjs <jobs.json>"); process.exit(2); }
const jobs = JSON.parse(readFileSync(jobsFile, "utf8"));
const key = apiKey();
const results = [];
for (const job of jobs) {
  if (existsSync(job.out)) { results.push({ out: job.out, ok: true, skipped: true }); console.error(`skip ${job.out}`); continue; }
  console.error(`gen  ${job.out} (${job.aspect || "1:1"} ${job.size || "1K"}) ...`);
  const r = await genOne(job, key);
  console.error(`  -> ${r.ok ? "ok " + (r.bytes || "") + "B via " + r.model : "FAIL " + r.error}`);
  results.push(r);
}
console.log(JSON.stringify(results, null, 2));
const failed = results.filter((r) => !r.ok).length;
process.exit(failed ? 1 : 0);
