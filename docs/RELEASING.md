# Releasing Kleoth

Step-by-step checklist for cutting a public release. Steps marked **[Developer Program]** are
blocked until the maintainer enrolls in the Apple Developer Program ($99/yr) — the self-signed tier
ships today without them, but users must allow the first launch by hand (Privacy & Security →
Open Anyway on macOS 15+, right-click → Open on macOS 14).

The single source of truth for the version is `CFBundleShortVersionString` in
`app/bundle/Info.plist`. `app/make-dmg.sh` reads it to name the DMG.

## 1. Pre-flight

- [ ] Working tree clean, on the release branch (usually `main`), everything intended is committed.
- [ ] Decide the version (semver). Current: `0.4.0`.

## 2. Bump the version

Edit `app/bundle/Info.plist`:

- [ ] `CFBundleShortVersionString` → the marketing version (e.g. `0.2.0`).
- [ ] `CFBundleVersion` → bump the build number (a monotonically increasing integer).

## 3. Build & test both packages

```sh
swift build && swift test            # core library + CLI; unit suite must pass
swift build --package-path app       # app + capture packages compile-check
```

- [ ] `swift test` is green.
- [ ] Both `swift build` invocations succeed.

> If you only have the Xcode Command Line Tools (not full Xcode), `swift test` needs the extra
> framework-search-path flags noted in `BUILD-APP.md`. Full Xcode runs it as-is.

## 4. Smoke-test the app bundle

```sh
bash app/setup-signing.sh            # one-time only: creates the "Kleoth Self-Signed" identity
bash app/make-app.sh release         # builds, signs, installs to /Applications/Kleoth.app
pkill -x Kleoth 2>/dev/null; open -a Kleoth
```

- [ ] App launches into the menu bar.
- [ ] Quick record → stop → a transcript appears in `~/Kleoth`.
- [ ] Settings opens; Usage / keys behave.

`make-app.sh` signs with the local **"Kleoth Self-Signed"** keychain identity if present (so TCC
permission grants persist across rebuilds), else ad-hoc. It bundles `Kleoth.icns` and the SwiftPM
resource bundle, then copies the app to `/Applications`.

## 5. Build the DMG — self-signed tier (ships today)

```sh
bash app/make-dmg.sh
```

If `marketing/positioning.json` changed since the last `bun marketing/sync.ts apply`, run
`bun marketing/sync.ts apply --no-remote` first: the DMG's *Read Me.txt* heading comes from it.

This runs `make-app.sh release` first (so the DMG always matches what runs), stages the app with an
`/Applications` symlink + a `Read Me.txt` + the volume icon, builds a compressed `UDZO` DMG, signs
the DMG (with "Kleoth Self-Signed", else ad-hoc), verifies it, and prints the size + SHA-256.

- [ ] Output: `app/dist/Kleoth-<version>.dmg`.
- [ ] Note the printed **SHA-256** — it goes in the GitHub release notes and the Homebrew cask.
- [ ] Gatekeeper line will say *"not notarized — other Macs must allow the first launch"* (expected
      until step 6).

## 6. Build the DMG — notarized public tier **[Developer Program]**

Once enrolled, `app/make-dmg.sh` auto-detects two environment variables and, when both are set,
produces a Gatekeeper-clean DMG:

- `KLEOTH_SIGN_IDENTITY` — a `"Developer ID Application: <Name> (<TEAMID>)"` identity. When set, the
  script re-signs the `.app` with the **hardened runtime + secure timestamp** (using
  `app/bundle/Kleoth.entitlements`) and signs the DMG with the same identity + timestamp.
- `KLEOTH_NOTARY_PROFILE` — a notarytool keychain profile. When set **together with**
  `KLEOTH_SIGN_IDENTITY`, the script runs `xcrun notarytool submit --wait` and `xcrun stapler staple`
  on the DMG.

One-time setup **[Developer Program]**:

