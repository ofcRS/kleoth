#!/usr/bin/env bun
// marketing/sync.ts — keeps every public copy of Kleoth's pitch in step with
// marketing/positioning.json, and gates releases on it. See marketing/README.md.
//
//   bun marketing/sync.ts check [--offline] [--release] [--version X]
//       Report drift; exit 1 if anything is stale. --offline skips the live GitHub
//       About/topics; --release also requires app/dist/Kleoth-<v>.dmg (the hook sets it).
//   bun marketing/sync.ts apply [--no-remote]
//       Rewrite every derived copy (README blocks, cask, Raycast, DMG Read Me, images)
//       and, unless --no-remote, the GitHub About/homepage/topics.
//   bun marketing/sync.ts hook
//       Claude Code PreToolUse gate (.claude/settings.json): reads the hook JSON on stdin
//       and blocks `git tag vX.Y.Z` / `gh release create` (exit 2) while `check` fails.

import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "..");
const P = (rel: string) => join(ROOT, rel);

const POSITIONING = "marketing/positioning.json";
const LOCK = "marketing/positioning.lock.json";
const README = "README.md";
const CASK = "packaging/homebrew/kleoth.rb";
const RAYCAST = "integrations/raycast-extension/package.json";
const MAKE_DMG = "app/make-dmg.sh";
const INFO_PLIST = "app/bundle/Info.plist";
const IMAGE_SCRIPT = "app/branding-src/readme-images/generate.swift";
const SOCIAL_PREVIEW = "docs/assets/social-preview.png";

type Job = { id: string; title: string; status: string; page: string; line: string };
type Positioning = {
  reviewed_for: string;
  name: string;
  tagline: string;
  github: { repo: string; about: string; homepage: string; topics: string[] };
  intro: string;
  jobs: Job[];
  byo_ai: string;
  byo_ai_page: string;
  closer: string;
  short: { homebrew: string; raycast: string; dmg: string };
  image: { jobs: string; tagline: string; sub: string };
};

const pos: Positioning = JSON.parse(readFileSync(P(POSITIONING), "utf8"));
const read = (rel: string) => readFileSync(P(rel), "utf8");

// ---------------------------------------------------------------- facts

function plistVersion(): string {
  const m = read(INFO_PLIST).match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/);
  if (!m) throw new Error(`${INFO_PLIST}: no CFBundleShortVersionString`);
  return m[1].trim();
}

type Dmg = { bytes: number; sha256: string };

function dmgFor(version: string): Dmg | null {
  const dmg = P(`app/dist/Kleoth-${version}.dmg`);
  const sum = `${dmg}.sha256`;
  if (!existsSync(dmg) || !existsSync(sum)) return null;
  return { bytes: statSync(dmg).size, sha256: readFileSync(sum, "utf8").trim().split(/\s+/)[0] };
}

function imagesFingerprint(): string {
  return createHash("sha256")
    .update(JSON.stringify({ name: pos.name, image: pos.image, script: read(IMAGE_SCRIPT) }))
    .digest("hex");
}

// ---------------------------------------------------------------- renderers

const BADGES = (repo: string) => [
  `[![Release](https://img.shields.io/github/v/release/${repo})](https://github.com/${repo}/releases/latest)`,
  `[![Downloads](https://img.shields.io/github/downloads/${repo}/total)](https://github.com/${repo}/releases)`,
  `[![Platform: macOS 14.4+](https://img.shields.io/badge/platform-macOS%2014.4%2B-black)](https://www.apple.com/macos/)`,
  `[![Swift 6](https://img.shields.io/badge/swift-6-orange)](https://www.swift.org/)`,
  `[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)`,
].join("\n");

function heroBlock(): string {
  const alt = `${pos.name} — ${pos.tagline.replace(/\.$/, "")}`;
  const jobs = pos.jobs
    .map((j) => {
      const status = j.status === "stable" ? "" : ` (${j.status})`;
      return `- **[${j.title}](${j.page})${status}.** ${j.line}`;
    })
    .join("\n");
  return [
    `<p align="center">`,
    `  <img src="docs/assets/hero.png" alt="${alt}" width="830">`,
    `</p>`,
    ``,
    BADGES(pos.github.repo),
    ``,
    `**${pos.tagline}**`,
    ``,
    pos.intro,
    ``,
    jobs,
    ``,
    `${pos.byo_ai} [Which providers, and what each needs →](${pos.byo_ai_page})`,
    ``,
    pos.closer,
  ].join("\n");
}

