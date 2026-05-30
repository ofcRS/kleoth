import Foundation
import AVFoundation
import KleothCapture

// Diagnostic harness for SystemAudioTap. Runs the tap for N seconds and reports
// what it actually captured. Play audio from ANOTHER process (e.g. `say` or
// `afplay`) while this runs — the tap excludes only this process, so that
// audio should be captured if the tap works.
//
//   taptest [outFile.m4a] [seconds]

guard #available(macOS 14.4, *) else {
    FileHandle.standardError.write(Data("needs macOS 14.4+\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
let outURL = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/taptest.m4a")
let secs = args.count > 2 ? (Double(args[2]) ?? 6) : 6

let tap = SystemAudioTap()
do {
    try tap.start(writingTo: outURL)
    FileHandle.standardError.write(Data("tap started; capturing \(secs)s -> \(outURL.path)\n".utf8))
    Thread.sleep(forTimeInterval: secs)
    tap.stop()
    let s = tap.lastStats
    print("cycles=\(s.cycles) nilBuffers=\(s.nilBuffers) frames=\(s.frames) peakSample=\(s.maxSample) writeFailed=\(tap.didEncounterWriteFailure)")
    print("format=\(String(describing: tap.resolvedFormat))")
} catch {
    print("ERROR starting tap: \(error)")
    exit(1)
}
