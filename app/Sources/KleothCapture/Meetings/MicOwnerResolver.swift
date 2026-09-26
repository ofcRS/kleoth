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
        if let cached = cache[key] {
            if isAlive(cached.pid) { return cached }
            cache.removeValue(forKey: key)
        }
        guard let owner = resolve(client) else { return nil }
        // A stand-in daemon (avconferenced) outlives the app it stands for and
        // serves FaceTime and Phone alike: resolve it afresh every time.
        guard owner.method != .daemonStandIn else { return owner }
        if cache.count > 256 { cache.removeAll() }
        cache[key] = owner
        return owner
    }

    private static func resolve(_ client: MicClient) -> MicOwner? {
        // 1. The app itself — a REGULAR app only (spec §4.2). WebKit's GPU
        //    process and many Chromium/Electron helpers check in with
        //    LaunchServices as `.accessory`: taken here they would name
        //    themselves instead of their host.
        if let app = launchServicesApp(pid: client.pid, regularOnly: true) {
            return MicOwner(bundleId: app.bundleId, name: app.name, pid: client.pid, method: .direct)
        }
        // 2. A daemon that stands for an app (FaceTime's avconferenced).
        if let bundleId = client.bundleId {
            for candidate in MeetingAppCatalog.daemonStandIn(bundleId: bundleId) {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: candidate).first {
                    return MicOwner(bundleId: candidate, name: app.localizedName ?? candidate, pid: app.processIdentifier, method: .daemonStandIn)
                }
            }
        }
        // 3. The outermost .app around a helper's executable (and an accessory
        //    app's own: Wispr Flow, another Kleoth build). A client built from
        //    a bare pid (the web-call assertion lookup) has no path: read it.
        let executablePath = client.executablePath ?? MicActivityMonitor.executablePath(of: client.pid)
        if let owner = bundleOwner(executablePath: executablePath, pid: client.pid, method: .appBundlePath) {
            return owner
        }
        // 4. WebKit's GPU process: the responsible process (Safari, a Safari web
        //    app, or any app embedding WebKit, a menu-bar one included).
        if client.bundleId?.hasPrefix("com.apple.WebKit.") == true {
            let responsible = responsibleFor?(client.pid) ?? 0
            if responsible > 0, responsible != client.pid {
                if let app = launchServicesApp(pid: responsible, regularOnly: false) {
                    return MicOwner(bundleId: app.bundleId, name: app.name, pid: responsible, method: .responsibleProcess)
                }
                // A real answer LaunchServices doesn't know: its .app, then its parents.
                return bundleOwner(executablePath: MicActivityMonitor.executablePath(of: responsible), pid: responsible, method: .responsibleProcess)
                    ?? parentChainOwner(from: responsible)
            }
            // No answer at all (the symbol is missing, or it named the client):
            // the one WebKit browser running, if there is exactly one.
            let running = MeetingAppCatalog.webKitBrowserBundleIds.compactMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
            }
            if running.count == 1, let app = running.first, let bundleId = app.bundleIdentifier {
                return MicOwner(bundleId: bundleId, name: app.localizedName ?? bundleId, pid: app.processIdentifier, method: .responsibleProcess)
            }
        }
        // 5. The parent chain, three levels.
        return parentChainOwner(from: client.pid)
    }

    /// The app at `executablePath`'s outermost .app, with the pid of its running
    /// instance (else `pid`).
    private static func bundleOwner(executablePath: String?, pid: pid_t, method: MicOwner.Method) -> MicOwner? {
        guard let path = executablePath, let appPath = MeetingAppCatalog.outermostAppPath(executablePath: path),
              let bundle = Bundle(path: appPath), let bundleId = bundle.bundleIdentifier else { return nil }
        let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        let hostPid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.processIdentifier ?? pid
        return MicOwner(bundleId: bundleId, name: name, pid: hostPid, method: method)
    }

    /// Up to three parents of `pid`: the first one LaunchServices knows (any
    /// policy but `.prohibited`).
    private static func parentChainOwner(from start: pid_t) -> MicOwner? {
        var pid = start
        for _ in 0..<3 {
            guard let parent = parentPid(of: pid), parent > 1 else { break }
            if let app = launchServicesApp(pid: parent, regularOnly: false) {
                return MicOwner(bundleId: app.bundleId, name: app.name, pid: parent, method: .parentProcess)
            }
            pid = parent
        }
        return nil
    }

    /// `pid` as LaunchServices knows it: `.regular` only, or anything but
    /// `.prohibited`.
    private static func launchServicesApp(pid: pid_t, regularOnly: Bool) -> (bundleId: String, name: String)? {
        guard let app = NSRunningApplication(processIdentifier: pid), let bundleId = app.bundleIdentifier else { return nil }
        let accepted = regularOnly ? app.activationPolicy == .regular : app.activationPolicy != .prohibited
        guard accepted else { return nil }
        return (bundleId, app.localizedName ?? bundleId)
    }

    /// The process exists (EPERM: it does, owned by someone else).
    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func parentPid(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
