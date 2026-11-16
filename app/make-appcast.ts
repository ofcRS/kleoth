#!/usr/bin/env bun
// app/make-appcast.ts — the in-app update feed (Sparkle appcast) for a release DMG.
// Design: docs/plans/2026-11-16-updater.md. Release step: docs/RELEASING.md.
//
//   bun app/make-appcast.ts [--dmg <path>] [--out <path>] [--previous <url|file|none>]
//                           [--download-base <url>] [--notes <file.md>] [--ed-key-file <file>]
//
// Defaults: the DMG is app/dist/Kleoth-<Info.plist version>.dmg, the feed goes to
// app/dist/appcast.xml, the items already published are read from the latest release's
// appcast.xml, the enclosure URL is the release download URL, and the release notes are the
// CHANGELOG.md section for the version. The DMG is signed with Sparkle's sign_update and the EdDSA
// key in this Mac's login Keychain (the first run asks for Keychain access: Always Allow);
// --ed-key-file signs with a key file instead (the local end-to-end test only).
//
// It refuses — exit 1, nothing written — when anything a shipped updater relies on is off: the app
// in the DMG doesn't match Info.plist, doesn't verify, or lacks Sparkle; its feed URL or minimum
// macOS is not the expected one; its build number is not a plain integer above every build already
// published; the signature is missing, or does not verify against the SUPublicEDKey inside the DMG;
// the CHANGELOG section is missing; the result is not well-formed XML.
//
// Upload the result with the DMG: `gh release create v<version> <dmg> <dmg>.sha256 app/dist/appcast.xml`.
// Every installed Kleoth reads https://github.com/ofcRS/kleoth/releases/latest/download/appcast.xml.

import { createPublicKey, verify } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "..");
const P = (rel: string) => join(ROOT, rel);

export const REPO = "ofcRS/kleoth";
export const FEED_URL = `https://github.com/${REPO}/releases/latest/download/appcast.xml`;
export const MINIMUM_SYSTEM_VERSION = "14.4";
/** How many items the feed keeps: the newest decides; older ones carry history for "Version History". */
export const MAX_ITEMS = 10;
const SIGN_UPDATE = P("app/.build/artifacts/sparkle/Sparkle/bin/sign_update");

// ---------------------------------------------------------------- pure parts (tested)

/** The `## [<version>]` section of a Keep-a-Changelog file, without its heading. Null if absent. */
export function changelogSection(changelog: string, version: string): string | null {
  const lines = changelog.split("\n");
  const start = lines.findIndex((l) => l.startsWith(`## [${version}]`));
  if (start < 0) return null;
  const end = lines.findIndex((l, i) => i > start && l.startsWith("## "));
  const body = lines.slice(start + 1, end < 0 ? undefined : end).join("\n").trim();
  return body.length ? body : null;
}

const escapeHTML = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** Inline Markdown the CHANGELOG uses: `code`, **bold**, [links](url). */
function inline(text: string): string {
  const codes: string[] = [];
  let s = text.replace(/`([^`]+)`/g, (_, c) => `\u0000${codes.push(`<code>${escapeHTML(c)}</code>`) - 1}\u0000`);
  s = escapeHTML(s)
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, t, u) => `<a href="${u.replace(/"/g, "&quot;")}">${t}</a>`);
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => codes[Number(i)]);
}

/**
 * The CHANGELOG's Markdown as the small HTML Sparkle's update alert renders: `###` headings,
 * `- ` lists with indented continuation lines, paragraphs, and inline code/bold/links.
 */
