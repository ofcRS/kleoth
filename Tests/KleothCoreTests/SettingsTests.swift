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

    // MARK: - Dictation keys (design §3.12 / §6.1)

    @Test func defaultInitDisablesDictationAndUsesPolishModel() {
        let settings = Settings(outputDir: URL(fileURLWithPath: "/tmp"), defaultModel: "m")
        #expect(settings.dictationEnabled == false)
        #expect(settings.dictationModel == DictationDefaults.polishModel)
    }

    @Test func loadParsesDictationEnabledStrictTrue() {
        #expect(Settings.load(config: ["dictation_enabled": "true"]).dictationEnabled == true)
        #expect(Settings.load(config: [:]).dictationEnabled == false)
        #expect(Settings.load(config: ["dictation_enabled": "1"]).dictationEnabled == false)
        #expect(Settings.load(config: ["dictation_enabled": "yes"]).dictationEnabled == false)
        #expect(Settings.load(config: ["dictation_enabled": "TRUE"]).dictationEnabled == false)
        #expect(Settings.load(config: ["dictation_enabled": ""]).dictationEnabled == false)
    }

    @Test func loadDefaultsDictationModelWhenAbsent() {
        #expect(Settings.load(config: [:]).dictationModel == DictationDefaults.polishModel)
        #expect(Settings.load(config: ["dictation_model": ""]).dictationModel == DictationDefaults.polishModel)
    }

    @Test func loadOverridesDictationModelFromConfig() {
        let settings = Settings.load(config: ["dictation_model": "deepseek/deepseek-v4-flash"])
        #expect(settings.dictationModel == "deepseek/deepseek-v4-flash")
    }

    @Test func loadParsesDictationPolishAlwaysStrictTrue() {
        #expect(Settings(outputDir: URL(fileURLWithPath: "/tmp"), defaultModel: "m").dictationPolishAlways == false)
        #expect(Settings.load(config: ["dictation_polish_always": "true"]).dictationPolishAlways == true)
        #expect(Settings.load(config: [:]).dictationPolishAlways == false)
        #expect(Settings.load(config: ["dictation_polish_always": "1"]).dictationPolishAlways == false)
        #expect(Settings.load(config: ["dictation_polish_always": "TRUE"]).dictationPolishAlways == false)
    }

    @Test func defaultModelComesFromModelCatalog() {
        #expect(Settings.load(config: [:]).defaultModel == ModelCatalog.defaultModel)
        #expect(Settings.load(config: [:]).defaultModel == "z-ai/glm-5.3-flash")
    }
}
