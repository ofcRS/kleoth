import Foundation
import SwiftUI
import KleothCore
import KleothCapture

/// A lightweight view-model describing a recently processed meeting,
/// surfaced in the menu bar UI.
public struct RecentMeeting: Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var date: String
    public var directory: URL

    public init(id: UUID = UUID(), title: String, date: String, directory: URL) {
        self.id = id
        self.title = title
        self.date = date
        self.directory = directory
    }
}

/// Owns the `Recorder` and the meeting pipeline, exposing observable
/// recording state to the SwiftUI menu-bar interface.
@MainActor
public final class RecordingController: ObservableObject {
    @Published public var isRecording: Bool = false
    @Published public var status: String = "Idle"
    @Published public var recentMeetings: [RecentMeeting] = []
    @Published public var currentCostUSD: Double = 0

    private var recorder: Recorder?

    public init() {}

    /// Begins a new recording session.
    public func start() async {
        fatalError("unimplemented")
    }

    /// Stops the current session and runs the processing pipeline.
    public func stop() async {
        fatalError("unimplemented")
    }
}
