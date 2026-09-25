import AppKit
import ApplicationServices
import Foundation
import KleothCore

/// `dictate --focus-probe` — the spike behind context-aware dictation
/// (`docs/plans/2026-09-24-dictation-context.md` §3.2, §3.6, §8 task 1).
/// Dictation will read the field it pastes into; which apps give a caret, a
/// selection and the text around it through Accessibility — and how soon after
/// a *wake* Chromium and Electron build their tree — can only be learned from
/// the apps themselves. The user runs this by hand, on test text: after the
/// delay it takes the frontmost app, applies one wake, then polls the focused
/// element with the reads `FocusedTextReader` will make, one line per poll.
///
/// What it may do to the app it reads, by construction:
/// - Post events: never.
/// - Write: only the `--wake manual` / `--wake enhanced` flag (`ProbeAX.set`),
///   and only after reading it — a flag that reads as neither a boolean nor
///   absent (-25205 unsupported, -25212 no value) is never written. It is set
///   back to false on exit and on Ctrl-C (also SIGTERM, SIGHUP and SIGQUIT),
///   only when the read found it off or absent.
/// - Read field text: only when the focused element's subrole was read and
///   isn't `AXSecureTextField` (fail closed). Print it: only with
///   `--show-text`; otherwise lengths.
/// - Wait on a hung app: at most 0.25 s per message, the timeout set on each
///   element — never on the system-wide element, where it is process-wide —
///   and 2 s, with one retry, for setting the wake flag back.
/// - Prompt for Accessibility: never. A shell-launched probe runs on the
///   terminal's grant; without one it says so and exits.
///
/// The flags, the per-poll line and the CPU summary are pure statics here;
/// `ProbeAX` sends every AX message and `FocusProbeSession` sequences a run.
enum FocusProbe {
    /// `main.swift` hands the command line here, minus this flag, before any
    /// other argument handling (no keys or settings are loaded for the probe).
    static let flag = "--focus-probe"

    static let synopsis =
        "dictate --focus-probe [--delay 5] [--wake none|role|manual|enhanced] [--polls 20] [--interval 0.25] [--show-text] [--cpu]"

    /// Per element, as the reader will set it (`contextElementTimeout`, spec §4.1).
    static let elementTimeout: Float = 0.25
    /// On the app element just before setting the wake flag back: that write
    /// must land, so it gets longer than a poll's read.
    static let restoreTimeout: Float = 2
    /// UTF-16 units (as AX counts) read on each side of the selection or caret.
    static let windowLength = 40
    /// `--cpu`: samples once a second for this long before the wake…
    static let usageSecondsBefore = 10
    /// …and until this long after it.
    static let usageSecondsAfter = 30

    static let untrustedMessage =
        "The terminal running this probe needs Accessibility: System Settings → Privacy & Security → Accessibility → add your terminal app (a shell-launched probe uses the terminal's permission). Remove it again when you're done."

    /// The facts read with one `AXUIElementCopyMultipleAttributeValues`, as the
    /// reader will (spec §4.4), with their short names in a poll line's `err`
    /// and the kind of value each must be.
    static let factAttributes: [(attribute: String, name: String, kind: ProbeAX.Kind)] = [
        ("AXRole", "role", .string),
        ("AXSubrole", "subrole", .string),
        ("AXSelectedTextRange", "range", .range),
        ("AXNumberOfCharacters", "chars", .number),
        ("AXPlaceholderValue", "placeholder", .string),
    ]

    static let errorLegend =
        "-25200 failure · -25201 illegal argument · -25202 invalid element · -25204 cannot complete (timed out) · -25205 unsupported · -25211 API disabled · -25212 no value · -25213 parameterized unsupported · null = a CFNull reply · type = a reply of an unexpected type"

    // MARK: - Flags

    enum Wake: String, Sendable {
        /// Nothing before the first poll.
        case none
        /// Reads `AXRole` of the app, then of its focused element — what makes
        /// Chrome's and Electron's application object build the tree (§3.2).
        case role
        /// Sets `AXManualAccessibility`, Electron's switch for assistive apps.
        case manual
        /// Sets `AXEnhancedUserInterface`, VoiceOver's flag (window managers
        /// misbehave while it is on, §3.6).
        case enhanced

        /// The app-element attribute this wake writes; nil = it writes nothing.
        var attribute: String? {
            switch self {
            case .none, .role: nil
            case .manual: "AXManualAccessibility"
            case .enhanced: "AXEnhancedUserInterface"
            }
        }
    }

    struct Options: Equatable, Sendable {
        var delay: Double = 5
        var wake: Wake = .none
        var polls = 20
        var interval: Double = 0.25
        var showText = false
        var cpu = false
    }

    enum Command: Equatable {
        case run(Options)
        case help
        case invalid(String)
    }

