import Foundation

/// Finds installed CLIs. A GUI app's `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`,
/// so the usual install locations are searched explicitly, before `$PATH`.
public struct ToolLocator: Sendable {
    public let searchDirectories: [URL]

    public init(searchDirectories: [URL]) {
        self.searchDirectories = searchDirectories
    }

    /// `~/.local/bin` (Claude Code's installer), Homebrew, `/usr/local/bin`,
    /// mise shims, `~/.codex/bin`, then every `$PATH` entry not already listed.
    public static let standard: ToolLocator = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs: [URL] = [
            home.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            home.appendingPathComponent(".local/share/mise/shims", isDirectory: true),
            home.appendingPathComponent(".codex/bin", isDirectory: true),
        ]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for entry in path.split(separator: ":") where !entry.isEmpty {
            let url = URL(fileURLWithPath: String(entry), isDirectory: true)
            if !dirs.contains(where: { $0.path == url.path }) { dirs.append(url) }
        }
        return ToolLocator(searchDirectories: dirs)
    }()

    /// The first executable regular file named `name` in search order.
    public func find(_ name: String) -> URL? {
        let fm = FileManager.default
        for dir in searchDirectories {
            let candidate = dir.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  fm.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate
        }
        return nil
    }

    /// `PATH` for a spawned tool.
    public var pathValue: String {
        searchDirectories.map(\.path).joined(separator: ":")
    }

    /// The minimal environment a spawned tool gets: enough to find its own
    /// config, keychain and temp dir — nothing inherited from Kleoth beyond that.
    public func environment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": pathValue,
            "LANG": "en_US.UTF-8",
            "TMPDIR": inherited["TMPDIR"] ?? NSTemporaryDirectory(),
        ]
        if let user = inherited["USER"] { env["USER"] = user }
        return env
    }
}
