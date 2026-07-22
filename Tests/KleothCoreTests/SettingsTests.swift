import Testing
import Foundation
@testable import KleothCore

@Suite struct SettingsTests {
    @Test func defaultInitDisablesAutoTranscribe() {
        let settings = Settings(outputDir: URL(fileURLWithPath: "/tmp"), defaultModel: "m")
        #expect(settings.autoTranscribe == false)
    }

    @Test func loadParsesAutoTranscribeTrue() {
        let settings = Settings.load(config: ["auto_transcribe": "true"])
        #expect(settings.autoTranscribe == true)
    }

    @Test func loadDefaultsAutoTranscribeToFalseWhenAbsent() {
        let settings = Settings.load(config: [:])
        #expect(settings.autoTranscribe == false)
    }

    @Test func loadTreatsMalformedAutoTranscribeAsFalse() {
        #expect(Settings.load(config: ["auto_transcribe": "1"]).autoTranscribe == false)
        #expect(Settings.load(config: ["auto_transcribe": "yes"]).autoTranscribe == false)
        #expect(Settings.load(config: ["auto_transcribe": "TRUE"]).autoTranscribe == false)
        #expect(Settings.load(config: ["auto_transcribe": ""]).autoTranscribe == false)
    }
}
