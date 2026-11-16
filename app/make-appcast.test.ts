// bun test ./app/make-appcast.test.ts — the update feed's pure parts.
import { describe, expect, test } from "bun:test";
import { generateKeyPairSync, sign } from "node:crypto";
import {
  appcastItems, appcastXML, buildNumber, changelogSection, markdownToHTML, MAX_ITEMS, newestItem,
  type NewItem, rfc822, verifyEd25519,
} from "./make-appcast.ts";

const CHANGELOG = `# Changelog

## [Unreleased]

## [0.5.5] — 2026-11-20

### Added

- **Kleoth updates itself.** A notice in the menu-bar popover, then
  one click. See \`Settings → General\`.

### Fixed

- A [link](https://example.com/a?b=1&c=2) & <angle> text.

## [0.5.4] — 2026-11-16

- older
`;

const item = (build: string, short = "0.5.5"): NewItem => ({
  shortVersion: short,
  build,
  minimumSystemVersion: "14.4",
  url: `https://github.com/ofcRS/kleoth/releases/download/v${short}/Kleoth-${short}.dmg`,
  length: 1234,
  signature: "c2ln",
  notesHTML: "<p>notes</p>",
  pubDate: new Date(Date.UTC(2026, 10, 16, 19, 30, 0)),
});

describe("changelogSection", () => {
  test("takes one version's section, without its heading", () => {
    const s = changelogSection(CHANGELOG, "0.5.5")!;
    expect(s.startsWith("### Added")).toBe(true);
    expect(s).not.toContain("0.5.4");
    expect(changelogSection(CHANGELOG, "0.5.4")).toBe("- older");
  });
  test("an absent or empty section is null", () => {
    expect(changelogSection(CHANGELOG, "0.9.9")).toBeNull();
    expect(changelogSection(CHANGELOG, "Unreleased")).toBeNull();
  });
});

describe("markdownToHTML", () => {
  test("headings, lists with continuation lines, inline marks, escaping", () => {
    const html = markdownToHTML(changelogSection(CHANGELOG, "0.5.5")!);
    expect(html).toContain("<h3>Added</h3>");
    expect(html).toContain("<li><strong>Kleoth updates itself.</strong> A notice in the menu-bar popover, then one click. See <code>Settings → General</code>.</li>");
    expect(html).toContain('<a href="https://example.com/a?b=1&amp;c=2">link</a> &amp; &lt;angle&gt; text.');
  });
});

describe("buildNumber", () => {
  test("only plain positive integers", () => {
    expect(buildNumber("10")).toBe(10);
    expect(buildNumber(" 9 ")).toBe(9);
    for (const bad of ["0", "09", "1.2", "10a", "", "-1"]) expect(buildNumber(bad)).toBeNull();
  });
});

describe("appcastXML", () => {
  test("new item first, the same build replaced, capped", () => {
    const old = Array.from({ length: 12 }, (_, i) => appcastItems(`<item><sparkle:version>${9 - i}</sparkle:version></item>`)[0]);
    const again = appcastItems(`<item><sparkle:version>10</sparkle:version><title>stale</title></item>`)[0];
    const xml = appcastXML(item("10"), [again, ...old]);
    const items = appcastItems(xml);
    expect(items[0].version).toBe("10");
    expect(xml).not.toContain("stale");
    expect(items.length).toBe(MAX_ITEMS);
  });
  test("the enclosure carries what Sparkle needs", () => {
    const xml = appcastXML(item("10"), []);
    expect(xml).toContain("<sparkle:version>10</sparkle:version>");
    expect(xml).toContain("<sparkle:shortVersionString>0.5.5</sparkle:shortVersionString>");
    expect(xml).toContain("<sparkle:minimumSystemVersion>14.4</sparkle:minimumSystemVersion>");
    expect(xml).toContain("<pubDate>Mon, 16 Nov 2026 19:30:00 +0000</pubDate>");
    expect(newestItem(xml)).toEqual({
      shortVersion: "0.5.5",
      url: "https://github.com/ofcRS/kleoth/releases/download/v0.5.5/Kleoth-0.5.5.dmg",
      length: 1234,
      signature: "c2ln",
    });
  });
  test("notes holding ]]> stay inside CDATA", () => {
    const xml = appcastXML({ ...item("10"), notesHTML: "<p>a ]]> b</p>" }, []);
    expect(xml).toContain("<p>a ]]]]><![CDATA[> b</p>");
  });
  test("rfc822", () => expect(rfc822(new Date(Date.UTC(2026, 0, 5, 7, 8, 9)))).toBe("Mon, 05 Jan 2026 07:08:09 +0000"));
});

describe("verifyEd25519 (Sparkle's archive check)", () => {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const raw = publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64");
  const data = Buffer.from("a DMG's bytes");
  const sig = sign(null, data, privateKey).toString("base64");
  test("accepts the key's signature", () => expect(verifyEd25519(data, sig, raw)).toBe(true));
  test("rejects other bytes, another key, garbage", () => {
    expect(verifyEd25519(Buffer.from("other bytes"), sig, raw)).toBe(false);
    const other = generateKeyPairSync("ed25519").publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("base64");
    expect(verifyEd25519(data, sig, other)).toBe(false);
    expect(verifyEd25519(data, "", raw)).toBe(false);
  });
});
