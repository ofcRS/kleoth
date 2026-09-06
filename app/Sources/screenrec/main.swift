import Foundation

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
/// **T0 STUB** — T3 implements it alongside `ScreenRecorder`.
FileHandle.standardError.write(Data("screenrec: not implemented (T3)\n".utf8))
exit(1)
