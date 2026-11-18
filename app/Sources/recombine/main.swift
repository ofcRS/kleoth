import AppKit
import Foundation
import KleothCapture
import KleothCore

// recombine [--dry-run] <meeting-dir | folder of meetings>...
//
// Rebuilds the `meeting.m4a` of meetings combined by 0.5.7 or earlier with a
// microphone at another rate than the system lane (the other side plays at the
// wrong speed, the file can last up to three times the meeting), or one that
// cannot be read, from their own `mic.m4a` + `system.m4a`, and corrects the
// length stored in `meta.json` / `variants/*/variant.json`. The same
// `MeetingAudioRepair` the app runs at launch, but it looks at every folder
// it is given (the app's failed and finished ones too). `--dry-run` only reads.
// A file not downloaded from a cloud folder is skipped, never downloaded.
// Refuses to write while Kleoth runs.

let arguments = Array(CommandLine.arguments.dropFirst())
let dryRun = arguments.contains("--dry-run")
let paths = arguments.filter { !$0.hasPrefix("--") }
guard !paths.isEmpty, !arguments.contains("--help") else {
    print("usage: recombine [--dry-run] <meeting-dir | folder of meetings>...")
    exit(paths.isEmpty ? 1 : 0)
}

// The app writes `meta.json` (renames, summaries, transcriptions) and repairs
// these folders itself; neither is guarded against a second process.
let kleothRunning = NSWorkspace.shared.runningApplications.contains { app in
    app.bundleIdentifier == "dev.kleoth.app"
        || app.executableURL?.lastPathComponent == "Kleoth"
        || app.executableURL?.lastPathComponent == "KleothApp"
}
if kleothRunning, !dryRun {
    FileHandle.standardError.write(Data("""
        recombine: Kleoth is running. It repairs these meetings itself when it launches, and its own \
        writes to meta.json are not guarded against this tool. Quit Kleoth and run again, or use --dry-run.

        """.utf8))
    exit(3)
}

func seconds(_ value: Double?) -> String {
    value.map { String(format: "%.3f s", $0) } ?? "none"
}

func describe(_ lane: MeetingAudioLanes.Lane?) -> String {
    lane.map { "\(Int($0.sampleRate)) Hz \(seconds($0.seconds))" } ?? "no audio"
}

let fm = FileManager.default
var failures = 0

for path in paths {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    let isMeeting = fm.fileExists(atPath: url.appendingPathComponent("mic.m4a").path)
        || fm.fileExists(atPath: url.appendingPathComponent("system.m4a").path)
    let meetings: [URL]
    if isMeeting {
        meetings = [url]
    } else {
        let found = MeetingAudioRepair.scan(url, deep: true)
        meetings = found.needsRepair
        print("\(url.path): \(found.needsRepair.count) meeting(s) need repair, \(found.unavailable.count) not downloaded (skipped)")
    }

    for dir in meetings {
        if MeetingAudioRepair.triage(dir, deep: true) == .unavailable {
            print("\(dir.lastPathComponent): not downloaded from its cloud folder; skipped")
            continue
        }
        guard let inspection = MeetingAudioRepair.inspect(dir) else {
            print("\(dir.lastPathComponent): no lane holds audio; nothing to rebuild from")
            continue
        }
        let stored = inspection.storedDurationsToCorrect.map(\.lastPathComponent)
        let combined = inspection.combinedSampleRate.map { "\(Int($0)) Hz \(seconds(inspection.combinedSeconds))" }
            ?? (inspection.combinedExists ? "unreadable" : "none")
        print("\(dir.lastPathComponent): mic \(describe(inspection.lanes.mic)) | system \(describe(inspection.lanes.system))"
            + " | meeting.m4a \(combined)\(inspection.combinedMarked ? " (marked)" : "")"
            + ", expected \(seconds(inspection.lanes.expectedSeconds))"
            + " | rebuild: \(inspection.combinedNeedsRebuild ? "yes" : "no")"
            + " | stored length to correct: \(stored.isEmpty ? "none" : stored.joined(separator: ", "))")
        guard !dryRun, inspection.needsRepair else { continue }

        let started = Date()
        do {
            if let rebuild = try MeetingAudioRepair.rebuildCombinedFile(in: dir) {
                print("  rebuilt meeting.m4a: \(seconds(rebuild.before)) → \(seconds(rebuild.after))"
                    + String(format: " in %.1f s", Date().timeIntervalSince(started)))
            }
            let store = MeetingStore(baseDir: dir.deletingLastPathComponent())
            let rewritten = try store.correctStoredAudioDurations(in: dir, lanes: inspection.lanes)
            if !rewritten.isEmpty {
                print("  corrected the stored length in: \(rewritten.map(\.lastPathComponent).joined(separator: ", "))")
            }
        } catch {
            failures += 1
            print("  FAILED: \(error.localizedDescription)")
        }
    }
}
exit(failures == 0 ? 0 : 2)
