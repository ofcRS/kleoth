import AVFoundation
import Foundation
import KleothCapture

// Holds the microphone for N seconds (default 15) and exits. No file, no
// transcription, no network: the tap discards every buffer — a partner for
// `micwatch`.   micopen [seconds]
//
// It never asks for the microphone: a shell-launched binary is TCC-attributed
// to the TERMINAL, and on an unattended run a prompt would sit on the screen.
// Without an existing grant it exits 3 ("calibration deferred"), not a failure.
guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
    FileHandle.standardError.write(Data("micopen: this terminal has no microphone grant — not prompting\n".utf8))
    exit(3)
}

let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 15
let stamp = ISO8601DateFormatter()
stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
/// The same timestamp format as `micwatch`, so a trigger delay reads off two logs.
@MainActor func line(_ text: String) { print("\(stamp.string(from: Date())) \(text)"); fflush(stdout) }

let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.inputFormat(forBus: 0)
guard format.sampleRate > 0, format.channelCount > 0 else {
    FileHandle.standardError.write(Data("micopen: no input device\n".utf8))
    exit(2)
}
do {
    try catchingObjCExceptions {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }
    }
    engine.prepare()
    try engine.start()
} catch {
    FileHandle.standardError.write(Data("micopen: \(error)\n".utf8))
    exit(1)
}
line("micopen: pid \(ProcessInfo.processInfo.processIdentifier) holding the mic for \(seconds)s (\(format.sampleRate) Hz)")
Thread.sleep(forTimeInterval: seconds)
input.removeTap(onBus: 0)
engine.stop()
line("micopen: released")
