# KeyboardShortcuts (vendored)

[sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) 2.4.0
(commit `1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27`), MIT — see `license`. `Sources/` is upstream's,
with one change in `Utilities.swift`: its strings load from `Bundle.keyboardShortcutsResources`
instead of `Bundle.module`.

Why: SwiftPM's generated `Bundle.module` looks only at the `.app` root and at the build Mac's
`.build` folder, then calls `fatalError`. Kleoth is built with `swift build`, not Xcode, so on every
other Mac the shortcut recorder in Settings → General crashed the app (#22, after #17). `make-app.sh`
ships `KeyboardShortcuts_KeyboardShortcuts.bundle` in `Contents/Resources`, where the patched lookup
finds it. Upstream 3.1.0 still uses `Bundle.module`.

To update: copy upstream's `Sources/` and `license` over these, then re-apply the change (grep for
`keyboardShortcutsResources`).
