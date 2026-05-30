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
        .package(path: ".."),
    ],
    targets: [
        .target(
            name: "KleothCapture",
            dependencies: [
                .product(name: "KleothCore", package: "kleoth-app"),
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
    ]
)
