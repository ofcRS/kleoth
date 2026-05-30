// swift-tools-version: 6.0
import PackageDescription

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
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
