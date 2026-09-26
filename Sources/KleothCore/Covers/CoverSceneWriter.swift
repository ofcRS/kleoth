import Foundation

/// What the scene step decided for one meeting. `scene` is sanitized, and
/// empty when `sensitive` is true: a sensitive meeting gets no picture at all.
public struct CoverScene: Sendable, Equatable {
    public var sensitive: Bool
    public var style: CoverStyle
    public var scene: String

    public init(sensitive: Bool, style: CoverStyle, scene: String) {
        self.sensitive = sensitive
        self.style = style
        self.scene = scene
    }
}

/// The scene step (design doc 2026-09-24 §3.3): one chat call, through the
/// summary task's provider, that turns a meeting into a short, wordless,
/// people-free scene an image model can draw — or decides the meeting is too
/// sensitive to picture.
///
/// It reads only the title, the TL;DR and the start of the overview. The
/// transcript, action items, speaker highlights and participants never leave
/// the machine for a cover: they carry names, and a scene built from them
/// would too.
public struct CoverSceneWriter: Sendable {
    public static let schemaName = "cover_scene"
    public static let maxOverviewCharacters = 1_500
    /// Room for a 45-word scene plus whatever the model spends on low-effort
    /// reasoning.
    public static let maxTokens = 1_000
    /// A 45-word scene is about 300 characters; the cap only stops a runaway.
    public static let maxSceneCharacters = 400

    /// The scene prompt, revision 4 (2026-09-25). Revision 3 is the look
    /// test's settled wording (`.scratch/cover-spike/RESULTS.md`, "Settled
    /// wording", approved 2026-09-25): §3.3's rules plus what the test images
    /// showed — things that usually carry printing (clocks, banners, boxes with
    /// printed covers, app UI), feelings shown by posture rather than "?"
    /// glyphs, one close moment with at most two props so a 40 pt tile still
    /// reads, and no symbols. Revision 4 adds two lines: no picture inside the
    /// picture (photos, frames, posters, mirrors, screens showing a picture —
    /// they invite faces and lettering, and often come out blank — not even
    /// named when the meeting is about photos), and one physical metaphor for
    /// the topic rather than a re-staged meeting room. The metaphor line names
    /// kinds of action (joined, balanced, mended…), not objects: example
    /// objects came back in every dry-run scene, and covers would converge.
    static let systemPrompt = """
    You write the scene for a small square cover picture of a meeting. You get the meeting's title, its TL;DR and the start of its overview. The picture is decoration for the meeting's row in a list, so it must be gentle, safe and wordless.

    Answer with one JSON object and nothing else:
    {"sensitive": true or false, "style": "animation" | "illustration" | "sketch" | "clay", "scene": "at most 45 English words"}

    sensitive
    - true when the meeting is mainly about health, a person's performance, pay, hiring or firing, layoffs, legal disputes, grief, family or relationships, personal money, therapy or coaching, a security incident, or anything a participant would not want pictured.
    - When unsure: true.
    - When sensitive is true, scene is an empty string. Do not describe the meeting.

    scene
    - One or two English sentences, at most 45 words, whatever language the meeting was in.
    - One to three cute animal characters (otters, foxes, owls, rabbits, bears, hedgehogs, penguins, red pandas) or everyday objects act out the meeting's main topic as a gentle metaphor.
    - Never people, human faces or hands.
    - Never real names, companies, brands, products, places or events. Never the names used in the meeting.
    - Nothing to read: no text, letters, numbers, signs, labels, screens, documents with writing, or charts. Also leave out things that usually carry writing or numbers: clocks, calendars, banners, flags, maps, tickets, boxes, books or packages with printed covers (board games, cereal, tins), and app icons, buttons or menus. Show the topic as a physical, everyday situation, never as a piece of software. Show feelings through posture, never with question marks or other symbols.
    - No photos, photographs, picture frames, framed pictures, posters, paintings, portraits, mirrors, or screens showing a picture — a picture inside the picture invites faces and lettering, and often comes out blank. Never these words in the scene, even when the meeting is about them.
    - One close moment with at most two props, against a simple backdrop, so it still reads as a tiny thumbnail.
    - Prefer the abstract to the literal: one physical metaphor for the main topic, built from the characters and their one or two props, rather than a re-staging of the conversation. Take the setting from the meeting's own world (a riverbank, a workshop, a garden, a kitchen, a hillside) and let the action carry the idea — something joined, balanced, mended, carried across, shared out, sorted, grown or set free. Invent it for this meeting; do not repeat a stock image. Never a meeting room, office, desk, conference table or laptop.
    - No ribbons, badges, flags or colour pairs that could read as a symbol.
    - Nothing violent, medical, political or religious.
    - Only what is visible: the characters, the objects, what they do and where. No art-style words (no "watercolour", "3D", "cartoon", "illustration", "cute style"), no camera or lighting words.
    - No quotation marks and no digits.

    style — pick by the meeting's mood:
    - animation: upbeat, launches, celebrations.
    - illustration: planning, reviews, decisions — the usual choice.
    - sketch: brainstorms, research, retros.
    - clay: building, fixing, operations.
    If the message says "Style: <name>", use that style.
    """

    /// The strict `cover_scene` schema, as the look test sent it. The style
    /// enum is `CoverStyle`'s raw values; every field is required, so a
    /// sensitive answer still carries a (empty) scene.
    static let schemaJSON = """
    {
      "type": "object",
      "properties": {
        "sensitive": { "type": "boolean" },
        "style": { "type": "string", "enum": ["animation", "illustration", "sketch", "clay"] },
        "scene": { "type": "string" }
      },
      "required": ["sensitive", "style", "scene"],
      "additionalProperties": false
    }
    """

