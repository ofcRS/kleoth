import Testing
@testable import KleothCore

/// The four `cover_*` keys (design doc 2026-09-24 §4.5) and the per-engine
/// constants every later cover task builds on.
@Suite struct CoverSettingsTests {
    @Test func defaultsAreOffAutomaticAndAutoStyle() {
        let settings = CoverSettings.load(config: [:])
        #expect(settings.engine == nil)
        #expect(settings.automatic == true)
        #expect(settings.style == nil)
        #expect(settings.models.isEmpty)
        #expect(Settings.load(config: [:]).coverSettings == CoverSettings())
    }

    @Test func engineValuesParse() {
        func engine(_ raw: String) -> CoverEngine? {
            CoverSettings.load(config: ["cover_engine": raw]).engine
        }
        #expect(engine("local") == .localServer)
        #expect(engine("codex") == .codex)
        #expect(engine("openrouter") == .openRouter)
        #expect(engine("off") == nil)
        #expect(engine("OPENROUTER") == .openRouter)
        #expect(engine(" codex\n") == .codex)
        #expect(engine("dall-e") == nil)
        #expect(engine("") == nil)
    }

    @Test func automaticIsOffOnlyForFalse() {
        func automatic(_ raw: String?) -> Bool {
            var config: [String: String] = [:]
            if let raw { config["cover_automatic"] = raw }
            return CoverSettings.load(config: config).automatic
        }
        #expect(automatic("false") == false)
        #expect(automatic("true") == true)
        #expect(automatic("0") == true)
        #expect(automatic("no") == true)
        #expect(automatic("") == true)
        #expect(automatic(nil) == true)
    }

    @Test func unknownStyleReadsAsAuto() {
        func style(_ raw: String) -> CoverStyle? {
            CoverSettings.load(config: ["cover_style": raw]).style
        }
        #expect(style("sketch") == .sketch)
        #expect(style("auto") == nil)
        #expect(style("3d") == nil)
        #expect(style("") == nil)
    }

    @Test func modelsParseLenientlyAndRoundTrip() {
        let stored = #"{"local":"x/flux2-klein","openrouter":"google/gemini-3.1-flash-image","dalle":"x","codex":""}"#
        let settings = CoverSettings.load(config: ["cover_models": stored])
        #expect(settings.models == [.localServer: "x/flux2-klein", .openRouter: "google/gemini-3.1-flash-image"])
        #expect(settings.modelsJSON == #"{"local":"x/flux2-klein","openrouter":"google/gemini-3.1-flash-image"}"#)
        #expect(CoverSettings.load(config: ["cover_models": settings.modelsJSON]).models == settings.models)
        // `cover_models` holds only engines that take a model (§4.5): Codex draws with its own tool.
        #expect(CoverSettings.parseModels(#"{"codex":"gpt-image-2","local":"m"}"#) == [.localServer: "m"])
        #expect(CoverSettings.parseModels("not json") == [:])
        #expect(CoverSettings.parseModels(nil) == [:])
        #expect(CoverSettings().modelsJSON == "{}")
    }

    @Test func modelForEngineDefaultsPerEngine() {
        let empty = CoverSettings()
        #expect(empty.model(for: .localServer) == "x/flux2-klein")
        #expect(empty.model(for: .codex) == "")
        #expect(empty.model(for: .openRouter) == "google/gemini-3.1-flash-lite-image")

        let custom = empty.settingModel(" my/model ", for: .openRouter)
        #expect(custom.model(for: .openRouter) == "my/model")
        #expect(custom.models == [.openRouter: "my/model"])

        let cleared = custom.settingModel("", for: .openRouter)
        #expect(cleared.models.isEmpty)
        #expect(cleared.model(for: .openRouter) == "google/gemini-3.1-flash-lite-image")
    }

