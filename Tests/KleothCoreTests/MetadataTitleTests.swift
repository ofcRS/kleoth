import Testing
@testable import KleothCore

/// Covers fix #2's title policy: a model-generated title replaces only
/// auto-generated placeholder names; real calendar/user titles are preserved.
@Suite struct MetadataTitleTests {
    @Test func placeholdersAreDetected() {
        #expect(MeetingMetadata.isPlaceholderTitle(""))
        #expect(MeetingMetadata.isPlaceholderTitle("   "))
        #expect(MeetingMetadata.isPlaceholderTitle("Meeting 2026-06-01"))
        #expect(MeetingMetadata.isPlaceholderTitle("Recording 2026-05-31"))
        #expect(MeetingMetadata.isPlaceholderTitle("Recording · Jun 1, 14:30"))
    }

    @Test func realTitlesArePreserved() {
        // These start with "Meeting"/"Recording" but are NOT date placeholders.
        #expect(!MeetingMetadata.isPlaceholderTitle("Meeting with Acme"))
        #expect(!MeetingMetadata.isPlaceholderTitle("Meeting recap"))
        #expect(!MeetingMetadata.isPlaceholderTitle("Recording studio sync"))
        // Unrelated real titles.
        #expect(!MeetingMetadata.isPlaceholderTitle("Q3 Planning"))
        #expect(!MeetingMetadata.isPlaceholderTitle("Standup"))
    }
}