function releaseBlock(version: string, dmg: Dmg): string {
  const base = `https://github.com/${pos.github.repo}/releases/download/v${version}`;
  const mb = (dmg.bytes / 1e6).toFixed(1);
  return [
    `**[⬇ Download Kleoth-${version}.dmg](${base}/Kleoth-${version}.dmg)**`,
    `(${mb} MB · [SHA-256](${base}/Kleoth-${version}.dmg.sha256))`,
    `— or browse all [Releases](../../releases).`,
  ].join("\n");
}

/** Replace the body between `<!-- <tag>:start … -->` and `<!-- <tag>:end -->`. */
function withBlock(text: string, file: string, tag: string, body: string, note: string): string {
  const re = new RegExp(`<!-- ${tag}:start[^\\n]*-->\\n[\\s\\S]*?<!-- ${tag}:end -->`);
  if (!re.test(text)) throw new Error(`${file}: missing <!-- ${tag}:start --> / <!-- ${tag}:end --> markers`);
  return text.replace(re, () => `<!-- ${tag}:start — ${note} -->\n${body}\n<!-- ${tag}:end -->`);
}

function blockBody(text: string, tag: string): string | null {
  const m = text.match(new RegExp(`<!-- ${tag}:start[^\\n]*-->\\n([\\s\\S]*?)\\n<!-- ${tag}:end -->`));
  return m ? m[1] : null;
}

function replaceOnce(text: string, file: string, re: RegExp, to: string): string {
  if (!re.test(text)) throw new Error(`${file}: pattern ${re} not found`);
  return text.replace(re, () => to);
}

// ---------------------------------------------------------------- targets

type Result = { name: string; ok: boolean; detail?: string; skipped?: boolean };
type Target = {
  name: string;
  file: string;
  /** The file as it should be, or null when it can't be derived here (e.g. no DMG). */
  expected: (current: string) => string | null;
  /** A weaker check used when `expected` returns null. */
  fallback?: (current: string) => string | null; // error message or null
  skipNote?: string;
};

