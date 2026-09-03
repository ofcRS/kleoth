// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KleothApp",
    platforms: [
        .macOS("14.4")
    ],
    products: [
        .executable(name: "KleothApp", targets: ["KleothApp"]),
        .library(name: "KleothCapture", targets: ["KleothCapture"]),
    ],
    dependencies: [
        // `name:` pins the dependency identity: without it SwiftPM derives it from
        // the directory name, so the app package could only build from a checkout
        // named `kleoth-app` (every worktree hit this).
        .package(name: "kleoth-app", path: ".."),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "KleothCapture",
            dependencies: [
                .product(name: "KleothCore", package: "kleoth-app"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "KleothApp",
            dependencies: [
                "KleothCapture",
                .product(name: "KleothCore", package: "kleoth-app"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            // Brand assets (menu-bar template glyph + empty-state illustrations),
            // loaded at runtime via `Bundle.module` (see `KleothAssets`).
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "taptest",
            dependencies: ["KleothCapture"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Headless one-off: transcribe an existing meeting folder with the same
        // on-device WhisperKit engine the app uses. Dev/recovery utility.
        .executableTarget(
            name: "localtranscribe",
            dependencies: [
                "KleothCapture",
                .product(name: "KleothCore", package: "kleoth-app"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Headless dictation pipeline probe: record N seconds from the mic →
        // prepare → Scribe → polish, print the result. No hotkey, no paste, no
        // Accessibility needed. `dictate [seconds] [--transcriber scribe] [--model <slug>]`
        .executableTarget(
            name: "dictate",
            dependencies: [
                "KleothCapture",
                .product(name: "KleothCore", package: "kleoth-app"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