```sh
# Create the Developer ID Application certificate in your Apple Developer account,
# then store notarization credentials as a reusable keychain profile:
xcrun notarytool store-credentials "<profile-name>" \
  --apple-id "<apple-id-email>" --team-id "<TEAMID>" --password "<app-specific-password>"
```

Then build:

```sh
KLEOTH_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
KLEOTH_NOTARY_PROFILE="<profile-name>" \
bash app/make-dmg.sh
```

- [ ] **[Developer Program]** Script prints *"notarized + stapled"* and the final Gatekeeper line
      reads **"Gatekeeper: ACCEPTED (notarized)"**.
- [ ] If only `KLEOTH_SIGN_IDENTITY` is set, it Developer-ID-signs but does **not** notarize (the
      script warns about this) — set the profile too for a true public release.

## 7. Verify

```sh
hdiutil verify app/dist/Kleoth-<version>.dmg
shasum -a 256 app/dist/Kleoth-<version>.dmg
```

- [ ] Image checksum OK.
- [ ] On a *second* Mac (or a fresh user), the install works: self-signed → Open Anyway (macOS 15+) or right-click → Open (14);
      notarized → opens cleanly.

## 8. Update the changelog

- [ ] Move the `[Unreleased]` notes (if any) into a dated `[<version>]` section in
      `CHANGELOG.md` (Keep a Changelog format).

## 9. Commercial info (positioning)

Every public copy of Kleoth's pitch comes from `marketing/positioning.json`
(see [`marketing/README.md`](../marketing/README.md)). A release is where it drifts, so:

- [ ] Read the new `CHANGELOG.md` section against `marketing/positioning.json` and the pages
      `docs/dictation.md`, `docs/meetings.md`, `docs/screen-recording.md`, `docs/ai-providers.md`:
      new jobs, a beta that graduated, a held-back claim that became true, a claim that stopped
      being true. Update the copy.
- [ ] Set `reviewed_for` in `positioning.json` to `<version>`.
- [ ] `bun marketing/sync.ts apply` — rewrites the README hero and download link, the cask
      `desc`/`version`/`sha256`, the Raycast description, the DMG Read Me heading, the images (if
      their text changed) and the GitHub About/topics.
- [ ] If `docs/assets/social-preview.png` changed: upload it (GitHub → Settings → General → Social
      preview; there is no API).
- [ ] `bun marketing/sync.ts check` passes; commit.

In a Claude Code session the `.claude/settings.json` hook runs this check before `git tag v…`
and `gh release create`, and blocks them until it passes.

## 10. Tag and publish the GitHub release

```sh
git tag v<version>            # e.g. v0.2.0
git push origin v<version>

gh release create v<version> \
  app/dist/Kleoth-<version>.dmg \
  --title "Kleoth <version>" \
  --notes-file <(sed -n '/## \[<version>\]/,/## \[/p' CHANGELOG.md)
```

- [ ] Release notes include the **SHA-256** from step 5/7.
- [ ] The DMG is attached.

## 11. Update the Homebrew cask

- [ ] `packaging/homebrew/kleoth.rb` already has the new `version` and `sha256` (step 9's `apply`).
- [ ] Push to the tap repo (e.g. `homebrew-kleoth`). The `livecheck` block tracks GitHub Releases.
- [ ] **[Developer Program]** Once notarized, remove the self-signed `caveats` note from the cask.

## 12. Announce

- [ ] Link the release; note the first-launch step (Open Anyway) until notarized builds land.

---

### What's blocked on the Apple Developer Program

| Capability | Status today | Unblocked by |
| --- | --- | --- |
| Self-signed DMG, installable on this Mac / Open Anyway elsewhere | ✅ Ships now | — |
| Developer ID signature (hardened runtime + timestamp) | ⛔️ | `KLEOTH_SIGN_IDENTITY` cert |
| Notarization + stapling (Gatekeeper-clean everywhere) | ⛔️ | `KLEOTH_NOTARY_PROFILE` + above |
| Drop the first-launch caveat from README, cask and DMG Read Me | ⛔️ | Notarized build |
