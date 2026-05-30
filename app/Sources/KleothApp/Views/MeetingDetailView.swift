import SwiftUI

/// Detail screen for a single processed meeting.
struct MeetingDetailView: View {
    let meeting: RecentMeeting

    var body: some View {
        Text(meeting.title)
            .padding()
    }
}
