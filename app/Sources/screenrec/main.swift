import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import KleothCapture
import KleothCore

/// Headless screen-recording probe (design §3.4) — the MB/min, A/V-sync and
/// mixer harness, the way `dictate` is the dictation pipeline's.
///
///     screenrec <seconds> [--display N] [--region x,y,w,h] [--no-mic]
///               [--out file] [--inspect file]
///
/// It prints the permission state, the resolved pixel size + bit rate, frames
/// appended / dropped, audio blocks, mic gaps, duration (AVURLAsset), file size
/// and MB/min. It is NOT the TCC spike: a binary exec'd from a shell is
/// TCC-attributed to the shell (the responsible process), wherever it lives —
/// the spike is the release app's own popover row (§8 #0).
///
/// `--region` is display-local, **top-left-origin points** — the same
/// convention `SCStreamConfiguration.sourceRect` uses (SCStream.h:269), so a
/// number printed here can be pasted straight back in.
@main
struct ScreenRecMain {
    @MainActor
    static func main() async {
        let arguments = Arguments(CommandLine.arguments.dropFirst())

        if let inspect = arguments.inspect {
            await Inspector.print(url: URL(fileURLWithPath: inspect))
            return
        }
        if arguments.showsHelp {
            print(Arguments.usage)
            return
        }

        // 1. Permission. A shell-launched binary inherits the terminal's grant;
        //    this line says which state we are actually in, nothing more.
        let permission = ScreenRecordingPermission.state(defaults: .standard)
        print("permission : \(label(for: permission))")
        if permission != .granted {
            print("             (Terminal itself needs Screen Recording — System Settings ›")
            print("              Privacy & Security › Screen Recording. This is NOT the §8 #0 spike.)")
        }

        // 2. Display.
        guard let display = resolveDisplay(index: arguments.display) else {
            fail("no active display")
        }
        let scale = pointPixelScale(of: display.id)
        print("display    : #\(display.index) id \(display.id) · \(display.points.width)×\(display.points.height) pt · scale \(format(scale, digits: 1))")

        let sourcePoints: CGSize
        if let region = arguments.region {
            print("region     : \(format(region.minX)),\(format(region.minY)) \(format(region.width))×\(format(region.height)) pt (display-local, top-left)")
            sourcePoints = region.size
        } else {
            print("region     : whole display")
            sourcePoints = display.points
        }
        let predicted = CaptureGeometry.outputPixelSize(
            sourcePoints: sourcePoints,
            pointPixelScale: scale,
            maxLongEdge: ScreenRecordingDefaults.maxLongEdgePixels
        )
        print("predicted  : \(Int(predicted.width))×\(Int(predicted.height)) px · \(CaptureGeometry.videoBitRate(pixelSize: predicted)) bps average")

        // 3. Microphone.
        var wantsMicrophone = arguments.microphone
        if wantsMicrophone {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status != .authorized {
                print("microphone : not authorized for this process (\(status.rawValue)) — recording system audio only")
                wantsMicrophone = false
            } else {
                print("microphone : on")
            }
        } else {
            print("microphone : off (--no-mic)")
        }

        let outputURL = arguments.outputURL
        print("output     : \(outputURL.path)")

        let configuration = ScreenRecordingConfiguration(
            target: ScreenRecordingTarget(displayID: display.id, sourceRect: arguments.region),
            outputURL: outputURL,
            captureMicrophone: wantsMicrophone
        )
        let recorder = ScreenRecorder(configuration: configuration)

        // 4. Events, printed as they happen.
        let events = recorder.events
        let eventTask = Task { @MainActor in
            for await event in events { print("event      : \(describe(event))") }
        }

        // 5. Run.
        let started = Date()
        do {
            try await recorder.start()
        } catch {
            eventTask.cancel()
            fail("start failed: \(describe(error))")
        }
        let clock = ContinuousClock()
        let live = recorder.stats
        // The movie's zero is the first frame's PTS, and ScreenCaptureKit hands
        // that frame over with a timestamp that is already in the past
        // (~0.2 s here). Anchoring on `now` would therefore record ~0.2 s more
        // movie than asked for; anchoring on the origin makes "10 s" mean 10 s
        // of file.
        let alreadyRecorded = live.sessionOriginHostTime > 0
            ? HostClockMath().seconds(fromHostTime: live.sessionOriginHostTime, to: mach_absolute_time())
            : 0
        let recordingStarted = clock.now.advanced(by: .seconds(-alreadyRecorded))
        let peak = Int(Double(live.videoBitRate) * ScreenRecordingDefaults.peakBitRateMultiplier)
        print("pixels     : \(Int(live.pixelSize.width))×\(Int(live.pixelSize.height)) · \(live.videoBitRate) bps average / \(peak) peak")
        print("first frame: \(format(Date().timeIntervalSince(started))) s after start")
        print("recording \(format(arguments.seconds)) s …")

        // Absolute deadlines, not ten one-second sleeps: the per-second stats
        // read is a `sync` onto two queues, and that drift lands straight in
        // the recorded duration.
        var previous = live
        for second in 1...max(1, Int(arguments.seconds.rounded(.up))) {
            let elapsed = min(Double(second), arguments.seconds)
            // `sleep(until:tolerance:)` on the continuous clock: the
            // nanosecond form coalesces and overshot by ~0.2 s at the tail,
            // which lands directly in the recorded duration.
            try? await Task.sleep(
                until: recordingStarted.advanced(by: .seconds(elapsed)),
                tolerance: .milliseconds(2),
                clock: clock
            )
            let now = recorder.stats
            let micFrames = now.micTotalFrames - previous.micTotalFrames
            let micReal = now.micRealFrames - previous.micRealFrames
            let micText = micFrames > 0 ? "\(Int((Double(micReal) / Double(micFrames)) * 100))%" : "—"
            print(String(
                format: "  %2ds      : video %d appended / %d dropped · audio %d blocks · mic real %@",
                second,
                now.videoAppended - previous.videoAppended,
                now.videoDropped - previous.videoDropped,
                now.audioBlocks - previous.audioBlocks,
                micText
            ))
            previous = now
        }

        // 6. Stop + report.
        let summary: ScreenRecordingSummary
        do {
            summary = try await recorder.stop(reason: .user)
        } catch {
            eventTask.cancel()
            fail("stop failed: \(describe(error))")
        }
        eventTask.cancel()

        let final = recorder.stats
        let wall = Date().timeIntervalSince(started)
        print("")
        print("stopped    : \(summary.stopReason)")
        print("file       : \(summary.url.path)")
        print("duration   : \(format(summary.duration)) s (AVURLAsset) · \(format(wall)) s wall clock")
        print("video      : \(summary.videoFramesAppended) frames appended, \(summary.droppedFrames) dropped")
        print("audio      : \(final.audioBlocks) blocks appended, \(final.audioDropped) dropped")
        let micPercent = final.micTotalFrames > 0
            ? "\(Int((Double(final.micRealFrames) / Double(final.micTotalFrames)) * 100))% real frames"
            : "no mic"
        print("mic        : \(summary.micCaptured ? micPercent : "nothing captured")")
        if summary.micGaps.isEmpty {
            print("mic gaps   : none")
        } else {
            for gap in summary.micGaps {
                print("mic gap    : \(format(gap.duration)) s at \(ElapsedFormatter.string(seconds: Int(gap.at)))")
            }
        }
        if final.micLateFrames > 0 || final.systemLateFrames > 0 {
            print("late frames: mic \(final.micLateFrames) · system \(final.systemLateFrames)")
        }
        if let failure = final.writerFailure {
            print("writer     : FAILED — \(failure)")
        }
        let megabytes = Double(summary.fileSizeBytes) / (1024 * 1024)
        let perMinute = summary.duration > 0 ? megabytes / (summary.duration / 60) : 0
        print("size       : \(summary.sizeText) (\(summary.fileSizeBytes) bytes) · \(format(perMinute, digits: 1)) MB/min")
        print("pill text  : \(summary.pillText)")
        print("")
        await Inspector.print(url: summary.url)
    }