    /// The probe's flags (`--focus-probe` itself already removed). The bounds
    /// keep every later `Duration` finite: a trap after the wake would skip
    /// setting the wake flag back.
    static func parse(_ arguments: [String]) -> Command {
        var options = Options()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "-h", "--help":
                return .help
            case "--delay":
                guard let value = iterator.next().flatMap({ Double($0) }), (0...600).contains(value) else {
                    return .invalid("--delay needs seconds from 0 to 600")
                }
                options.delay = value
            case "--wake":
                guard let value = iterator.next().flatMap({ Wake(rawValue: $0) }) else {
                    return .invalid("--wake needs none, role, manual or enhanced")
                }
                options.wake = value
            case "--polls":
                guard let value = iterator.next().flatMap({ Int($0) }), (1...10_000).contains(value) else {
                    return .invalid("--polls needs a count from 1 to 10000")
                }
                options.polls = value
            case "--interval":
                guard let value = iterator.next().flatMap({ Double($0) }), value > 0, value <= 60 else {
                    return .invalid("--interval needs seconds above 0, at most 60")
                }
                options.interval = value
            case "--show-text":
                options.showText = true
            case "--cpu":
                options.cpu = true
            default:
                return .invalid("unknown --focus-probe flag '\(argument)'")
            }
        }
        return .run(options)
    }

    static let usageText = """
        usage: \(synopsis)

        Accessibility spike for context-aware dictation. After the delay it reads the
        focused field of the app in front with the reads Kleoth's reader will make,
        and prints one line per poll: role, editability, selection, the \(windowLength)-character
        windows around it, lengths, milliseconds per AX message and AX error codes.
        It posts no events and writes no attribute except the --wake flag under test
        (never one it can't read), which it sets back on exit and on Ctrl-C. Field
        text is read only once the subrole shows no password field, and printed only
        with --show-text. The terminal running it needs System Settings → Privacy &
        Security → Accessibility (a shell-launched probe uses the terminal's permission).

          --delay S       seconds to focus the field before the read (default 5)
          --wake MODE     before the first poll (default none):
                            none      nothing
                            role      read AXRole of the app, then of its focused element
                            manual    set AXManualAccessibility (Electron's switch for assistive apps)
                            enhanced  set AXEnhancedUserInterface (VoiceOver's flag; window
                                      managers misbehave while it is on)
          --polls N       polls, the first right after the wake (default 20)
          --interval S    seconds between polls (default 0.25)
          --show-text     also print the selection and both windows, quoted (test text only)
          --cpu           %CPU and RSS from ps for the app and its direct children (helpers),
                          once a second for \(usageSecondsBefore) s before the wake and until \(usageSecondsAfter) s after it;
                          the means of main, helpers and total are compared at the end

        """

    // MARK: - Entry

    /// Runs the probe for `arguments`; the usage paths and a refused trust
    /// check exit instead of returning.
    @MainActor
    static func run(_ arguments: [String]) async {
        switch parse(arguments) {
        case .help:
            usage()
        case .invalid(let problem):
            usage(problem)
        case .run(let options):
            await FocusProbeSession(options: options).run()
        }
    }

    static func usage(_ problem: String? = nil) -> Never {
        let text = (problem.map { "dictate: \($0)\n" } ?? "") + usageText
        FileHandle.standardError.write(Data(text.utf8))
        exit(2)
    }

    // MARK: - One poll, as data

    /// A range in UTF-16 units, as AX counts (the reader's `DictationTextRange`).
    struct TextRange: Equatable, Sendable {
        var location: Int
        var length: Int
    }

    enum Editability: String, Equatable {
        case value
        case ancestor
        case both = "value+ancestor"
        case no

        /// Editable text is a settable `AXValue` or an `AXEditableAncestor`
        /// (§3.2); both are reported, since the spike decides which one the
        /// reader can rely on.
        init(valueIsSettable: Bool, hasEditableAncestor: Bool) {
            switch (valueIsSettable, hasEditableAncestor) {
            case (true, true): self = .both
            case (true, false): self = .value
            case (false, true): self = .ancestor
            case (false, false): self = .no
            }
        }
    }

    struct Timing: Equatable {
        var name: String
        var milliseconds: Double
    }

    /// An odd reply, by message or attribute name.
    struct Failure: Equatable {
        enum Problem: Equatable {
            /// A non-success `AXError`, by raw value.
            case error(Int32)
            /// A CFNull value.
            case null
            /// A value of a type the attribute never has.
            case unexpectedType
        }

        var name: String
        var problem: Problem

        /// `role=-25205`, `subrole=null`, `before=type`.
        var rendered: String {
            switch problem {
            case .error(let code): "\(name)=\(code)"
            case .null: "\(name)=null"
            case .unexpectedType: "\(name)=type"
            }
        }
    }

    /// Why a poll read no text at all (fail closed, §3.2).
    enum TextSkip: String, Equatable {
        case secureField = "secure field"
        /// The multi-attribute call failed, or AXSubrole's reply was neither
        /// a string nor a documented "none": it could be a password field.
        case subroleUnknown = "subrole unknown"
    }

    /// Everything one poll learned. Optional fields are nil when not read.
    struct PollRecord: Equatable {
        var index: Int
        /// From the start of the wake to the start of this poll.
        var millisecondsSinceWake: Double
        /// The process serving the focused element (`AXUIElementGetPid`): the
        /// app's own unless the element is hosted by another process.
        var processIdentifier: Int32
        var bundleId: String?
        var role: String?
        var subrole: String?
        var editability: Editability?
        var characterCount: Int?
        var selection: TextRange?
        /// `AXSelectedText`.
        var selectedText: String?
        /// Each window as planned, and the text that came back ("" for an
        /// empty window, which sends no message).
        var beforeWindow: TextRange?
        var before: String?
        var afterWindow: TextRange?
        var after: String?
        var placeholder: String?
        /// Set when no text was read on this poll, and why.
        var textSkipped: TextSkip?
        /// A window read failed, so `AXValue` was read too — the reader's
        /// fallback — and `value` holds it (nil when that read failed as well).
        var valueRead = false
        var value: String?
        /// Every AX message, in the order sent.
        var timings: [Timing] = []
        /// Every odd reply: a non-success `AXError`, a CFNull, an unexpected type.
        var errors: [Failure] = []
    }

    /// The `AXStringForRange` windows around a selection or caret, clamped to
    /// the field. Without a character count the after-window isn't planned: a
    /// range past the field's end is never sent to another app.
    static func windows(around selection: TextRange, characterCount: Int?) -> (before: TextRange?, after: TextRange?) {
        guard selection.location >= 0, selection.length >= 0 else { return (nil, nil) }
        let limit = characterCount.map { max(0, $0) }
        let start = min(selection.location, limit ?? selection.location)
        let beforeStart = max(0, start - windowLength)
        let before = TextRange(location: beforeStart, length: start - beforeStart)
        guard let limit else { return (before, nil) }
        let end = start + min(selection.length, limit - start)     // ≤ limit, no overflow
        return (before, TextRange(location: end, length: min(windowLength, limit - end)))
    }

    // MARK: - Output

    /// One poll as one line: `key=value` fields (`-` = not read), then `| ms`
    /// per AX message and `| err` with every odd reply (an AXError raw value,
    /// `null`, `type`).
    static func line(_ poll: PollRecord, pollCount: Int) -> String {
        var fields = [
            "#" + zeroPadded(poll.index, toWidthOf: pollCount),
            "+" + String(format: "%.0f", poll.millisecondsSinceWake) + "ms",
            "pid=\(poll.processIdentifier)",
            "app=\(poll.bundleId ?? "-")",
            "role=\(poll.role ?? "-")",
            "subrole=\(poll.subrole ?? "-")",
            "edit=\(poll.editability?.rawValue ?? "-")",
            "chars=\(poll.characterCount.map { String($0) } ?? "-")",
            "range=\(poll.selection.map { "\($0.location)+\($0.length)" } ?? "-")",
        ]
        if let skip = poll.textSkipped {
            fields.append("text=skipped (\(skip.rawValue))")
        } else {
            let replacements = objectReplacementCount(in: [poll.selectedText, poll.before, poll.after])
            fields.append("sel=\(poll.selectedText.map { String($0.utf16.count) } ?? "-")")
            fields.append("before=\(window(poll.beforeWindow, read: poll.before))")
            fields.append("after=\(window(poll.afterWindow, read: poll.after))")
            if poll.valueRead {
                fields.append("value=\(poll.value.map { String($0.utf16.count) } ?? "-")")
            }
            fields.append("fffc=\(replacements.map { String($0) } ?? "-")")
        }
        fields.append("placeholder=\(poll.placeholder.map { String($0.utf16.count) } ?? "-")")
        let timings = poll.timings.map { "\($0.name)=" + String(format: "%.1f", $0.milliseconds) }
        let errors = poll.errors.map(\.rendered)
        return fields.joined(separator: " ")
            + " | ms " + (timings.isEmpty ? "-" : timings.joined(separator: " "))
            + " | err " + (errors.isEmpty ? "none" : errors.joined(separator: " "))
    }

    /// `--show-text`: the selection, both windows and a fallback `AXValue`,
    /// quoted, under the poll's line.
    static func textLine(_ poll: PollRecord) -> String {
        if let skip = poll.textSkipped {
            return "    text skipped (\(skip.rawValue))"
        }
        let selection = poll.selectedText.map(quoted) ?? "-"
        let before = poll.before.map(quoted) ?? "-"
        let after = poll.after.map(quoted) ?? "-"
        let value = poll.valueRead ? " value=\(poll.value.map(quoted) ?? "-")" : ""
        return "    text sel=\(selection) before=\(before) after=\(after)\(value)"
    }

    /// `got/asked` in UTF-16 units; `-/asked` when the read failed; `-` when
    /// the window wasn't planned (no selection range, or no character count).
    static func window(_ planned: TextRange?, read: String?) -> String {
        guard let planned else { return "-" }
        return "\(read.map { String($0.utf16.count) } ?? "-")/\(planned.length)"
    }

    /// U+FFFC (an inline object — a mention chip, an image) across the texts
    /// that were read; nil when none was.
    static func objectReplacementCount(in texts: [String?]) -> Int? {
        let read = texts.compactMap { $0 }
        guard !read.isEmpty else { return nil }
        return read.reduce(0) { total, text in
            total + text.unicodeScalars.filter { $0 == "\u{FFFC}" }.count
        }
    }

    /// On one line, in double quotes: line breaks, tabs, controls and the two
    /// characters the reader strips (U+FFFC, U+FFFD) are spelled out.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{FFFC}", "\u{FFFD}":
                out += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            default:
                switch scalar.properties.generalCategory {
                case .control, .lineSeparator, .paragraphSeparator:
                    out += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
                default:
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func zeroPadded(_ value: Int, toWidthOf widest: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, String(widest).count - digits.count)) + digits
    }

    /// "5", "2.5", "0.25".
    static func seconds(_ value: Double) -> String {
        String(format: "%g", value)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    // MARK: - CPU and memory (`--cpu`)

    // Chromium and Electron build a page's accessibility tree in a renderer
    // helper and mirror it in the app's own process, so a sample covers the
    // app and all of its direct children (renderer, GPU and utility helpers).

    /// One process's `ps` row.
    struct ProcessUsage: Equatable, Sendable {
        var cpuPercent: Double
        var residentKilobytes: Double

        static let zero = ProcessUsage(cpuPercent: 0, residentKilobytes: 0)

        static func + (lhs: ProcessUsage, rhs: ProcessUsage) -> ProcessUsage {
            ProcessUsage(cpuPercent: lhs.cpuPercent + rhs.cpuPercent,
                         residentKilobytes: lhs.residentKilobytes + rhs.residentKilobytes)
        }

        static func - (lhs: ProcessUsage, rhs: ProcessUsage) -> ProcessUsage {
            ProcessUsage(cpuPercent: lhs.cpuPercent - rhs.cpuPercent,
                         residentKilobytes: lhs.residentKilobytes - rhs.residentKilobytes)
        }
    }

    /// One sample: the app's own process and each direct child that `ps` still
    /// found, by pid. A child that exited between `pgrep` and `ps` is absent.
    struct UsageSample: Equatable, Sendable {
        var main: ProcessUsage
        var helpers: [Int32: ProcessUsage]
    }

    /// One `--cpu` phase: its samples, and the command names (`ps -o
    /// pid=,comm=`, run right after the last sample) of that sample's helpers.
    struct UsagePhase: Equatable, Sendable {
        var samples: [UsageSample] = []
        var helperNames: [Int32: String] = [:]
    }

    /// A phase's means. The helper row is the mean of each sample's sum over
    /// the helpers present in it: a helper that started or exited mid-phase
    /// counts in the samples it was running in, and nowhere else.
    struct UsageMeans: Equatable {
        var sampleCount: Int
        var main: ProcessUsage
        var helpers: ProcessUsage
        /// Fewest and most helpers present in one sample.
        var helperCounts: ClosedRange<Int>

        var total: ProcessUsage { main + helpers }
    }

    /// `pgrep -P <pid>`: one pid per line.
    static func parsePids(_ output: String) -> [Int32] {
        output.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// `ps -o pid=,%cpu=,rss=`: "96577   0.3   2528" per process, keyed by
    /// pid. A malformed line is skipped.
    static func parseProcessRows(_ output: String) -> [Int32: ProcessUsage] {
        var rows: [Int32: ProcessUsage] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, let pid = Int32(fields[0]), let cpu = Double(fields[1]),
                  let rss = Double(fields[2]) else { continue }
            rows[pid] = ProcessUsage(cpuPercent: cpu, residentKilobytes: rss)
        }
        return rows
    }

    /// `ps -o pid=,comm=`: "96577 /Applications/…/T3 Code Helper (GPU)" per
    /// process, keyed by pid. The command runs to the end of the line (it may
    /// hold spaces); a malformed line is skipped.
    static func parseCommandNames(_ output: String) -> [Int32: String] {
        var names: [Int32: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let row = line.drop(while: \.isWhitespace)
            guard let gap = row.firstIndex(where: \.isWhitespace), let pid = Int32(row[..<gap]) else { continue }
            let command = row[gap...].trimmingCharacters(in: .whitespaces)
            if !command.isEmpty {
                names[pid] = command
            }
        }
        return names
    }

    /// A sample from one `ps` table; nil when the app's own process isn't in
    /// it (it quit, and a sample without it compares with nothing). A listed
    /// child without a row is absent from this sample.
    static func usageSample(pid: Int32, children: [Int32], rows: [Int32: ProcessUsage]) -> UsageSample? {
        guard let main = rows[pid] else { return nil }
        var helpers: [Int32: ProcessUsage] = [:]
        for child in Set(children).subtracting([pid]) {
            helpers[child] = rows[child]
        }
        return UsageSample(main: main, helpers: helpers)
    }

    /// nil for a phase without a single sample.
    static func usageMeans(_ samples: [UsageSample]) -> UsageMeans? {
        let helperCounts = samples.map(\.helpers.count)
        guard let fewest = helperCounts.min(), let most = helperCounts.max() else { return nil }
        let count = Double(samples.count)
        func mean(_ values: [ProcessUsage]) -> ProcessUsage {
            let sum = values.reduce(.zero, +)
            return ProcessUsage(cpuPercent: sum.cpuPercent / count, residentKilobytes: sum.residentKilobytes / count)
        }
        return UsageMeans(
            sampleCount: samples.count,
            main: mean(samples.map(\.main)),
            helpers: mean(samples.map { $0.helpers.values.reduce(.zero, +) }),
            helperCounts: fewest...most
        )
    }

    /// Mean %CPU and RSS before and after the wake, as `main`, `helpers (n)`
    /// and `total` rows with each phase's helpers named, then the change.
    static func usageSummary(before: UsagePhase, after: UsagePhase) -> [String] {
        let early = usageMeans(before.samples)
        let late = usageMeans(after.samples)
        var lines = [usageHeader("cpu before", early, window: "the \(usageSecondsBefore) s before the wake")]
        lines += early.map(usageRows) ?? []
        lines += helperRows(before)
        lines.append(usageHeader("cpu after ", late, window: "1–\(usageSecondsAfter) s after the wake"))
        lines += late.map(usageRows) ?? []
        lines += helperRows(after)
        if let early, let late {
            lines.append("cpu change: after − before")
            lines.append(usageRow("main", late.main - early.main, signed: true))
            lines.append(usageRow("helpers", late.helpers - early.helpers, signed: true))
            lines.append(usageRow("total", late.total - early.total, signed: true))
        }
        return lines
    }

    static func usageHeader(_ label: String, _ means: UsageMeans?, window: String) -> String {
        guard let means else { return "\(label): no samples, \(window)" }
        return "\(label): mean %CPU and RSS of \(means.sampleCount) samples, \(window)"
    }

    /// `helpers (n)`: n is the number of helpers present, as a range when it
    /// changed during the phase.
    static func usageRows(_ means: UsageMeans) -> [String] {
        let counts = means.helperCounts
        let helpers = counts.lowerBound == counts.upperBound
            ? "\(counts.lowerBound)" : "\(counts.lowerBound)–\(counts.upperBound)"
        return [
            usageRow("main", means.main),
            usageRow("helpers (\(helpers))", means.helpers),
            usageRow("total", means.total),
        ]
    }

    /// "  helpers (4)      3.1 %CPU        610.2 MB"
    static func usageRow(_ label: String, _ usage: ProcessUsage, signed: Bool = false) -> String {
        let padded = label + String(repeating: " ", count: max(1, 14 - label.count))
        let format = signed ? "%+6.1f %%CPU %+12.1f MB" : "%6.1f %%CPU %12.1f MB"
        return "  " + padded + String(format: format, usage.cpuPercent, usage.residentKilobytes / 1024)
    }

    /// Which helper is which: each helper of the phase's last sample, once,
    /// by pid, with its command's last path component (`?` when it had exited
    /// before the names were read) and that sample's %CPU and RSS.
    static func helperRows(_ phase: UsagePhase) -> [String] {
        guard let last = phase.samples.last, !last.helpers.isEmpty else { return [] }
        var lines = ["  helpers in the last sample:"]
        for (pid, usage) in last.helpers.sorted(by: { $0.key < $1.key }) {
            let name = phase.helperNames[pid].map { ($0 as NSString).lastPathComponent } ?? "?"
            let padded = name + String(repeating: " ", count: max(1, 34 - name.count))
            lines.append("    " + String(format: "%6d", pid) + "  " + padded
                + String(format: "%6.1f %%CPU %12.1f MB", usage.cpuPercent, usage.residentKilobytes / 1024))
        }
        return lines
    }

    /// One sample at `origin` + each offset (whole seconds), on absolute
    /// deadlines so a slow one doesn't push the rest. A sample whose calls
    /// failed, or that no longer found the app, is left out. Right after the
    /// last sample, one `ps -o pid=,comm=` names its helpers. Never touches
    /// the main actor: it runs beside the polls.
    static func sampleUsage(pid: Int32, atSeconds offsets: [Int], from origin: ContinuousClock.Instant) async -> UsagePhase {
        let runner = FoundationProcessRunner()
        var phase = UsagePhase()
        for offset in offsets {
            try? await Task.sleep(until: origin.advanced(by: .seconds(offset)), clock: .continuous)
            if let sample = await readUsage(pid: pid, runner: runner) {
                phase.samples.append(sample)
            }
        }
        if let last = phase.samples.last, !last.helpers.isEmpty {
            let pids = last.helpers.keys.sorted().map { String($0) }.joined(separator: ",")
            if let names = try? await run(runner, "/bin/ps", ["-o", "pid=,comm=", "-p", pids]) {
                phase.helperNames = parseCommandNames(names.stdoutText)
            }
        }
        return phase
    }

    /// The app's direct children (`pgrep -P`), then one `ps` for the app and
    /// all of them.
    private static func readUsage(pid: Int32, runner: FoundationProcessRunner) async -> UsageSample? {
        guard let children = try? await run(runner, "/usr/bin/pgrep", ["-P", String(pid)]),
              children.status == 0 || children.status == 1          // 1: no children
        else { return nil }
        let childPids = parsePids(children.stdoutText)
        let pids = ([pid] + childPids).map { String($0) }.joined(separator: ",")
        // No status check: `ps` still prints the rows it found when a child
        // exited after `pgrep` listed it (and exits 1 only when it found none).
        guard let table = try? await run(runner, "/bin/ps", ["-o", "pid=,%cpu=,rss=", "-p", pids]) else {
            return nil
        }
        return usageSample(pid: pid, children: childPids, rows: parseProcessRows(table.stdoutText))
    }

    private static func run(_ runner: FoundationProcessRunner, _ path: String,
                            _ arguments: [String]) async throws -> ProcessResult {
        try await runner.run(
            executable: URL(fileURLWithPath: path),
            arguments: arguments,
            stdin: nil,
            environment: ["LC_ALL": "C"],   // a "." decimal point whatever the user's locale
            timeout: 2
        )
    }
}