    /// Typing the engine's own default (it is the field's placeholder) is not
    /// a pick: it drops the override like an empty field, so a later change
    /// of default is never shadowed by a pinned copy of the old one.
    @Test func aRetypedDefaultDropsTheOverride() {
        let custom = CoverSettings().settingModel("my/model", for: .openRouter)
            .settingModel("my/flux", for: .localServer)

        let retyped = custom.settingModel(" google/gemini-3.1-flash-lite-image\n", for: .openRouter)
        #expect(retyped.models == [.localServer: "my/flux"])
        #expect(retyped.model(for: .openRouter) == "google/gemini-3.1-flash-lite-image")
        #expect(retyped.modelsJSON == #"{"local":"my/flux"}"#)

        let local = custom.settingModel("x/flux2-klein", for: .localServer)
        #expect(local.models == [.openRouter: "my/model"])
    }

    /// A job's style pick → `CoverDrawing.Request.fixedStyle`: only `.settings`
    /// follows the Style setting; an explicit pick, Automatic included, wins.
    @Test func styleChoiceMapsToTheRequestStyle() {
        #expect(CoverStyleChoice.settings.fixedStyle(settingsStyle: .sketch) == .sketch)
        #expect(CoverStyleChoice.settings.fixedStyle(settingsStyle: nil) == nil)
        #expect(CoverStyleChoice.automatic.fixedStyle(settingsStyle: .sketch) == nil)
        #expect(CoverStyleChoice.fixed(.clay).fixedStyle(settingsStyle: .sketch) == .clay)
    }

    @Test func engineConstants() {
        #expect(CoverEngine.localServer.budget == 300)
        #expect(CoverEngine.codex.budget == 240)
        #expect(CoverEngine.openRouter.budget == 90)
        #expect(CoverEngine.localServer.retries == 1)
        #expect(CoverEngine.codex.retries == 0)
        #expect(CoverEngine.openRouter.retries == 1)
        #expect(CoverEngine.allCases.filter { !$0.takesModel } == [.codex])
        #expect(CoverEngine.offValue == "off")
        #expect(CoverSettings(engine: nil).engineStorageValue == "off")
        #expect(CoverSettings(engine: .openRouter).engineStorageValue == "openrouter")
        #expect(CoverSettings(style: nil).styleStorageValue == "auto")
        #expect(CoverSettings(style: .clay).styleStorageValue == "clay")
        // Pickers iterate both enums (`ForEach(…allCases)`), keyed by the stored value.
        #expect(CoverEngine.allCases.map(\.id) == ["local", "codex", "openrouter"])
        #expect(CoverStyle.allCases.map(\.id) == ["animation", "illustration", "sketch", "clay"])
        #expect(CoverEngine.allCases.map(\.displayName) == ["Local server", "Codex", "OpenRouter"])
        #expect(CoverStyle.allCases.map(\.displayName) == ["Animation", "Illustration", "Sketch", "Clay"])
    }

    @Test func settingsLoadReadsTheFourKeys() {
        let settings = Settings.load(config: [
            "cover_engine": "openrouter",
            "cover_automatic": "false",
            "cover_style": "clay",
            "cover_models": #"{"openrouter":"m"}"#,
        ])
        #expect(settings.coverSettings == CoverSettings(
            engine: .openRouter, automatic: false, style: .clay, models: [.openRouter: "m"]
        ))
    }

    @Test func errorCopyIsReadable() {
        #expect(CoverError.unreadableImage.localizedDescription == "The image model returned an unreadable image")
        #expect(CoverError.sceneUnreadable("x").localizedDescription == "The scene came back unreadable")
        #expect(CoverError.refused("moderation").localizedDescription == "The image model refused this scene — try New Cover")
        #expect(CoverError.dataPolicy(model: "m").localizedDescription
            == "OpenRouter's data policy on this account allows no endpoint for m — pick another image model in Settings → Meetings")
        #expect(CoverError.noSummary.localizedDescription == "Needs a summary")
        #expect(CoverError.noImage.localizedDescription == "The image model returned no image")
        #expect(CoverError.http(status: 503, body: "x").localizedDescription == "HTTP 503")
    }
}