    // MARK: - Display

    private struct Display {
        var index: Int
        var id: CGDirectDisplayID
        var points: CGSize
    }

    private static func resolveDisplay(index: Int?) -> Display? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        let wanted = index ?? 0
        guard wanted >= 0, wanted < ids.count else { return nil }
        let id = ids[wanted]
        let bounds = CGDisplayBounds(id)
        return Display(index: wanted, id: id, points: bounds.size)
    }

    /// Points → pixels for a display, from its current mode. The recorder uses
    /// `SCContentFilter.pointPixelScale`; this is the same number, available
    /// before a filter exists.
    private static func pointPixelScale(of id: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 1 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    // MARK: - Printing

    private static func label(for state: ScreenRecordingPermission.State) -> String {
        switch state {
        case .granted: return "granted"
        case .notDetermined: return "not determined"
        case .deniedOrStale: return "denied, or granted without a relaunch"
        }
    }

    private static func describe(_ event: ScreenRecorderEvent) -> String {
        switch event {
        case .firstFrame(let hostTime): return "first frame (host \(hostTime))"
        case .micStarted: return "mic started"
        case .micGapBegan(let at): return "mic gap began at \(format(at)) s"
        case .micGapEnded(let at): return "mic gap ended at \(format(at)) s"
        case .micLost(let reason): return "mic lost — \(reason)"
        case .streamStopped(let reason, let systemInitiated):
            return "stream stopped (\(systemInitiated ? "system" : "us")) — \(reason)"
        case .writerFailed(let message): return "writer failed — \(message)"
        }
    }

    private static func describe(_ error: any Error) -> String {
        guard let recorderError = error as? ScreenRecorderError else { return error.localizedDescription }
        switch recorderError {
        case .userDeclined: return "the system declined screen capture (-3801)"
        case .noDisplay: return "that display is not in the shareable-content snapshot"
        case .noFirstFrame: return "no frame arrived within \(ScreenRecordingDefaults.firstFrameTimeout ?? 0) s (stale grant?)"
        case .shareableContentTimedOut: return "SCShareableContent did not respond within 5 s"
        case .selfNotInShareableContent: return "could not find our own windows to exclude"
        case .writerSetupFailed(let message): return "writer setup failed — \(message)"
        case .writerFailed(let message): return "writer failed — \(message)"
        case .alreadyStarted: return "already started"
        case .nothingCaptured: return "nothing was captured (zero video frames)"
        case .finalizeTimedOut: return "finishWriting exceeded \(ScreenRecordingDefaults.finalizeTimeout) s"
        }
    }

    private static func format(_ value: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }

    private static func format(_ value: CGFloat, digits: Int = 0) -> String {
        String(format: "%.\(digits)f", Double(value))
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("screenrec: \(message)\n".utf8))
        exit(1)
    }
}