// MARK: - The run

/// One probe run. Main-actor bound: the AX calls are synchronous (each capped
/// by its element's timeout) and the signal handlers run on the main queue, so
/// a Ctrl-C lands between two AX calls — never between the wake's write and
/// the note that it must be set back.
@MainActor
final class FocusProbeSession {
    private struct Target {
        let pid: pid_t
        let bundleId: String?
        let name: String
    }

    /// The wake flag this run may have turned on.
    private struct PendingRestore {
        let element: AXUIElement
        let attribute: String
        let appName: String
    }

    private let options: FocusProbe.Options
    private var signalSources: [any DispatchSourceSignal] = []
    /// nil = nothing to set back.
    private var pendingRestore: PendingRestore?

    init(options: FocusProbe.Options) {
        self.options = options
    }

    func run() async {
        // 1. Trust: checked, never prompted for.
        guard AXIsProcessTrusted() else {
            FileHandle.standardError.write(Data((FocusProbe.untrustedMessage + "\n").utf8))
            exit(1)
        }
        installSignalHandlers()

        // 2. Target.
        emit("Focus the field to test — reading in \(FocusProbe.seconds(options.delay)) s…")
        try? await Task.sleep(for: .seconds(options.delay))
        guard let app = NSWorkspace.shared.frontmostApplication else {
            FileHandle.standardError.write(Data("dictate: no app is in front — nothing to read\n".utf8))
            exit(1)
        }
        let target = Target(pid: app.processIdentifier, bundleId: app.bundleIdentifier,
                            name: app.localizedName ?? "?")
        // Creating the element and setting its timeout send no message.
        let appElement = AXUIElementCreateApplication(target.pid)
        _ = AXUIElementSetMessagingTimeout(appElement, FocusProbe.elementTimeout)
        emit("target    : \(target.name) — \(target.bundleId ?? "no bundle id"), pid \(target.pid)")

        // 5. CPU and memory before the wake: no AX message has been sent yet.
        let pid = target.pid
        var usageBefore = FocusProbe.UsagePhase()
        if options.cpu {
            emit("cpu       : sampling \(target.name) and its direct children once a second for \(FocusProbe.usageSecondsBefore) s before the wake — keep the field focused…")
            let origin = ContinuousClock.now
            usageBefore = await FocusProbe.sampleUsage(
                pid: pid, atSeconds: Array(0..<FocusProbe.usageSecondsBefore), from: origin)
            try? await Task.sleep(until: origin.advanced(by: .seconds(FocusProbe.usageSecondsBefore)), clock: .continuous)
        }

        // 3. Wake.
        let wakeStarted = ContinuousClock.now
        wake(appElement, appName: target.name)

        // 5. …and until 30 s after it, beside the polls.
        let usageAfter: Task<FocusProbe.UsagePhase, Never>? = options.cpu
            ? Task.detached {
                await FocusProbe.sampleUsage(
                    pid: pid, atSeconds: Array(1...FocusProbe.usageSecondsAfter), from: wakeStarted)
            }
            : nil

        // 4. Polls, the first right after the wake.
        emit("polls     : \(options.polls) every \(FocusProbe.seconds(options.interval)) s from the wake · lengths in UTF-16 units · window = got/asked · ms per AX message")
        emit("err codes : \(FocusProbe.errorLegend)")
        for index in 1...options.polls {
            let due = wakeStarted.advanced(by: .seconds(options.interval * Double(index - 1)))
            try? await Task.sleep(until: due, clock: .continuous)
            let record = poll(index, app: appElement, target: target, wakeStarted: wakeStarted)
            emit(FocusProbe.line(record, pollCount: options.polls))
            if options.showText {
                emit(FocusProbe.textLine(record))
            }
        }

        if let usageAfter {
            emit("cpu       : sampling until \(FocusProbe.usageSecondsAfter) s after the wake…")
            let phase = await usageAfter.value
            FocusProbe.usageSummary(before: usageBefore, after: phase).forEach(emit)
        }
        restoreWake()
    }

