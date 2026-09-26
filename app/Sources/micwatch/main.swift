import AppKit
import Foundation
import KleothCapture
import KleothCore

// micwatch [--seconds N] [--titles] [--detector]
//
// Prints every change in who holds the mic: pid, Core Audio bundle id, the
// outermost .app's bundle id, the resolved owner + method, the web-call
// assertion, the catalog verdict, the matched service; with `--detector` the
// offers the real `MeetingDetector` would make. It prints bundle ids, pids,
// booleans and timings only — never an executable path or a window title
// (`--titles` feeds the matcher and prints the matched SERVICE and a count).
// A shell-launched probe reads titles with the TERMINAL's grants.
let args = CommandLine.arguments.dropFirst()
var seconds: Double = 60
var readTitles = false
var runDetector = false
var i = args.startIndex
while i < args.endIndex {
    switch args[i] {
    case "--seconds": i += 1; seconds = args.indices.contains(i) ? (Double(args[i]) ?? 60) : 60
    case "--titles": readTitles = true
    case "--detector": runDetector = true
    default: break
    }
    i += 1
}

// A backgrounded CLI (or one on a locked screen) gets App-Napped: its timers
// coalesce and the trigger timings stop meaning anything. Held for the run.
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "micwatch timing")

let stamp = ISO8601DateFormatter()
stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
@MainActor func line(_ text: String) { print("\(stamp.string(from: Date())) \(text)"); fflush(stdout) }

var detector = MeetingDetector()
_ = detector.handle(.environment(MeetingDetector.Environment(offersEnabled: true), at: Date()))
var previous: Set<MicClient> = []
var tickTimer: Timer?

/// The bundle id of the outermost .app around `path`, or "-".
func appBundleId(ofExecutable path: String?) -> String {
    guard let path, let appPath = MeetingAppCatalog.outermostAppPath(executablePath: path) else { return "-" }
    return Bundle(path: appPath)?.bundleIdentifier ?? "-"
}

func verdictText(_ verdict: MeetingAppCatalog.Verdict) -> String {
    switch verdict {
    case .never: return "never"
    case .browser: return "browser"
    case .app(let sourceClass, _, _): return sourceClass.rawValue
    }
}

/// An effect without the source's window title (A.4: no titles in the output).
func effectText(_ effect: MeetingDetector.Effect) -> String {
    switch effect {
    case .show(let offer):
        return "show id=\(offer.id) kind=\(offer.kind) key=\(offer.source.key) class=\(offer.source.sourceClass.rawValue) name=\(offer.source.name) title=\(offer.source.windowTitle != nil)"
    case .withdraw(let offerId):
        return "withdraw id=\(offerId)"
    case .ignore(let key, let name):
        return "ignore key=\(key) name=\(name)"
    }
}

@MainActor func describe(_ clients: [MicClient]) -> Set<MeetingSource> {
    let webPids = WebCallAssertions.pids()
    let webApps = Set(webPids.compactMap { MicOwnerResolver.owner(of: MicClient(pid: $0, bundleId: nil, executablePath: nil))?.bundleId })
    var sources = Set<MeetingSource>()
    for client in clients {
        let owner = MicOwnerResolver.owner(of: client)
        let titles = (readTitles && owner != nil) ? WindowTitleReader.titles(ofProcess: owner!.pid) : []
        let hasWebCall = webPids.contains(client.pid) || owner.map { webApps.contains($0.bundleId) } == true
        let verdict = owner.map { MeetingAppCatalog.verdict(bundleId: $0.bundleId, appName: $0.name) }
        let source = owner.flatMap { MeetingSource.make(bundleId: $0.bundleId, appName: $0.name, windowTitles: titles, hasWebCall: hasWebCall) }
        let service = titles.lazy.compactMap { MeetingServiceMatcher.match(windowTitle: $0)?.name }.first ?? "-"
        line("  pid=\(client.pid) bundle=\(client.bundleId ?? "-") app=\(appBundleId(ofExecutable: client.executablePath))")
        line("    owner=\(owner.map { "<\($0.bundleId)> pid=\($0.pid) via \($0.method.rawValue)" } ?? "UNRESOLVED") webcall=\(hasWebCall) verdict=\(verdict.map(verdictText) ?? "-") service=\(service) titles=\(titles.count)")
        if let source { sources.insert(source) }
    }
    return sources
}

@MainActor func feed(_ event: MeetingDetector.Event) {
    for effect in detector.handle(event) { line("  DETECTOR \(effectText(effect))") }
    tickTimer?.invalidate()
    if let deadline = detector.nextDeadline {
        // A floor: a deadline already in the past must not become a busy loop.
        tickTimer = Timer.scheduledTimer(withTimeInterval: max(0.25, deadline.timeIntervalSinceNow), repeats: false) { _ in
            MainActor.assumeIsolated { feed(.tick(at: Date(), pointerOnPill: false)) }
        }
    }
}

let monitor = MicActivityMonitor()
let initial = MicActivityMonitor.snapshot()
line("micwatch: snapshot \(initial.count) client(s) running input; watching \(seconds)s (titles=\(readTitles), detector=\(runDetector))")
_ = describe(initial)
do {
    // `onChange` runs on the monitor's queue: hop to main before anything else.
    try monitor.start { clients in
        DispatchQueue.main.async {
            let now = Set(clients)
            for gone in previous.subtracting(now) { line("- input pid=\(gone.pid) bundle=\(gone.bundleId ?? "-")") }
            for new in now.subtracting(previous) { line("+ input pid=\(new.pid) bundle=\(new.bundleId ?? "-")") }
            previous = now
            let sources = describe(clients)
            if runDetector { feed(.observed(sources, at: Date())) }
        }
    }
} catch {
    line("micwatch: monitor failed to start: \(error)")
    exit(1)
}
Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
    MainActor.assumeIsolated {
        monitor.stop()
        line("micwatch: done")
        ProcessInfo.processInfo.endActivity(activity)
    }
    exit(0)
}
RunLoop.main.run()
