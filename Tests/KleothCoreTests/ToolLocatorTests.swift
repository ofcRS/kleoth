import Testing
import Foundation
@testable import KleothCore

@Suite struct ToolLocatorTests {
    /// A temp tree: `a/` (empty), `b/claude` (executable), `c/claude` (executable).
    static func makeTree() throws -> (root: URL, dirs: [URL]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-locator-\(UUID().uuidString)", isDirectory: true)
        var dirs: [URL] = []
        for name in ["a", "b", "c"] {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            dirs.append(dir)
        }
        for dir in dirs.dropFirst() {
            let file = dir.appendingPathComponent("claude")
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        // A non-executable file must not count.
        let plain = dirs[0].appendingPathComponent("codex")
        try Data("x".utf8).write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        return (root, dirs)
    }

    @Test func firstExecutableInSearchOrderWins() throws {
        let (root, dirs) = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ToolLocator(searchDirectories: dirs)
        #expect(locator.find("claude") == dirs[1].appendingPathComponent("claude"))
        #expect(locator.find("codex") == nil)
        #expect(locator.find("nothing") == nil)
    }

    @Test func pathValueJoinsDirectories() {
        let locator = ToolLocator(searchDirectories: [URL(fileURLWithPath: "/x/bin"), URL(fileURLWithPath: "/y")])
        #expect(locator.pathValue == "/x/bin:/y")
        let env = locator.environment()
        #expect(env["PATH"] == "/x/bin:/y")
        #expect(env["HOME"] == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(env["LANG"] == "en_US.UTF-8")
    }

    @Test func standardLocatorSearchesTheUsualPlacesFirst() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = ToolLocator.standard.searchDirectories.map(\.path)
        #expect(dirs.prefix(3) == [
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ])
        #expect(dirs.contains(home.appendingPathComponent(".local/share/mise/shims").path))
        #expect(dirs.contains(home.appendingPathComponent(".codex/bin").path))
    }
}