    // MARK: Wake

    /// Step 3. `none` sends nothing and `role` only reads; `manual` and
    /// `enhanced` read their flag, then write it (the probe's one write) and
    /// note that it must be set back — unless the read couldn't say whether it
    /// was off: a write then might leave the app changed with nothing to undo it.
    private func wake(_ app: AXUIElement, appName: String) {
        switch options.wake {
        case .none:
            emit("wake      : none")
        case .role:
            let appRole = ProbeAX.copy(app, "AXRole")
            var parts = ["app AXRole=\(appRole.string ?? "-") \(appRole.summary)"]
            let focus = ProbeAX.copy(app, "AXFocusedUIElement")
            parts.append("AXFocusedUIElement \(focus.summary)")
            if let focused = focus.element {
                _ = AXUIElementSetMessagingTimeout(focused, FocusProbe.elementTimeout)
                let role = ProbeAX.copy(focused, "AXRole")
                parts.append("focused AXRole=\(role.string ?? "-") \(role.summary)")
            }
            emit("wake      : role — " + parts.joined(separator: "; "))
        case .manual, .enhanced:
            guard let attribute = options.wake.attribute else { return }
            let read = ProbeAX.copy(app, attribute)
            // Off or absent is known only from a boolean or from -25205/-25212.
            let wasOn: Bool
            let found: String
            if read.error == .success, let number = read.value as? NSNumber {
                wasOn = number.boolValue
                found = number.boolValue ? "true" : "false"
            } else if ProbeAX.absentErrors.contains(read.error) {
                wasOn = false
                found = "absent"
            } else {
                let reason = read.error == .success ? "not a boolean" : "\(read.error.rawValue)"
                emit("wake      : \(options.wake.rawValue) — \(attribute) unreadable (\(reason)) — not set (read \(read.time))")
                return
            }
            let set = ProbeAX.set(app, attribute, kCFBooleanTrue)
            // A set that timed out may still have landed: it is set back too.
            let mayHaveLanded = set.error == .success || set.error == .cannotComplete
            if !wasOn && mayHaveLanded {
                pendingRestore = PendingRestore(element: app, attribute: attribute, appName: appName)
            }
            let verb: String
            switch set.error {
            case .success: verb = "set to true"
            case .cannotComplete: verb = "set to true timed out"
            default: verb = "set to true FAILED"
            }
            let outcome: String
            if wasOn {
                outcome = "it was on already, so it is left on"
            } else if mayHaveLanded {
                outcome = "it will be set back to false on exit"
            } else {
                outcome = "nothing to set back"
            }
            emit("wake      : \(options.wake.rawValue) — \(attribute) was \(found) \(read.summary); \(verb) \(set.summary) — \(outcome)")
        }
    }

