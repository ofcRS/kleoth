# Building the Kleoth menu-bar app

The entire codebase — **including the audio-capture code** (`KleothCapture`: Core Audio process-tap, AVAudioEngine, ScreenCaptureKit) — already **compiles** under the Xcode Command Line Tools:

```sh
swift build --package-path app
```

Full Xcode is only needed for the last mile: assembling a real `.app` **bundle**, **codesigning/notarizing** it, and obtaining the **TCC permission grants** (microphone, screen recording) that live capture requires — those grants only work from a signed, bundled app.

## 1. Install full Xcode

```sh
# Install Xcode from the App Store (or `xcodes install`), then point the toolchain at it:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

With full Xcode active, `swift test` (in the repo root) also runs without the extra framework flags noted in the README.

## 2. Build the app target

```sh
swift run --package-path app KleothApp     # compiles and launches the executable
```

This runs the executable directly. To behave as a proper **menu-bar agent** (no Dock icon, persistent) it must be wrapped in an `.app` bundle (next step).

> **Package-identity note:** SwiftPM derives a path dependency's identity from the directory's basename. The repo directory is `kleoth-app`, so `app/Package.swift` references the core product as `.product(name: "KleothCore", package: "kleoth-app")`. If you rename the repo directory to `kleoth`, update that `package:` string to match.

## 3. Assemble the `.app` bundle

Create `KleothApp.app/Contents/{MacOS,Resources}/`, copy the built binary into `MacOS/`, and add `Contents/Info.plist` with at least:

| Key | Value | Why |
| --- | --- | --- |
| `CFBundleIdentifier` | `dev.kleoth.app` | bundle id (matches the Keychain service `dev.kleoth`) |
| `CFBundleExecutable` | `KleothApp` | the binary name |
| `LSUIElement` | `true` | menu-bar-only, no Dock icon |
| `NSMicrophoneUsageDescription` | "Kleoth records your microphone for meeting transcription." | required for the mic TCC prompt |

There is **no** Info.plist key for Screen Recording — it is a system-managed TCC prompt triggered on first ScreenCaptureKit use. (System-audio capture via the Core Audio process-tap does **not** require Screen Recording at all.)

## 4. Codesign (hardened runtime)

```sh
codesign --force --options runtime \
  --entitlements Kleoth.entitlements \
  --sign "Developer ID Application: <Your Name> (<TEAMID>)" \
  KleothApp.app
```

`Kleoth.entitlements` should include:

```xml
<key>com.apple.security.device.audio-input</key><true/>
```

**Do not enable the App Sandbox initially** — creating a Core Audio process-tap + aggregate device is impractical under the sandbox. Ship a hardened-runtime, non-sandboxed app first.

## 5. Notarize (for distribution)

```sh
ditto -c -k --keepParent KleothApp.app KleothApp.zip
xcrun notarytool submit KleothApp.zip --keychain-profile "<profile>" --wait
xcrun stapler staple KleothApp.app
```

## 6. Grant permissions & live-test capture

1. Launch `KleothApp.app`; it appears in the menu bar.
2. Acknowledge the consent prompt.
3. On first record, grant **Microphone** (and **Screen Recording** if you use the ScreenCaptureKit screenshot feature) in System Settings → Privacy & Security.
4. Start a short recording on a real call, stop it, and confirm a transcript (and summary, if an OpenRouter key is set) lands in your output folder.

### Capture implementation notes (already in `KleothCapture`)

- `SystemAudioTap` is gated `@available(macOS 14.4, *)`: `CATapDescription` → `AudioHardwareCreateProcessTap` → an aggregate device (`kAudioAggregateDeviceTapListKey`) → an IOProc. Process exclusion uses Core Audio process object IDs (translated from PIDs via `kAudioHardwarePropertyTranslatePIDToProcessObject`), not raw POSIX pids. Teardown is idempotent and ordered.
- `MicCapture` writes from a real-time, `@Sendable` `installTap` callback — allocation/lock-free.
- `Recorder` records mic and system audio as **separate tracks** with a shared `mach_absolute_time` anchor, and can build a 2-channel file (mic = ch0, system = ch1) for Scribe's multi-channel mode (perfect "you vs. them" separation).
- The recording session is owned by an app-level `@MainActor RecordingController`, not by any view, so recording survives the menu popover closing.