// MARK: - Arguments

private struct Arguments {
    static let usage = """
        screenrec <seconds> [--display N] [--region x,y,w,h] [--no-mic] [--out file] [--inspect file]

          seconds     how long to record (default 10)
          --display   index into the active display list (default 0)
          --region    display-local, TOP-left-origin points: x,y,w,h
          --no-mic    system audio only
          --out       destination; the recorder writes "<name>.recording.mp4" and renames on success
          --inspect   print bitrate, fps and track durations of an existing file, then exit
        """

    var seconds: Double = 10
    var display: Int?
    var region: CGRect?
    var microphone = true
    var inspect: String?
    var showsHelp = false
    private var out: String?

    /// The recorder is handed the IN-FLIGHT name and renames on success, so a
    /// `--out /tmp/x.mp4` really produces `/tmp/x.mp4`.
    var outputURL: URL {
        let base = out.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("screenrec.mp4")
        let name = base.deletingPathExtension().lastPathComponent
        return base
            .deletingLastPathComponent()
            .appendingPathComponent(name + ScreenRecordingDefaults.recordingSuffix)
    }

    init(_ arguments: ArraySlice<String>) {
        var iterator = Array(arguments).makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--display": display = iterator.next().flatMap { Int($0) }
            case "--region": region = Self.parseRegion(iterator.next())
            case "--no-mic": microphone = false
            case "--out": out = iterator.next()
            case "--inspect": inspect = iterator.next()
            case "-h", "--help": showsHelp = true
            default:
                if let value = Double(argument), value > 0 { seconds = value }
            }
        }
    }

    private static func parseRegion(_ text: String?) -> CGRect? {
        guard let parts = text?.split(separator: ","), parts.count == 4 else { return nil }
        let numbers = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }
}

// MARK: - Inspect

private enum Inspector {
    /// `--inspect`: what the container actually says, which is the only honest
    /// answer to "did the encoder settings take".
    static func print(url: URL) async {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Swift.print("inspect    : no file at \(url.path)")
            return
        }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else {
            Swift.print("inspect    : could not read \(url.lastPathComponent)")
            return
        }
        Swift.print("inspect    : \(url.lastPathComponent) · \(String(format: "%.2f", CMTimeGetSeconds(duration))) s")
        // `mediaType` is not an async-loadable property, so the tracks are
        // fetched per type rather than filtered after the fact.
        var pairs: [(AVMediaType, AVAssetTrack)] = []
        for mediaType in [AVMediaType.video, .audio] {
            let tracks = (try? await asset.loadTracks(withMediaType: mediaType)) ?? []
            pairs.append(contentsOf: tracks.map { (mediaType, $0) })
        }
        for (mediaType, track) in pairs {
            let range = (try? await track.load(.timeRange)) ?? .zero
            let rate = (try? await track.load(.estimatedDataRate)) ?? 0
            let fps = (try? await track.load(.nominalFrameRate)) ?? 0
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            let codec = formats.first.map { codecName($0) } ?? "?"
            var line = "  \(mediaType.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0))"
            line += " \(codec)"
            line += " · \(String(format: "%.2f", CMTimeGetSeconds(range.duration))) s"
            line += " · \(Int(rate)) bps"
            if mediaType == .video { line += " · \(String(format: "%.2f", fps)) fps nominal" }
            if mediaType == .audio, let format = formats.first {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
                if let asbd {
                    line += " · \(Int(asbd.mSampleRate)) Hz · \(asbd.mChannelsPerFrame) ch"
                }
            }
            Swift.print(line)
        }
    }

    private static func codecName(_ format: CMFormatDescription) -> String {
        let type = CMFormatDescriptionGetMediaSubType(format)
        let bytes = [
            UInt8((type >> 24) & 0xFF), UInt8((type >> 16) & 0xFF),
            UInt8((type >> 8) & 0xFF), UInt8(type & 0xFF),
        ]
        let name = String(bytes: bytes, encoding: .ascii) ?? "?"
        switch name {
        case "avc1": return "H.264 (avc1)"
        case "aac ", "mp4a": return "AAC (\(name.trimmingCharacters(in: .whitespaces)))"
        default: return name
        }
    }
}