    /// Sets the wake flag back to false when this run may have turned it on:
    /// 2 s on the app element, and once more after a timeout. Runs once: at
    /// the end of a run, or from a signal handler.
    private func restoreWake() {
        guard let pending = pendingRestore else {
            if let attribute = options.wake.attribute {
                emit("restore   : nothing to set back — \(attribute) left as found")
            }
            return
        }
        pendingRestore = nil
        _ = AXUIElementSetMessagingTimeout(pending.element, FocusProbe.restoreTimeout)
        var reply = ProbeAX.set(pending.element, pending.attribute, kCFBooleanFalse)
        var tries = 1
        if reply.error == .cannotComplete {
            reply = ProbeAX.set(pending.element, pending.attribute, kCFBooleanFalse)
            tries = 2
        }
        switch reply.error {
        case .success:
            let second = tries == 2 ? ", on the second try" : ""
            emit("restore   : \(pending.attribute) set back to false (\(reply.time)\(second))")
        case .cannotComplete:
            emit("restore   : \(pending.attribute): restore timed out — the write usually lands anyway; if in doubt, quit and reopen \(pending.appName) (\(tries) tries, err \(reply.error.rawValue))")
        default:
            emit("restore   : \(pending.attribute) set back to false FAILED \(reply.summary) — if in doubt, quit and reopen \(pending.appName)")
        }
    }