    public let client: any ChatCompleting
    public let model: String

    public init(client: any ChatCompleting, model: String) {
        self.client = client
        self.model = model
    }

    /// Asks for the scene and returns it with the call's USD cost (0 when the
    /// backend reports none — only OpenRouter does).
    ///
    /// `fixedStyle` is the style fixed in Settings or picked from New Cover ▸;
    /// it wins over the model's pick. `previousScene` is New Cover's: the model
    /// is told to pick a clearly different idea. The request is the strict
    /// `cover_scene` schema with low reasoning and no temperature (§3.3): the
    /// answer is 45 words and needs no deliberation.
    ///
    /// Anthropic models get no reasoning at all: OpenRouter turns `low` into a
    /// 1,024-token thinking budget, which is not below the 1,000-token cap, so
    /// a budget-style model rejects the request and only the chat client's
    /// relaxed retry would save it — a second round trip, without the strict
    /// schema. (A deviation from §4.1's "reasoning `.low`".)
    ///
    /// Throws the client's error or `CoverError.sceneUnreadable`; an answer the
    /// output cap cut off says so in the unreadable detail ("cut off (length): …").
    public func write(
        title: String, summary: MeetingSummary, fixedStyle: CoverStyle?, previousScene: String?
    ) async throws -> (scene: CoverScene, cost: Double) {
        let messages = [
            ChatMessage(role: "system", content: Self.systemPrompt),
            ChatMessage(role: "user", content: Self.userContent(
                title: title, summary: summary, fixedStyle: fixedStyle, previousScene: previousScene
            )),
        ]
        let completion = try await client.complete(
            messages: messages,
            model: model,
            responseFormat: .jsonSchema(name: Self.schemaName, schemaJSON: Self.schemaJSON),
            maxTokens: Self.maxTokens,
            temperature: nil,
            reasoning: model.hasPrefix("anthropic/") ? nil : .low
        )
        let scene: CoverScene
        do {
            scene = try Self.parse(completion.content, fixedStyle: fixedStyle)
        } catch let CoverError.sceneUnreadable(detail) where completion.finishReason == "length" {
            throw CoverError.sceneUnreadable("cut off (length): " + detail)
        }
        return (scene, completion.usage?.cost ?? 0)
    }

    /// The user message: the title, the TL;DR and the first 1,500 overview
    /// characters, then New Cover's instructions when there are any. Nothing
    /// else from the summary goes in.
    static func userContent(
        title: String, summary: MeetingSummary, fixedStyle: CoverStyle?, previousScene: String?
    ) -> String {
        var lines = ["Title: \(title)", "TL;DR: \(summary.tldr)"]
        if let overview = summary.overview, !overview.isEmpty {
            lines.append("Overview: \(String(overview.prefix(maxOverviewCharacters)))")
        }
        if let fixedStyle { lines.append("Style: use exactly \"\(fixedStyle.rawValue)\".") }
        if let previousScene, !previousScene.isEmpty {
            lines.append("Previous scene: \(previousScene)\nPick a clearly different idea.")
        }
        return lines.joined(separator: "\n")
    }

    /// Reads the model's answer, fenced or not. `sensitive` must be a boolean,
    /// and a non-sensitive answer needs a scene that survives `sanitize`;
    /// anything else is `CoverError.sceneUnreadable` (its detail, the answer's
    /// first 200 characters, is for the log only). A missing or unknown style
    /// falls back to `fixedStyle`, else `illustration` — the usual choice — and
    /// a fixed style always wins. A sensitive answer's scene is dropped, even
    /// when the model wrote one against the prompt.
    static func parse(_ content: String, fixedStyle: CoverStyle?) throws -> CoverScene {
        let text = Summarizer.stripCodeFences(content)
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let sensitive = object["sensitive"] as? Bool
        else { throw CoverError.sceneUnreadable(String(content.prefix(200))) }

        let pickedStyle = CoverStyle(rawValue: (object["style"] as? String ?? "").lowercased())
        let style = fixedStyle ?? pickedStyle ?? .illustration
        if sensitive { return CoverScene(sensitive: true, style: style, scene: "") }

        let scene = sanitize(object["scene"] as? String ?? "")
        guard !scene.isEmpty else { throw CoverError.sceneUnreadable(String(content.prefix(200))) }
        return CoverScene(sensitive: false, style: style, scene: scene)
    }

    /// Straight and typographic quotes and every digit both invite an image
    /// model to letter them into the picture, so they go; whitespace runs
    /// collapse to one space; the result is capped at `maxSceneCharacters`.
    /// The cap cuts at the last space at or before it, so the scene never ends
    /// in half a word; a scene with no space there is cut at the cap itself.
    static func sanitize(_ scene: String) -> String {
        var unquoted = String.UnicodeScalarView()
        unquoted.append(contentsOf: scene.unicodeScalars.filter { !quoteScalars.contains($0) })
        let words = String(unquoted).filter { !$0.isNumber }.split(whereSeparator: \.isWhitespace)
        let joined = words.joined(separator: " ")
        guard joined.count > maxSceneCharacters else { return joined }
        // `through: cap` includes the first character past the cap: a space
        // there means the cap already falls between two words.
        let window = joined[...joined.index(joined.startIndex, offsetBy: maxSceneCharacters)]
        guard let space = window.lastIndex(of: " ") else {
            return String(joined.prefix(maxSceneCharacters))
        }
        return String(joined[..<space]).trimmingCharacters(in: .whitespaces)
    }

    private static let quoteScalars = Set("\"'“”‘’«»".unicodeScalars)
}
