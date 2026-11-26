import AppKit
import Foundation
import KleothCapture
import KleothCore

// relabel [--dry-run | --out <dir>] [--verbose] <meeting-dir | folder of meetings>...
//
// Re-attributes the words of a meeting's cloud transcript to You/Them from its
// own `mic.m4a` + `system.m4a`, word by word (`ChannelAttribution`), the way a
// new transcription does since per-word attribution. No Scribe call, no cost.
// A meeting transcribed before then kept no Scribe voice clusters, so its old
// labels are the prior for the words the lanes can't decide. Never run by the app.
//
// Writes `transcript.json` atomically, keeps the first one it replaced as
// `transcript.before-relabel.json` (a re-run starts from that backup, so it
// gives the same result), and re-renders `transcript.md` and `summary.md`. The
// summary's TEXT still reflects the old labels: re-summarize to redo it.
// Skipped: a meeting without both lanes holding audio, an on-device transcript
// (each lane transcribed on its own), one whose speakers are Scribe's voices
// rather than the two lanes (a CLI transcription), and a file not downloaded
// from a cloud folder (never downloaded). A cloud transcript archived under
// `variants/` (another tier active) is not re-labelled.
// `--dry-run` only reads. `--out <dir>` leaves the meetings alone and writes
// each re-attributed `transcript.json` + `transcript.md` to `<dir>/<meeting>/`
// for a look first; it refuses a folder that is, or is inside, a meeting.
// `--verbose` adds a line per cluster (counts only).
// Refuses to write into meetings while Kleoth runs.
// Prints folder names and counts only, never words.

var arguments = Array(CommandLine.arguments.dropFirst())
var outDir: URL?
if let flag = arguments.firstIndex(of: "--out") {
    guard flag + 1 < arguments.count else {
        print("relabel: --out needs a directory")
        exit(1)
    }
    outDir = URL(fileURLWithPath: (arguments[flag + 1] as NSString).expandingTildeInPath, isDirectory: true)
    arguments.removeSubrange(flag...(flag + 1))
}
let dryRun = arguments.contains("--dry-run")
let verbose = arguments.contains("--verbose")
let paths = arguments.filter { !$0.hasPrefix("--") }
guard !paths.isEmpty, !arguments.contains("--help") else {
    print("""
        usage: relabel [--dry-run | --out <dir>] [--verbose] <meeting-dir | folder of meetings>...
          Re-attributes a meeting's cloud transcript to You/Them, word by word, from its mic.m4a and
          system.m4a; no new transcription. Keeps the replaced file as transcript.before-relabel.json.
          --dry-run   only read and report
          --out <dir> write previews to <dir>/<meeting>/ and leave the meetings alone
          --verbose   a line per cluster (counts only)
          Skips meetings without both lanes, on-device transcripts, CLI transcripts whose speakers
          are Scribe's voices, and files not downloaded. A cloud transcript archived under
          variants/ (another tier active) is not re-labelled. The summary text is not redone.
        """)
    exit(paths.isEmpty ? 1 : 0)
}

// The app writes these files (transcriptions, renames, summaries); its writes
// are not guarded against a second process.
let kleothRunning = NSWorkspace.shared.runningApplications.contains { app in
    app.bundleIdentifier == "dev.kleoth.app"
        || app.executableURL?.lastPathComponent == "Kleoth"
        || app.executableURL?.lastPathComponent == "KleothApp"
}
if kleothRunning, !dryRun, outDir == nil {
    FileHandle.standardError.write(Data("""
        relabel: Kleoth is running, and its own writes to these meetings are not guarded against this \
        tool. Quit Kleoth and run again, or use --dry-run or --out <dir>.

        """.utf8))
    exit(3)
}

let fm = FileManager.default
let hopSeconds = 0.05
var failures = 0
var totals = (meetings: 0, words: 0, youBefore: 0, youAfter: 0, changed: 0)

func percent(_ part: Int, _ whole: Int) -> String {
    whole == 0 ? "-" : String(format: "%.1f%%", 100 * Double(part) / Double(whole))
}