    /// Ctrl-C, Ctrl-\, SIGTERM and SIGHUP must not skip the restore: their
    /// default action is ignored, and a dispatch source on the main queue
    /// sets the flag back, then exits. SIGPIPE is ignored too, so output piped
    /// into a reader that quit can't end the run with the flag still set.
    private func installSignalHandlers() {
        signal(SIGPIPE, SIG_IGN)
        for number in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.interrupted(by: number)
                }
                exit(128 + number)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func interrupted(by number: Int32) {
        let name = [SIGINT: "SIGINT", SIGTERM: "SIGTERM", SIGHUP: "SIGHUP", SIGQUIT: "SIGQUIT"][number]
            ?? "signal \(number)"
        emit("")
        emit("interrupted (\(name))")
        restoreWake()
    }

    // MARK: Poll

    /// Step 4: the focused element, read the way the reader will read it.
    private func poll(_ index: Int, app: AXUIElement, target: Target,
                      wakeStarted: ContinuousClock.Instant) -> FocusProbe.PollRecord {
        var record = FocusProbe.PollRecord(
            index: index,
            millisecondsSinceWake: FocusProbe.milliseconds(wakeStarted.duration(to: .now)),
            processIdentifier: target.pid,
            bundleId: target.bundleId
        )
        let focus = ProbeAX.copy(app, "AXFocusedUIElement")
        record.note("focus", focus, expecting: .element)
        guard let element = focus.element else { return record }
        _ = AXUIElementSetMessagingTimeout(element, FocusProbe.elementTimeout)

        // Local, no message: the process that serves the element.
        var elementPid: pid_t = 0
        if AXUIElementGetPid(element, &elementPid) == .success, elementPid != target.pid {
            record.processIdentifier = elementPid
            record.bundleId = NSRunningApplication(processIdentifier: elementPid)?.bundleIdentifier
        }

        let facts = ProbeAX.copyMultiple(element, FocusProbe.factAttributes.map(\.attribute))
        record.note("multi", facts.reply)
        for fact in FocusProbe.factAttributes {
            if let problem = facts.slots[fact.attribute]?.problem(expecting: fact.kind) {
                record.errors.append(.init(name: fact.name, problem: problem))
            }
        }
        record.role = facts.slots["AXRole"]?.string
        record.subrole = facts.slots["AXSubrole"]?.string
        record.selection = facts.slots["AXSelectedTextRange"]?.range
        record.characterCount = facts.slots["AXNumberOfCharacters"]?.integer
        record.placeholder = facts.slots["AXPlaceholderValue"]?.string

        let settable = ProbeAX.isSettable(element, "AXValue")
        record.note("settable", settable.reply)
        let ancestor = ProbeAX.copy(element, "AXEditableAncestor")
        record.note("ancestor", ancestor, expecting: .element)
        record.editability = .init(valueIsSettable: settable.isSettable, hasEditableAncestor: ancestor.element != nil)

        // Fail closed: an unknown subrole could be a password field's, so no
        // text is read unless AXSubrole answered and isn't AXSecureTextField.
        guard facts.slots["AXSubrole"]?.answersString == true else {
            record.textSkipped = .subroleUnknown
            return record
        }
        guard record.subrole != "AXSecureTextField" else {
            record.textSkipped = .secureField
            return record
        }

        let selected = ProbeAX.copy(element, "AXSelectedText")
        record.note("seltext", selected, expecting: .string)
        record.selectedText = selected.string

        guard let selection = record.selection else { return record }
        let windows = FocusProbe.windows(around: selection, characterCount: record.characterCount)
        record.beforeWindow = windows.before
        record.before = read(windows.before, of: element, as: "before", into: &record)
        record.afterWindow = windows.after
        record.after = read(windows.after, of: element, as: "after", into: &record)

        // A window read that brought no string back: would the reader's
        // AXValue fallback work here? Only its length is printed.
        let windowFailed = (windows.before.map { $0.length > 0 } == true && record.before == nil)
            || (windows.after.map { $0.length > 0 } == true && record.after == nil)
        if windowFailed {
            let value = ProbeAX.copy(element, "AXValue")
            record.note("value", value, expecting: .string)
            record.valueRead = true
            record.value = value.string
        }
        return record
    }