function targets(version: string, dmg: Dmg | null): Target[] {
  const generated = "generated from marketing/positioning.json by `bun marketing/sync.ts apply`; edit the JSON, not this block";
  return [
    {
      name: "README hero",
      file: README,
      expected: (t) => withBlock(t, README, "positioning", heroBlock(), generated),
    },
    {
      name: `README download link (v${version})`,
      file: README,
      expected: (t) =>
        dmg
          ? withBlock(t, README, "release", releaseBlock(version, dmg),
              "generated from app/bundle/Info.plist + app/dist by `bun marketing/sync.ts apply`")
          : null,
      fallback: (t) =>
        (blockBody(t, "release") ?? "").includes(`/download/v${version}/Kleoth-${version}.dmg`)
          ? null
          : `does not link Kleoth-${version}.dmg`,
      skipNote: `size/SHA not verified (no app/dist/Kleoth-${version}.dmg)`,
    },
    {
      name: "Homebrew cask desc",
      file: CASK,
      expected: (t) => replaceOnce(t, CASK, /^  desc ".*"$/m, `  desc ${JSON.stringify(pos.short.homebrew)}`),
    },
    {
      name: `Homebrew cask version + sha256 (v${version})`,
      file: CASK,
      expected: (t) => {
        if (!dmg) return null;
        const v = replaceOnce(t, CASK, /^  version ".*"$/m, `  version "${version}"`);
        return replaceOnce(v, CASK, /^  sha256 ".*"$/m, `  sha256 "${dmg.sha256}"`);
      },
      fallback: (t) => (t.includes(`version "${version}"`) ? null : `version is not ${version}`),
      skipNote: `sha256 not verified (no app/dist/Kleoth-${version}.dmg)`,
    },
    {
      name: "Raycast extension description",
      file: RAYCAST,
      expected: (t) =>
        replaceOnce(t, RAYCAST, /^  "description": ".*",$/m, `  "description": ${JSON.stringify(pos.short.raycast)},`),
    },
    {
      name: "DMG Read Me heading",
      file: MAKE_DMG,
      expected: (t) =>
        replaceOnce(t, MAKE_DMG, /(Read Me\.txt" <<'EOF'\n).*\n=+\n/,
          `Read Me.txt" <<'EOF'\n${pos.short.dmg}\n${"=".repeat(pos.short.dmg.length)}\n`),
    },
  ];
}

function evaluate(t: Target): { result: Result; next: string | null; current: string } {
  const current = read(t.file);
  const next = t.expected(current);
  if (next === null) {
    const err = t.fallback?.(current) ?? null;
    return {
      result: { name: t.name, ok: !err, detail: err ?? t.skipNote, skipped: !err },
      next: null,
      current,
    };
  }
  return { result: { name: t.name, ok: next === current, detail: next === current ? undefined : "out of date" }, next, current };
}

// ---------------------------------------------------------------- GitHub metadata

function gh(args: string[], input?: string): { ok: boolean; out: string; err: string } {
  const p = Bun.spawnSync(["gh", ...args], { cwd: ROOT, stdin: input ? Buffer.from(input) : undefined });
  return { ok: p.exitCode === 0, out: p.stdout.toString(), err: p.stderr.toString().trim() };
}

type Live = { description: string; homepage: string; topics: string[] };

function liveMetadata(): Live | string {
  const r = gh(["repo", "view", pos.github.repo, "--json", "description,homepageUrl,repositoryTopics"]);
  if (!r.ok) return `gh repo view failed: ${r.err || "unknown error"}`;
  const j = JSON.parse(r.out);
  return {
    description: j.description ?? "",
    homepage: j.homepageUrl ?? "",
    topics: (j.repositoryTopics ?? []).map((t: { name: string }) => t.name),
  };
}

function remoteResults(live: Live | string): Result[] {
  if (typeof live === "string") return [{ name: "GitHub About/topics", ok: false, detail: live }];
  const same = (a: string[], b: string[]) => [...a].sort().join(",") === [...b].sort().join(",");
  return [
    { name: "GitHub About", ok: live.description === pos.github.about, detail: "differs from positioning.json" },
    { name: "GitHub homepage", ok: live.homepage === pos.github.homepage, detail: "differs from positioning.json" },
    { name: "GitHub topics", ok: same(live.topics, pos.github.topics), detail: "differ from positioning.json" },
  ].map((r) => (r.ok ? { name: r.name, ok: true } : r));
}

// ---------------------------------------------------------------- check / apply

type Opts = { offline: boolean; release: boolean; version?: string; remote: boolean };

function parseOpts(argv: string[]): Opts {
  const vi = argv.indexOf("--version");
  return {
    offline: argv.includes("--offline"),
    release: argv.includes("--release"),
    version: vi >= 0 ? argv[vi + 1]?.replace(/^v/, "") : undefined,
    remote: !argv.includes("--no-remote"),
  };
}

function check(o: Opts): Result[] {
  const version = o.version ?? plistVersion();
  const dmg = dmgFor(version);
  const results: Result[] = [];

  const plist = plistVersion();
  if (plist !== version) results.push({ name: "Info.plist version", ok: false, detail: `is ${plist}, releasing ${version}` });

  results.push({
    name: `positioning reviewed for v${version}`,
    ok: pos.reviewed_for === version,
    detail: pos.reviewed_for === version ? undefined
      : `reviewed_for is ${pos.reviewed_for} — read CHANGELOG [${version}] against positioning.json, update the copy, bump reviewed_for`,
  });

  if (o.release && !dmg) {
    results.push({ name: "release DMG", ok: false, detail: `app/dist/Kleoth-${version}.dmg(.sha256) missing — run bash app/make-dmg.sh first` });
  }

  for (const t of targets(version, dmg)) results.push(evaluate(t).result);

  const lock = existsSync(P(LOCK)) ? JSON.parse(read(LOCK)) : {};
  results.push({
    name: "README hero + social preview images",
    ok: lock.images === imagesFingerprint(),
    detail: lock.images === imagesFingerprint() ? undefined : "image text changed since the last render",
  });

  if (!o.offline) results.push(...remoteResults(liveMetadata()));
  return results;
}

function apply(o: Opts): boolean {
  const version = plistVersion();
  const dmg = dmgFor(version);
  let ok = true;

  for (const t of targets(version, dmg)) {
    const { result, next, current } = evaluate(t);
    if (next !== null && next !== current) {
      writeFileSync(P(t.file), next);
      console.log(`  wrote   ${t.name} (${t.file})`);
    } else if (result.skipped) {
      console.log(`  skip    ${t.name} — ${result.detail}`);
    } else if (!result.ok) {
      console.log(`  ✗       ${t.name} — ${result.detail}`);
      ok = false;
    }
  }

  const fp = imagesFingerprint();
  const lock = existsSync(P(LOCK)) ? JSON.parse(read(LOCK)) : {};
  if (lock.images !== fp) {
    const r = Bun.spawnSync(["swift", IMAGE_SCRIPT], { cwd: ROOT, stdout: "inherit", stderr: "inherit" });
    if (r.exitCode === 0) {
      writeFileSync(P(LOCK), JSON.stringify({ images: fp }, null, 2) + "\n");
      console.log(`  wrote   README hero + social preview images`);
    } else {
      console.log(`  ✗       images — ${IMAGE_SCRIPT} failed`);
      ok = false;
    }
  }

  if (o.remote) {
    const live = liveMetadata();
    if (typeof live === "string") {
      console.log(`  ✗       GitHub metadata — ${live}`);
      ok = false;
    } else {
      const repo = pos.github.repo;
      const edits = [
        ...(live.description !== pos.github.about ? ["--description", pos.github.about] : []),
        ...(live.homepage !== pos.github.homepage ? ["--homepage", pos.github.homepage] : []),
      ];
      if (edits.length) {
        const r = gh(["repo", "edit", repo, ...edits]);
        console.log(r.ok ? `  pushed  GitHub About/homepage` : `  ✗       GitHub About/homepage — ${r.err}`);
        ok &&= r.ok;
      }
      if ([...live.topics].sort().join() !== [...pos.github.topics].sort().join()) {
        const r = gh(["api", "--method", "PUT", `repos/${repo}/topics`, "--input", "-"],
          JSON.stringify({ names: pos.github.topics }));
        console.log(r.ok ? `  pushed  GitHub topics` : `  ✗       GitHub topics — ${r.err}`);
        ok &&= r.ok;
      }
    }
  }
  return ok;
}

function reminders(): string[] {
  const out: string[] = [];
  const tag = Bun.spawnSync(["git", "describe", "--tags", "--abbrev=0"], { cwd: ROOT }).stdout.toString().trim();
  if (tag) {
    const d = Bun.spawnSync(["git", "diff", "--quiet", tag, "--", SOCIAL_PREVIEW], { cwd: ROOT });
    if (d.exitCode === 1) {
      out.push(`${SOCIAL_PREVIEW} changed since ${tag}: upload it at https://github.com/${pos.github.repo}/settings → Social preview (GitHub has no API for it).`);
    }
  }
  out.push("After a copy change, re-run the discovery queries in marketing/README.md.");
  return out;
}

function print(results: Result[]) {
  for (const r of results) {
    const mark = r.skipped ? "–" : r.ok ? "✓" : "✗";
    console.log(`  ${mark} ${r.name}${r.detail && (!r.ok || r.skipped) ? ` — ${r.detail}` : ""}`);
  }
}

// ---------------------------------------------------------------- hook

/** The release version a shell command is about to tag or publish, or null. */
function releaseVersion(command: string): string | null {
  for (const raw of command.split(/&&|\|\||;|\||\n/)) {
    const seg = raw.trim().replace(/^(?:[A-Z_][A-Z0-9_]*=\S*\s+)*/, "");
    const tagged = /^git\s+tag\b/.test(seg) && !/\s(?:-d|-l|--delete|--list|--contains|--points-at)\b/.test(seg);
    const released = /^gh\s+release\s+create\b/.test(seg);
    if (!tagged && !released) continue;
    const v = seg.match(/\bv(\d+\.\d+\.\d+)\b/);
    if (v) return v[1];
    if (released) return plistVersion();
  }
  return null;
}

async function hook(): Promise<number> {
  let command = "";
  try {
    command = JSON.parse(await Bun.stdin.text())?.tool_input?.command ?? "";
  } catch {
    return 0;
  }
  const version = releaseVersion(command);
  if (!version) return 0;
  const failed = check({ offline: false, release: true, version, remote: false }).filter((r) => !r.ok && !r.skipped);
  if (failed.length === 0) return 0;
  console.error(`Release v${version} blocked: Kleoth's public positioning is stale.`);
  for (const r of failed) console.error(`  ✗ ${r.name}${r.detail ? ` — ${r.detail}` : ""}`);
  console.error(
    `Fix: review marketing/positioning.json against CHANGELOG [${version}] (marketing/README.md → "Every release"), ` +
      `bump reviewed_for, run \`bun marketing/sync.ts apply\`, commit, then retry.`,
  );
  return 2;
}

// ---------------------------------------------------------------- main

const [cmd, ...rest] = Bun.argv.slice(2);
const opts = parseOpts(rest);

if (cmd === "check") {
  const results = check(opts);
  print(results);
  for (const r of reminders()) console.log(`  · ${r}`);
  process.exit(results.every((r) => r.ok) ? 0 : 1);
} else if (cmd === "apply") {
  const ok = apply(opts);
  for (const r of reminders()) console.log(`  · ${r}`);
  process.exit(ok ? 0 : 1);
} else if (cmd === "hook") {
  process.exit(await hook());
} else {
  console.error("usage: bun marketing/sync.ts check [--offline] [--release] [--version X] | apply [--no-remote] | hook");
  process.exit(64);
}
