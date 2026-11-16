import AppKit
import Foundation
import Sparkle

// The updater's end-to-end probe (docs/plans/2026-11-16-updater.md §6): Sparkle's real updater,
// pointed at a COPY of Kleoth.app and a feed of your choosing, with a user driver that prints
// instead of drawing. It refuses /Applications and dev.kleoth.app, launches nothing from the copy
// and never relaunches anything. app/updater-e2e.sh runs it.
//
//   updatecheck <copy/Kleoth.app> [--feed <url>]
//       finds the newest update in the feed, downloads it, and hands it to Sparkle's installer,
//       which extracts it, validates it (EdDSA against the copy's SUPublicEDKey, its code signature
//       against the copy's designated requirement) and, since the copy is not running, installs it
//       over the copy at once. Exit 0 = installed, 2 = no update, 1 = any error (a refused
//       signature included).
//   updatecheck --compare <a> <b>
//       how Sparkle orders two CFBundleVersion values: "<", "=" or ">".
//
// Sparkle keeps its per-bundle state in the COPY's bundle id defaults domain and caches: give the
// copy its own id (e.g. dev.kleoth.updateprobe) and delete both afterwards.

@MainActor
final class Probe: NSObject {
    private let feed: String?
    private var updater: SPUUpdater?

    init(feed: String?) {
        self.feed = feed
    }

    func run(host: Bundle) {
        let driver = PrintingDriver(probe: self)
        let updater = SPUUpdater(hostBundle: host, applicationBundle: host, userDriver: driver, delegate: self)
        self.updater = updater
        do {
            try updater.start()
        } catch {
            fail("updater did not start: \(describe(error))")
        }
        say("host \(host.bundleIdentifier ?? "?") \(bundleVersion(of: host)) at \(host.bundlePath)")
        say("feed \(updater.feedURL?.absoluteString ?? "none")")
        updater.checkForUpdates()
    }

    func finish(_ code: Int32, _ message: String) {
        say(message)
        // Let Sparkle's last callbacks and the installer's own exit settle before leaving.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(code) }
    }

    func fail(_ message: String) -> Never {
        say("FAILED: \(message)")
        exit(1)
    }
}

extension Probe: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? { feed }

    /// The probe updates a copy that is not running: there is nothing to relaunch, and nothing
    /// may be launched from the copy.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { false }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let code = (error as NSError).code
        if code == 1001 { return } // SUNoUpdateError: reported by the driver
        fail("aborted: \(describe(error))")
    }
}

@MainActor
final class PrintingDriver: NSObject, SPUUserDriver {
    private weak var probe: Probe?
    private var received: UInt64 = 0

    init(probe: Probe) {
        self.probe = probe
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        say("permission request (answered: no automatic checks)")
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        say("checking…")
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        say("update found: \(appcastItem.displayVersionString) (build \(appcastItem.versionString)), minimum macOS \(appcastItem.minimumSystemVersion ?? "-"), \(appcastItem.contentLength) bytes, \(appcastItem.fileURL?.absoluteString ?? "no enclosure")")
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        say("release notes: \(downloadData.data.count) bytes (\(downloadData.mimeType ?? "?"))")
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        say("release notes failed: \(describe(error))")
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        probe?.finish(2, "no update: \(describe(error))")
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        probe?.fail("updater error: \(describe(error))")
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        say("downloading…")
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        say("expecting \(expectedContentLength) bytes")
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
    }

    func showDownloadDidStartExtractingUpdate() {
        say("downloaded \(received) bytes; the installer extracts and validates…")
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    /// Not reached for a copy that isn't running (the installer goes straight on), kept for completeness.
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        say("ready to install")
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        // Past validation: the installer reports installing only for an update it accepted.
        say("validated; installing (application terminated: \(applicationTerminated))…")
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        probe?.finish(0, "OK: installed (relaunched: \(relaunched))")
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        say("session finished")
    }
}

nonisolated func say(_ line: String) {
    FileHandle.standardOutput.write(Data("updatecheck: \(line)\n".utf8))
}

nonisolated func bundleVersion(of bundle: Bundle) -> String {
    let info = bundle.infoDictionary ?? [:]
    return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
}

/// The error and every underlying one: Sparkle's validation failures nest the reason.
nonisolated func describe(_ error: any Error) -> String {
    var parts: [String] = []
    var current: NSError? = error as NSError
    while let e = current, parts.count < 6 {
        parts.append("\(e.localizedDescription) [\(e.domain) \(e.code)]")
        current = e.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return parts.joined(separator: " <- ")
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())

if args.first == "--compare" {
    guard args.count == 3 else { say("usage: updatecheck --compare <a> <b>"); exit(64) }
    let result = SUStandardVersionComparator.default.compareVersion(args[1], toVersion: args[2])
    let sign = result == .orderedAscending ? "<" : (result == .orderedSame ? "=" : ">")
    print("\(args[1]) \(sign) \(args[2])")
    exit(0)
}

guard let path = args.first, !path.hasPrefix("-") else {
    say("usage: updatecheck <copy/Kleoth.app> [--feed <url>] | --compare <a> <b>")
    exit(64)
}
let appURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
if appURL.path.hasPrefix("/Applications/") {
    say("refusing /Applications: point this at a copy")
    exit(64)
}
guard let host = Bundle(url: appURL), host.bundleIdentifier != nil else {
    say("no app bundle at \(appURL.path)")
    exit(64)
}
if host.bundleIdentifier == "dev.kleoth.app" {
    say("refusing dev.kleoth.app: give the copy its own bundle id (its defaults and caches are Sparkle's state)")
    exit(64)
}
var feed: String?
if let i = args.firstIndex(of: "--feed"), i + 1 < args.count { feed = args[i + 1] }

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
MainActor.assumeIsolated {
    let probe = Probe(feed: feed)
    probe.run(host: host)
    // Keep it alive for the run loop (Sparkle holds its delegate weakly).
    objc_setAssociatedObject(app, "updatecheck.probe", probe, .OBJC_ASSOCIATION_RETAIN)
}
// A run that hangs has failed.
DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
    say("FAILED: timed out after 300 s")
    exit(1)
}
app.run()