    /// One `AXStringForRange` window; an empty one is "" without a message.
    private func read(_ window: FocusProbe.TextRange?, of element: AXUIElement, as name: String,
                      into record: inout FocusProbe.PollRecord) -> String? {
        guard let window else { return nil }
        guard window.length > 0 else { return "" }
        let reply = ProbeAX.string(element, range: window)
        record.note(name, reply, expecting: .string)
        return reply.string
    }

    /// Unbuffered, so lines arrive as they happen through `| tee`; a write to
    /// a closed pipe fails quietly (SIGPIPE is ignored) instead of ending the run.
    private func emit(_ line: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }
}

// MARK: - AX messages

/// Every AX message the probe sends, each timed on the continuous clock. All
/// are reads except `set`: the wake flag under test, and setting it back.
enum ProbeAX {
    /// The two errors that say an attribute is absent rather than unreadable.
    static let absentErrors: Set<AXError> = [.attributeUnsupported, .noValue]

    /// What an attribute's value must be; anything else is recorded as `type`.
    enum Kind {
        case string
        case element
        case number
        /// An AXValue of `.cfRange`.
        case range

        func matches(_ value: AnyObject) -> Bool {
            switch self {
            case .string:
                return CFGetTypeID(value) == CFStringGetTypeID()
            case .element:
                return CFGetTypeID(value) == AXUIElementGetTypeID()
            case .number:
                return CFGetTypeID(value) == CFNumberGetTypeID()
            case .range:
                return CFGetTypeID(value) == AXValueGetTypeID()
                    && AXValueGetType(unsafeDowncast(value, to: AXValue.self)) == .cfRange
            }
        }
    }