export function markdownToHTML(markdown: string): string {
  const out: string[] = [];
  let list: string[] | null = null;
  let para: string[] | null = null;
  const flush = () => {
    if (list) out.push(`<ul>${list.map((i) => `<li>${inline(i)}</li>`).join("")}</ul>`);
    if (para) out.push(`<p>${inline(para.join(" "))}</p>`);
    list = null;
    para = null;
  };
  for (const raw of markdown.split("\n")) {
    const line = raw.trimEnd();
    const heading = line.match(/^#{1,6}\s+(.*)$/);
    if (!line.trim()) {
      flush();
    } else if (heading) {
      flush();
      out.push(`<h3>${inline(heading[1])}</h3>`);
    } else if (/^[-*]\s+/.test(line)) {
      if (para) flush();
      (list ??= []).push(line.replace(/^[-*]\s+/, ""));
    } else if (list && /^\s+/.test(line)) {
      list[list.length - 1] += ` ${line.trim()}`;
    } else {
      if (list) flush();
      (para ??= []).push(line.trim());
    }
  }
  flush();
  return out.join("\n");
}

/** Sparkle compares CFBundleVersion; Kleoth's is a plain positive integer. */
export function buildNumber(value: string): number | null {
  return /^[1-9]\d*$/.test(value.trim()) ? Number(value.trim()) : null;
}

/** The `<item>` elements of an appcast, verbatim, with each one's sparkle:version. */
export function appcastItems(xml: string): { xml: string; version: string | null }[] {
  return [...xml.matchAll(/<item>[\s\S]*?<\/item>/g)].map((m) => ({
    xml: m[0],
    version: m[0].match(/<sparkle:version>\s*([^<]+?)\s*<\/sparkle:version>/)?.[1] ?? null,
  }));
}

export type NewItem = {
  shortVersion: string;
  build: string;
  minimumSystemVersion: string;
  url: string;
  length: number;
  signature: string;
  notesHTML: string;
  pubDate: Date;
};

/** RFC 822 with a numeric zone, the form Sparkle documents: "Mon, 16 Nov 2026 19:30:00 +0000". */
export function rfc822(date: Date): string {
  return date.toUTCString().replace(/GMT$/, "+0000");
}

export function itemXML(i: NewItem): string {
  const attr = (s: string) => escapeHTML(s).replace(/"/g, "&quot;");
  return [
    `    <item>`,
    `      <title>Kleoth ${escapeHTML(i.shortVersion)}</title>`,
    `      <pubDate>${rfc822(i.pubDate)}</pubDate>`,
    `      <sparkle:version>${escapeHTML(i.build)}</sparkle:version>`,
    `      <sparkle:shortVersionString>${escapeHTML(i.shortVersion)}</sparkle:shortVersionString>`,
    `      <sparkle:minimumSystemVersion>${escapeHTML(i.minimumSystemVersion)}</sparkle:minimumSystemVersion>`,
    `      <link>https://github.com/${REPO}/releases/tag/v${attr(i.shortVersion)}</link>`,
    `      <sparkle:fullReleaseNotesLink>https://github.com/${REPO}/blob/main/CHANGELOG.md</sparkle:fullReleaseNotesLink>`,
    `      <description><![CDATA[${i.notesHTML.replace(/]]>/g, "]]]]><![CDATA[>")}]]></description>`,
    `      <enclosure url="${attr(i.url)}" length="${i.length}" type="application/octet-stream" sparkle:edSignature="${attr(i.signature)}"/>`,
    `    </item>`,
  ].join("\n");
}

/** The whole feed: the new item first, then the published ones (same build replaced), capped. */
export function appcastXML(item: NewItem, previous: { xml: string; version: string | null }[]): string {
  const kept = previous
    .filter((p) => p.version !== item.build)
    .slice(0, MAX_ITEMS - 1)
    .map((p) => `    ${p.xml.trim()}`);
  return [
    `<?xml version="1.0" encoding="utf-8"?>`,
    `<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">`,
    `  <channel>`,
    `    <title>Kleoth</title>`,
    `    <link>https://github.com/${REPO}</link>`,
    `    <description>Kleoth updates</description>`,
    `    <language>en</language>`,
    itemXML(item),
    ...kept,
    `  </channel>`,
    `</rss>`,
    ``,
  ].join("\n");
}

/** Sparkle's EdDSA check: an Ed25519 signature over the archive's bytes, with the raw 32-byte key. */
export function verifyEd25519(data: Uint8Array, signatureB64: string, publicKeyB64: string): boolean {
  const raw = Buffer.from(publicKeyB64, "base64");
  const signature = Buffer.from(signatureB64, "base64");
  if (raw.length !== 32 || signature.length !== 64) return false;
  const spki = Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), raw]);
  return verify(null, data, createPublicKey({ key: spki, format: "der", type: "spki" }), signature);
}

