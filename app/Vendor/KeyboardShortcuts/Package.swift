// swift-tools-version:6.1
// Vendored from sindresorhus/KeyboardShortcuts 2.4.0 (see README.md); the upstream test target is dropped.
import PackageDescription

let package = Package(
	name: "KeyboardShortcuts",
	defaultLocalization: "en",
	platforms: [
		.macOS(.v10_15)
	],
	products: [
		.library(
			name: "KeyboardShortcuts",
			targets: [
				"KeyboardShortcuts"
			]
		)
	],
	targets: [
		.target(
			name: "KeyboardShortcuts",
			swiftSettings: [
				.swiftLanguageMode(.v5)
			]
		)
	]
)
