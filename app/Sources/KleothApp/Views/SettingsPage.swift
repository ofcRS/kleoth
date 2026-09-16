import SwiftUI

/// The Settings window's pages, in sidebar order: the product's three features
/// first, then the app's own plumbing. Each page is a plain grouped `Form`
/// under its own title — the System Settings idiom. A banner-per-page cut
/// (serif title, gradient card, 3D art) was rejected on sight the same day it
/// was built (2026-09-10): "trying to look premium instead of trying to look
/// precise". Keep this window undecorated.
enum SettingsPage: String, CaseIterable, Identifiable {
    case meetings, dictation, screenRecording, microphone, accounts, general

    var id: String { rawValue }

    /// The sidebar groups: features first, then the app.
    static let features: [SettingsPage] = [.meetings, .dictation, .screenRecording]
    static let app: [SettingsPage] = [.microphone, .accounts, .general]

    var title: String {
        switch self {
        case .meetings: "Meetings"
        case .dictation: "Dictation"
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .accounts: "Accounts"
        case .general: "General"
        }
    }

    var systemImage: String {
        switch self {
        case .meetings: "waveform"
        case .dictation: "mic.and.signal.meter"
        case .screenRecording: "record.circle"
        case .microphone: "mic.fill"
        case .accounts: "key.fill"
        case .general: "gearshape"
        }
    }
}