/** The newest item of a feed, as the release gate (marketing/sync.ts check --release) reads it. */
export function newestItem(xml: string): { shortVersion?: string; url?: string; length?: number; signature?: string } | null {
  const first = appcastItems(xml)[0]?.xml;
  if (!first) return null;
  const enclosure = first.match(/<enclosure\b[^>]*>/)?.[0] ?? "";
  const attr = (name: string) => enclosure.match(new RegExp(`\\b${name}="([^"]*)"`))?.[1];
  return {
    shortVersion: first.match(/<sparkle:shortVersionString>\s*([^<]+?)\s*<\/sparkle:shortVersionString>/)?.[1],
    url: attr("url"),
    length: attr("length") !== undefined ? Number(attr("length")) : undefined,
    signature: attr("sparkle:edSignature"),
  };
}

// ---------------------------------------------------------------- the run

class Refusal extends Error {}
const refuse = (message: string): never => {
  throw new Refusal(message);
};

function run(cmd: string[], opts: { stdin?: string } = {}): { ok: boolean; out: string; err: string } {
  const r = Bun.spawnSync(cmd, { cwd: ROOT, stdin: opts.stdin !== undefined ? Buffer.from(opts.stdin) : undefined });
  return { ok: r.exitCode === 0, out: r.stdout.toString(), err: r.stderr.toString() };
}

function plistValue(plist: string, key: string): string | null {
  const r = run(["/usr/libexec/PlistBuddy", "-c", `Print :${key}`, plist]);
  return r.ok ? r.out.trim() : null;
}

type DmgApp = {
  shortVersion: string;
  build: string;
  minimumSystemVersion: string | null;
  feedURL: string | null;
  publicKey: string | null;
  bundleId: string | null;
};