for path in paths {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    let isMeeting = fm.fileExists(atPath: url.appendingPathComponent("transcript.json").path)
        || fm.fileExists(atPath: url.appendingPathComponent(Recorder.micFileName).path)
    let meetings = isMeeting ? [url] : MeetingAudioRepair.meetingFolders(in: url)

    for dir in meetings {
        let name = dir.lastPathComponent
        let store = MeetingStore(baseDir: dir.deletingLastPathComponent())
        let mic = dir.appendingPathComponent(Recorder.micFileName)
        let system = dir.appendingPathComponent(Recorder.systemFileName)
        guard fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path) else {
            print("\(name): no transcript; skipped")
            continue
        }
        guard let metadata = try? store.loadMetadata(in: dir) else {
            print("\(name): no readable meta.json, so no telling how it was transcribed; skipped")
            continue
        }
        guard metadata.transcriptTier == TranscriptTier.sotaScribe else {
            print("\(name): \(TranscriptTier.label(metadata.transcriptTier ?? TranscriptTier.local)) transcript; skipped")
            continue
        }
        // Both lanes, as the app needs to attribute by lane at all.
        if let missing = [mic, system].first(where: { !fm.fileExists(atPath: $0.path) }) {
            print("\(name): no \(missing.lastPathComponent); skipped")
            continue
        }
        if [mic, system, dir.appendingPathComponent("transcript.json")].contains(where: MeetingAudioRepair.isNotDownloaded) {
            print("\(name): not downloaded from its cloud folder; skipped")
            continue
        }
        let preview = outDir?.appendingPathComponent(name, isDirectory: true)
        if let preview, let problem = TranscriptRelabel.previewProblem(preview: preview, meeting: dir) {
            failures += 1
            print("\(name): refused: \(problem) (\(preview.path))")
            continue
        }

        do {
            let (source, current, fromBackup) = try store.relabelSource(in: dir)
            let micEnergy = try ChannelAudio.envelope(of: mic, hopSeconds: hopSeconds)
            let systemEnergy = try ChannelAudio.envelope(of: system, hopSeconds: hopSeconds)
            let outcome: TranscriptRelabel.Outcome
            switch TranscriptRelabel.relabel(source, micEnergy: micEnergy, systemEnergy: systemEnergy, hopSeconds: hopSeconds) {
            case .success(let result): outcome = result
            case .failure(let refusal):
                print("\(name): \(refusal); skipped")
                continue
            }
            var notes: [String] = []
            if outcome.micHearsSystemSeconds > 0 {
                notes.append(String(format: "the mic hears the speakers over %.0f s", outcome.micHearsSystemSeconds))
            }
            if outcome.systemHearsMicSeconds > 0 {
                notes.append(String(format: "the system lane carries the mic over %.0f s", outcome.systemHearsMicSeconds))
            }
            if outcome.sharedMicClusters > 0 { notes.append("two voices at the mic, nobody on the system lane") }
            if !outcome.usedScribeClusters {
                notes.append("Scribe's voice clusters were not stored: the old You/Them labels are the prior")
            }
            if fromBackup { notes.append("from \(MeetingStore.relabelBackupName)") }
            print("\(name): \(outcome.words) words | You \(outcome.youBefore) (\(percent(outcome.youBefore, outcome.words)))"
                + " -> \(outcome.youAfter) (\(percent(outcome.youAfter, outcome.words)))"
                + " | changed \(outcome.changed)" + (notes.isEmpty ? "" : " | " + notes.joined(separator: "; ")))
            if verbose {
                for cluster in outcome.clusters {
                    print("  \(cluster.id.isEmpty ? "(none)" : cluster.id): \(cluster.words) words, clearly mic \(cluster.clearMic),"
                        + " clearly system \(cluster.clearSystem), You now \(cluster.you)")
                }
            }
            totals.meetings += 1
            totals.words += outcome.words
            totals.youBefore += outcome.youBefore
            totals.youAfter += outcome.youAfter
            totals.changed += outcome.changed

            guard !dryRun else { continue }
            if let preview {
                // A preview: the meeting folder is only read.
                try fm.createDirectory(at: preview, withIntermediateDirectories: true)
                try Data().write(to: preview.appendingPathComponent(TranscriptRelabel.previewMarkerName))
                try MeetingStore.encodeRawTranscript(outcome.response)
                    .write(to: preview.appendingPathComponent("transcript.json"), options: .atomic)
                var transcript = TranscriptNormalizer.normalize(outcome.response, tier: metadata.transcriptTier)
                if let map = store.loadSpeakerMap(in: dir) { transcript = SpeakerMapper.apply(map, to: transcript) }
                try Data(MeetingStore.transcriptLines(transcript).utf8)
                    .write(to: preview.appendingPathComponent("transcript.md"), options: .atomic)
                continue
            }
            let currentWords = current.words ?? [], newWords = outcome.response.words ?? []
            let unchanged = zip(currentWords, newWords).allSatisfy { $0.speakerId == $1.speakerId }
            if unchanged {
                print("  already labelled so; nothing written")
                continue
            }
            try store.replaceRawTranscript(in: dir, with: outcome.response)
            print("  wrote transcript.json, transcript.md\(fm.fileExists(atPath: dir.appendingPathComponent("summary.json").path) ? ", summary.md (the summary text is unchanged: re-summarize to redo it)" : "")")
        } catch {
            failures += 1
            print("\(name): FAILED: \(error.localizedDescription)")
        }
    }
}
if totals.meetings > 1 {
    print("all: \(totals.meetings) meetings, \(totals.words) words | You \(totals.youBefore) -> \(totals.youAfter) | changed \(totals.changed)")
}
exit(failures == 0 ? 0 : 2)