    struct Reply {
        var value: CFTypeRef?
        var error: AXError
        var milliseconds: Double

        var string: String? { value as? String }

        var element: AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXUIElement.self)
        }

        /// "0.4 ms".
        var time: String { String(format: "%.1f ms", milliseconds) }

        /// "(0.4 ms)" or "(0.4 ms, err -25205)".
        var summary: String {
            error == .success ? "(\(time))" : "(\(time), err \(error.rawValue))"
        }

        /// A successful reply that is CFNull, empty, or not of `kind`.
        func oddity(expecting kind: Kind) -> FocusProbe.Failure.Problem? {
            guard error == .success else { return nil }
            guard let value, CFGetTypeID(value) != CFNullGetTypeID() else { return .null }
            return kind.matches(value) ? nil : .unexpectedType
        }
    }

    /// One attribute's place in an `AXUIElementCopyMultipleAttributeValues` answer.
    enum Slot {
        case value(AnyObject)
        /// An AXValue of type `.axError` in the attribute's place.
        case failed(Int32)
        /// CFNull.
        case missing

        var string: String? {
            guard case .value(let object) = self else { return nil }
            return object as? String
        }

        /// A definite answer for a string attribute: a string, or one of the
        /// documented "none" replies — -25205, -25212, or the CFNull the API
        /// puts in an unsupported attribute's place. Any other error, or a
        /// value of another type, answers nothing.
        var answersString: Bool {
            switch self {
            case .value(let object):
                return Kind.string.matches(object)
            case .failed(let code):
                return absentErrors.contains { $0.rawValue == code }
            case .missing:
                return true
            }
        }

        func problem(expecting kind: Kind) -> FocusProbe.Failure.Problem? {
            switch self {
            case .value(let object): return kind.matches(object) ? nil : .unexpectedType
            case .failed(let code): return .error(code)
            case .missing: return .null
            }
        }

        var integer: Int? {
            guard case .value(let object) = self else { return nil }
            return (object as? NSNumber)?.intValue
        }

        var range: FocusProbe.TextRange? {
            guard case .value(let object) = self, CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
            let value = unsafeDowncast(object, to: AXValue.self)
            var range = CFRange()
            guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range) else { return nil }
            return FocusProbe.TextRange(location: range.location, length: range.length)
        }
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> Reply {
        var value: CFTypeRef?
        let (error, milliseconds) = timed { AXUIElementCopyAttributeValue(element, attribute as CFString, &value) }
        return Reply(value: error == .success ? value : nil, error: error, milliseconds: milliseconds)
    }

    /// Options 0, not `.stopOnError`: an attribute the element lacks comes back
    /// as an error value in its place and the others still arrive.
    static func copyMultiple(_ element: AXUIElement, _ attributes: [String]) -> (slots: [String: Slot], reply: Reply) {
        var values: CFArray?
        let (error, milliseconds) = timed {
            AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &values)
        }
        var slots: [String: Slot] = [:]
        if error == .success, let objects = values as? [AnyObject] {
            for (attribute, object) in zip(attributes, objects) {
                slots[attribute] = slot(object)
            }
        }
        return (slots, Reply(value: nil, error: error, milliseconds: milliseconds))
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> (isSettable: Bool, reply: Reply) {
        var settable = DarwinBoolean(false)
        let (error, milliseconds) = timed { AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) }
        return (error == .success && settable.boolValue, Reply(value: nil, error: error, milliseconds: milliseconds))
    }

    /// `AXStringForRange` with an `AXValue` of `.cfRange`.
    static func string(_ element: AXUIElement, range: FocusProbe.TextRange) -> Reply {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            return Reply(value: nil, error: .illegalArgument, milliseconds: 0)
        }
        var value: CFTypeRef?
        let (error, milliseconds) = timed {
            AXUIElementCopyParameterizedAttributeValue(element, "AXStringForRange" as CFString, parameter, &value)
        }
        return Reply(value: error == .success ? value : nil, error: error, milliseconds: milliseconds)
    }

    /// The probe's only write.
    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFBoolean) -> Reply {
        let (error, milliseconds) = timed { AXUIElementSetAttributeValue(element, attribute as CFString, value) }
        return Reply(value: nil, error: error, milliseconds: milliseconds)
    }

    private static func slot(_ object: AnyObject) -> Slot {
        if CFGetTypeID(object) == CFNullGetTypeID() {
            return .missing
        }
        if CFGetTypeID(object) == AXValueGetTypeID() {
            let value = unsafeDowncast(object, to: AXValue.self)
            var code: Int32 = 0
            if AXValueGetType(value) == .axError, AXValueGetValue(value, .axError, &code) {
                return .failed(code)
            }
        }
        return .value(object)
    }

    private static func timed<T>(_ body: () -> T) -> (T, Double) {
        let clock = ContinuousClock()
        let start = clock.now
        let result = body()
        return (result, FocusProbe.milliseconds(start.duration(to: clock.now)))
    }
}

extension FocusProbe.PollRecord {
    /// One message: its time, its AXError unless it succeeded, and — given
    /// the kind its value must be — a CFNull or unexpected type as `null`/`type`.
    fileprivate mutating func note(_ name: String, _ reply: ProbeAX.Reply, expecting kind: ProbeAX.Kind? = nil) {
        timings.append(.init(name: name, milliseconds: reply.milliseconds))
        if reply.error != .success {
            errors.append(.init(name: name, problem: .error(reply.error.rawValue)))
        } else if let kind, let problem = reply.oddity(expecting: kind) {
            errors.append(.init(name: name, problem: problem))
        }
    }
}