/** Mounts the DMG read-only, reads Kleoth.app's Info.plist and verifies its signature. */
function inspectDmg(dmg: string): DmgApp {
  const mount = mkdtempSync(join(tmpdir(), "kleoth-appcast-"));
  const attach = run(["hdiutil", "attach", dmg, "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mount]);
  if (!attach.ok) refuse(`could not mount ${dmg}: ${attach.err.trim()}`);
  try {
    const app = join(mount, "Kleoth.app");
    if (!existsSync(app)) refuse(`${basename(dmg)} holds no Kleoth.app at its top level`);
    const plist = join(app, "Contents/Info.plist");
    if (!existsSync(join(app, "Contents/Frameworks/Sparkle.framework"))) {
      refuse("the app in the DMG has no Contents/Frameworks/Sparkle.framework: it could never update itself");
    }
    const verified = run(["codesign", "--verify", "--deep", "--strict", app]);
    if (!verified.ok) refuse(`the app in the DMG fails codesign --verify --deep --strict: ${verified.err.trim()}`);
    return {
      shortVersion: plistValue(plist, "CFBundleShortVersionString") ?? refuse("no CFBundleShortVersionString in the DMG's app"),
      build: plistValue(plist, "CFBundleVersion") ?? refuse("no CFBundleVersion in the DMG's app"),
      minimumSystemVersion: plistValue(plist, "LSMinimumSystemVersion"),
      feedURL: plistValue(plist, "SUFeedURL"),
      publicKey: plistValue(plist, "SUPublicEDKey"),
      bundleId: plistValue(plist, "CFBundleIdentifier"),
    };
  } finally {
    run(["hdiutil", "detach", mount, "-quiet"]);
    rmSync(mount, { recursive: true, force: true });
  }
}

/** The published feed's items: a URL (404 = nothing published yet), a file, or "none". */
async function previousItems(source: string): Promise<{ items: ReturnType<typeof appcastItems>; from: string }> {
  if (source === "none") return { items: [], from: "none (--previous none)" };
  if (!/^https?:/.test(source)) return { items: appcastItems(readFileSync(source, "utf8")), from: source };
  const res = await fetch(source, { redirect: "follow" });
  if (res.status === 404) return { items: [], from: `${source} (404: no feed published yet)` };
  if (!res.ok) refuse(`could not read the published feed ${source}: HTTP ${res.status}`);
  return { items: appcastItems(await res.text()), from: source };
}

/** CFBundleVersion of the newest v* tag: the floor for a release that has no feed before it. */
function taggedBuild(): { tag: string; build: number } | null {
  const tags = run(["git", "tag", "--list", "v*", "--sort=-v:refname"]);
  const tag = tags.ok ? tags.out.split("\n")[0]?.trim() : "";
  if (!tag) return null;
  const plist = run(["git", "show", `${tag}:app/bundle/Info.plist`]);
  const build = plist.out.match(/<key>CFBundleVersion<\/key>\s*<string>([^<]+)<\/string>/)?.[1];
  const n = build ? buildNumber(build) : null;
  return n === null ? null : { tag, build: n };
}

function sign(dmg: string, keyFile?: string): { signature: string; length: number } {
  if (!existsSync(SIGN_UPDATE)) refuse(`${SIGN_UPDATE} is missing: run \`swift build --package-path app\` first (Sparkle's tools come with the package)`);
  const r = run([SIGN_UPDATE, ...(keyFile ? ["--ed-key-file", keyFile] : []), dmg]);
  // sign_update prints its errors on stdout.
  if (!r.ok) refuse(`sign_update failed: ${(r.out + r.err).trim()}`);
  const signature = r.out.match(/sparkle:edSignature="([^"]+)"/)?.[1];
  const length = r.out.match(/\blength="(\d+)"/)?.[1];
  if (!signature) refuse(`sign_update printed no sparkle:edSignature (output: ${r.out.trim() || "empty"})`);
  if (!length) refuse(`sign_update printed no length (output: ${r.out.trim()})`);
  return { signature: signature!, length: Number(length) };
}

async function main() {
  const argv = Bun.argv.slice(2);
  const opt = (name: string) => {
    const i = argv.indexOf(name);
    return i >= 0 ? argv[i + 1] : undefined;
  };
  const sourcePlist = P("app/bundle/Info.plist");
  const sourceVersion = plistValue(sourcePlist, "CFBundleShortVersionString") ?? refuse("app/bundle/Info.plist has no version");
  const explicitDmg = opt("--dmg");
  const dmg = resolve(explicitDmg ?? P(`app/dist/Kleoth-${sourceVersion}.dmg`));
  const out = resolve(opt("--out") ?? P("app/dist/appcast.xml"));
  if (!existsSync(dmg)) refuse(`${dmg} is missing: run bash app/make-dmg.sh first`);

  console.log(`==> inspecting ${dmg}`);
  const app = inspectDmg(dmg);
  console.log(`    Kleoth ${app.shortVersion} (build ${app.build}), ${app.bundleId}, signature verifies`);
  if (!explicitDmg && app.shortVersion !== sourceVersion) {
    refuse(`the DMG holds ${app.shortVersion} but app/bundle/Info.plist says ${sourceVersion}: rebuild the DMG`);
  }
  if (!explicitDmg && app.build !== plistValue(sourcePlist, "CFBundleVersion")) {
    refuse(`the DMG's build ${app.build} is not app/bundle/Info.plist's: rebuild the DMG`);
  }
  if (app.feedURL !== FEED_URL) refuse(`the app's SUFeedURL is ${app.feedURL ?? "missing"}, not ${FEED_URL}`);
  if (!app.publicKey) refuse("the app has no SUPublicEDKey: Sparkle would refuse every update");
  if (app.minimumSystemVersion !== MINIMUM_SYSTEM_VERSION) {
    refuse(`LSMinimumSystemVersion is ${app.minimumSystemVersion ?? "missing"}, expected ${MINIMUM_SYSTEM_VERSION} (update MINIMUM_SYSTEM_VERSION here if that changed on purpose)`);
  }

  // Build numbers only ever go up: Sparkle offers an item only when its sparkle:version is newer.
  const build = buildNumber(app.build) ?? refuse(`CFBundleVersion "${app.build}" is not a plain positive integer`);
  const previous = await previousItems(opt("--previous") ?? FEED_URL);
  console.log(`    published feed: ${previous.from}, ${previous.items.length} item(s)`);
  for (const p of previous.items) {
    const n = p.version ? buildNumber(p.version) : null;
    if (n === null) refuse(`a published item has sparkle:version "${p.version}", not a plain integer`);
    if (n! > build || (n === build && !p.xml.includes(`<sparkle:shortVersionString>${app.shortVersion}<`))) {
      refuse(`build ${build} is not above the published build ${n}: bump CFBundleVersion in app/bundle/Info.plist`);
    }
  }
  const tagged = taggedBuild();
  if (tagged && !(build > tagged.build) && tagged.tag !== `v${app.shortVersion}`) {
    refuse(`build ${build} is not above ${tagged.tag}'s build ${tagged.build}: bump CFBundleVersion in app/bundle/Info.plist`);
  }
  if (tagged) {
    console.log(tagged.tag === `v${app.shortVersion}` && build === tagged.build
      ? `    build ${build} is ${tagged.tag}'s own (a re-run for a tagged release)`
      : `    build ${build} > ${tagged.tag}'s ${tagged.build}`);
  }

  const notesFile = opt("--notes");
  const notes = notesFile
    ? readFileSync(notesFile, "utf8")
    : changelogSection(readFileSync(P("CHANGELOG.md"), "utf8"), app.shortVersion)
      ?? refuse(`CHANGELOG.md has no "## [${app.shortVersion}]" section with notes (docs/RELEASING.md: update the changelog first)`);

  console.log(`==> signing with ${opt("--ed-key-file") ? "the key file given" : "the EdDSA key in your login Keychain"}`);
  const { signature, length } = sign(dmg, opt("--ed-key-file"));
  const bytes = readFileSync(dmg);
  if (length !== bytes.length || length !== statSync(dmg).size) refuse(`sign_update's length ${length} is not the DMG's ${bytes.length} bytes`);
  if (!verifyEd25519(bytes, signature, app.publicKey!)) {
    refuse(`the signature does not verify against the SUPublicEDKey inside the DMG: ${opt("--ed-key-file") ? "the key file" : "the Keychain key"} is not the app's key, and every installed Kleoth would reject this update`);
  }
  console.log(`    EdDSA signature verifies against the app's SUPublicEDKey`);

  const base = (opt("--download-base") ?? `https://github.com/${REPO}/releases/download/v${app.shortVersion}/`).replace(/\/?$/, "/");
  const item: NewItem = {
    shortVersion: app.shortVersion,
    build: String(build),
    minimumSystemVersion: app.minimumSystemVersion!,
    url: base + encodeURIComponent(basename(dmg)),
    length,
    signature,
    notesHTML: markdownToHTML(notes),
    pubDate: new Date(),
  };
  const xml = appcastXML(item, previous.items);
  const tmp = `${out}.tmp`;
  writeFileSync(tmp, xml);
  const lint = run(["xmllint", "--noout", tmp]);
  if (!lint.ok) {
    rmSync(tmp, { force: true });
    refuse(`the feed is not well-formed XML: ${lint.err.trim()}`);
  }
  run(["mv", "-f", tmp, out]);
  console.log(`==> wrote ${out}`);
  console.log(`    newest: Kleoth ${item.shortVersion} (build ${item.build}) → ${item.url}`);
  console.log(`    upload it with the DMG (docs/RELEASING.md): gh release create v${app.shortVersion} … app/dist/appcast.xml`);
}

if (import.meta.main) {
  try {
    await main();
  } catch (e) {
    if (e instanceof Refusal) {
      console.error(`make-appcast: REFUSED — ${e.message}`);
      process.exit(1);
    }
    throw e;
  }
}
