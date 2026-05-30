// swift-tools-version: 6.0
import PackageDescription

// This environment ships only the Command Line Tools (no full Xcode), so the
// public `XCTest` module is unavailable. The swift-testing framework *is*
// present under the CLT, but not on the default search paths. These paths let
// the test target compile against `import Testing` and link/load its runtime
// (`Testing.framework` + `lib_TestingInterop.dylib`).
//
// NOTE: actually *running* the tests still requires passing the same search
// paths on the command line so SwiftPM routes execution through the
// swift-testing helper, e.g.:
//
//   swift test \
//     -Xswiftc -F -Xswiftc "$TESTING_FW" \
//     -Xlinker  -F -Xlinker  "$TESTING_FW" \
//     -Xlinker  -rpath -Xlinker "$TESTING_FW" \
//     -Xlinker  -L -Xlinker  "$TESTING_LIB" \
//     -Xlinker  -rpath -Xlinker "$TESTING_LIB"
//
// where TESTING_FW / TESTING_LIB are the two constants below.
let testingFrameworksDir = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testingInteropLibDir = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "kleoth",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "KleothCore", targets: ["KleothCore"]),
        .executable(name: "kleoth", targets: ["kleoth"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "KleothCore",
            dependencies: [],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "kleoth",
            dependencies: [
                "KleothCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "KleothCoreTests",
            dependencies: ["KleothCore"],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // Resolve `import Testing` (swift-testing) under CLT-only.
                .unsafeFlags(["-F", testingFrameworksDir]),
            ],
            linkerSettings: [
                // Link & load the swift-testing runtime under CLT-only.
                .unsafeFlags([
                    "-F", testingFrameworksDir,
                    "-L", testingInteropLibDir,
                    "-Xlinker", "-rpath", "-Xlinker", testingFrameworksDir,
                    "-Xlinker", "-rpath", "-Xlinker", testingInteropLibDir,
                ]),
            ]
        ),
    ]
)
