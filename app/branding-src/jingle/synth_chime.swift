#!/usr/bin/env swift
//
// synth_chime.swift — Plan B (offline) Kleoth welcome chime generator.
//
// Plan A (ElevenLabs Sound Effects API) was unavailable: the account's key is
// scoped and the POST /v1/sound-generation endpoint 401s with
// `missing_permissions` (sound_generation scope not granted). Per the task
// brief, we fall back to synthesizing a harp-like plucked-string arpeggio
// locally with Karplus-Strong synthesis.
//
// Brand: Kleoth — Greek lyre, "kleos = that which is heard". A short, warm,
// ascending 4-note flourish (D-major-ish: D4 F#4 A4 D5) evokes a kithara/harp
// without sampling anything. Pure AVFoundation + Accelerate, no deps.
//
// Output: WelcomeChime.wav (44.1 kHz, mono, Float32), peak-normalized to -3 dBFS.
// Run:  swift synth_chime.swift [out.wav]
//
import AVFoundation
import Accelerate

let sampleRate = 44_100.0
let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "WelcomeChime.wav"

// --- Note layout ----------------------------------------------------------
// Ascending D-major arpeggio: D4, F#4, A4, D5. Equal-tempered (A4 = 440 Hz).
func midiToHz(_ m: Double) -> Double { 440.0 * pow(2.0, (m - 69.0) / 12.0) }
let notes = [62.0, 66.0, 69.0, 74.0].map(midiToHz)   // D4 F#4 A4 D5

let onsetGap = 0.18      // seconds between successive plucks (a flowing arpeggio)
let ring     = 1.25      // seconds each note rings out
let lastTail = 0.55      // a touch extra so the top note's tail fully blooms

// Total length: last onset + its ring + a little tail headroom.
let lastOnset = onsetGap * Double(notes.count - 1)
let totalSeconds = lastOnset + ring + lastTail
let totalFrames = Int(totalSeconds * sampleRate)

var mix = [Float](repeating: 0, count: totalFrames)

// --- Karplus-Strong plucked string ---------------------------------------
// Excite a delay line (length = SR / freq) with noise, then low-pass-feedback
// it. A small per-step energy-loss factor sets the decay/brightness. We layer
// an exponential amplitude envelope on top so each note blooms then fades.
func pluck(into buffer: inout [Float], freq: Double, startFrame: Int,
           ringSeconds: Double, gain: Float, decay: Float, brightness: Float) {
    let n = Int(sampleRate / freq)
    guard n > 1 else { return }

    // Seeded, deterministic noise burst (reproducible builds) via a small LCG.
    var seed: UInt64 = UInt64(bitPattern: Int64(startFrame &* 2654435761 &+ Int(freq)))
    func nextNoise() -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let v = Double(seed >> 33) / Double(UInt64(1) << 31)   // 0..2
        return Float(v - 1.0)                                  // -1..1
    }

    var delay = [Float](repeating: 0, count: n)
    for i in 0..<n { delay[i] = nextNoise() }

    let ringFrames = Int(ringSeconds * sampleRate)
    var prev: Float = 0
    var idx = 0
    // Exponential amplitude envelope time-constant (seconds). Longer = slower fade.
    let tau = Float(ringSeconds * 0.42)
    let dtau = expf(-1.0 / (tau * Float(sampleRate)))
    var env: Float = 1.0
    // Soft attack so the very first samples don't click.
    let attackFrames = Int(0.004 * sampleRate)

    for k in 0..<ringFrames {
        let f = startFrame + k
        if f >= buffer.count { break }

        let cur = delay[idx]
        // One-pole low-pass on the feedback path: brightness in 0.5..0.5+ blends
        // current & previous; decay (<1) bleeds energy so the string dies out.
        let filtered = decay * (brightness * cur + (1.0 - brightness) * prev)
        prev = cur
        delay[idx] = filtered
        idx = (idx + 1) % n

        var amp = env
        if k < attackFrames { amp *= Float(k) / Float(attackFrames) }
        buffer[f] += cur * gain * amp

        env *= dtau
    }
}

// Layer the notes. Slightly drop per-note gain as we ascend so the bright top
// note doesn't dominate, and give earlier notes marginally longer rings.
for (i, hz) in notes.enumerated() {
    let start = Int(Double(i) * onsetGap * sampleRate)
    let gain: Float = 0.95 - Float(i) * 0.06
    let bright: Float = 0.50 + Float(i) * 0.012   // higher notes a hair brighter
    pluck(into: &mix, freq: hz, startFrame: start,
          ringSeconds: ring, gain: gain, decay: 0.996, brightness: bright)
}

// --- Master: gentle global fade-out tail, then peak-normalize to -3 dBFS ---
let fadeStart = Int((totalSeconds - 0.45) * sampleRate)
for f in max(0, fadeStart)..<totalFrames {
    let t = Float(f - fadeStart) / Float(totalFrames - fadeStart)
    mix[f] *= (1.0 - t * t)   // smooth quadratic fade
}

// Peak normalize to -3 dBFS (0.708).
var peak: Float = 0
vDSP_maxmgv(mix, 1, &peak, vDSP_Length(mix.count))
if peak > 0 {
    let target: Float = 0.708
    var scale = target / peak
    vDSP_vsmul(mix, 1, &scale, &mix, 1, vDSP_Length(mix.count))
}

// --- Write 44.1 kHz mono Float32 WAV via AVAudioFile ----------------------
guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                 sampleRate: sampleRate,
                                 channels: 1,
                                 interleaved: false) else {
    fatalError("could not make AVAudioFormat")
}
let url = URL(fileURLWithPath: outPath)
// Remove any stale file first so AVAudioFile writes a fresh, correctly-sized header.
try? FileManager.default.removeItem(at: url)
let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsNonInterleaved: true,
]

// IMPORTANT: AVAudioFile finalizes the RIFF/data chunk sizes in its header only
// when the object is deallocated (closed). A Swift script keeps a top-level
// `let file` alive until process exit, where the flush is unreliable — that
// produced a 0-duration WAV. Confine the file to a scope so it deallocs (and
// flushes) before we hand off.
func writeWav() throws {
    let file = try AVAudioFile(forWriting: url, settings: settings,
                              commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                    frameCapacity: AVAudioFrameCount(totalFrames)) else {
        fatalError("could not make PCM buffer")
    }
    pcm.frameLength = AVAudioFrameCount(totalFrames)
    mix.withUnsafeBufferPointer { src in
        pcm.floatChannelData![0].update(from: src.baseAddress!, count: totalFrames)
    }
    try file.write(from: pcm)
}
try writeWav()   // `file` is released here -> header finalized

print("wrote \(outPath): \(totalFrames) frames, \(String(format: "%.3f", totalSeconds))s, peak->-3dBFS")
