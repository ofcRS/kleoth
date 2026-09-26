import AppKit
import Foundation
import KleothCore
import os

/// The app a person would name for a Core Audio client (design §3.2.1).
public struct MicOwner: Sendable, Equatable {
    public enum Method: String, Sendable { case direct, appBundlePath, parentProcess, responsibleProcess, daemonStandIn }
    public var bundleId: String
    public var name: String
    public var pid: pid_t
    public var method: Method
}

public enum MicOwnerResolver {
    private static let lock = NSLock()
    /// Resolved owners only: a client that resolves to nothing is tried again
    /// next time (a helper whose app registers with LaunchServices a moment
    /// after it opened the mic).
    nonisolated(unsafe) private static var cache: [String: MicOwner] = [:]

    /// `responsibility_get_pid_responsible_for_pid`, exported by
    /// `/usr/lib/system/libquarantine.dylib` (no header), looked up once.
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFor: ResponsibleFn? = {
        // RTLD_DEFAULT: libquarantine is loaded in every process.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            Logger(subsystem: "dev.kleoth", category: "MicActivity")
                .notice("responsibility_get_pid_responsible_for_pid is missing — WebKit mic clients fall back to the one WebKit browser running")
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    public static func owner(of client: MicClient) -> MicOwner? {
        let key = "\(client.pid):\(client.bundleId ?? "")"
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        guard let owner = resolve(client) else { return nil }
        if cache.count > 256 { cache.removeAll() }
        cache[key] = owner
        return owner
    }

    private static func resolve(_ client: MicClient) -> MicOwner? {
        // 1. The app itself (a regular or accessory app owns its own pid).
        if let app = regularApp(pid: client.pid) { return MicOwner(bundleId: app.0, name: app.1, pid: client.pid, method: .direct) }
        // 2. A daemon that stands for an app (FaceTime's avconferenced).
        if let bundleId = client.bundleId {
            for candidate in MeetingAppCatalog.daemonStandIn(bundleId: bundleId) {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: candidate).first {
                    return MicOwner(bundleId: candidate, name: app.localizedName ?? candidate, pid: app.processIdentifier, method: .daemonStandIn)
                }
            }
        }
        // 3. The outermost .app around a helper's executable.
        if let path = client.executablePath, let appPath = MeetingAppCatalog.outermostAppPath(executablePath: path),
           let bundle = Bundle(path: appPath), let bundleId = bundle.bundleIdentifier {
            let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
            let hostPid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.processIdentifier ?? client.pid
            return MicOwner(bundleId: bundleId, name: name, pid: hostPid, method: .appBundlePath)
        }
        // 4. WebKit's GPU process: the responsible process (Safari, or any app
        //    embedding WebKit); without an answer, the one WebKit browser running.
        if client.bundleId?.hasPrefix("com.apple.WebKit.") == true {
            if let fn = responsibleFor {
                let responsible = fn(client.pid)
                if responsible > 0, responsible != client.pid, let app = regularApp(pid: responsible) {
                    return MicOwner(bundleId: app.0, name: app.1, pid: responsible, method: .responsibleProcess)
                }
            }
            let running = MeetingAppCatalog.webKitBrowserBundleIds.compactMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
            }
            if running.count == 1, let app = running.first, let bundleId = app.bundleIdentifier {
                return MicOwner(bundleId: bundleId, name: app.localizedName ?? bundleId, pid: app.processIdentifier, method: .responsibleProcess)
            }
        }
        // 5. The parent chain, three levels.
        var pid = client.pid
        for _ in 0..<3 {
            guard let parent = parentPid(of: pid), parent > 1 else { break }
            if let app = regularApp(pid: parent) { return MicOwner(bundleId: app.0, name: app.1, pid: parent, method: .parentProcess) }
            pid = parent
        }
        return nil
    }

    private static func regularApp(pid: pid_t) -> (String, String)? {
        guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited,
              let bundleId = app.bundleIdentifier else { return nil }
        return (bundleId, app.localizedName ?? bundleId)
    }

    private static func parentPid(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
