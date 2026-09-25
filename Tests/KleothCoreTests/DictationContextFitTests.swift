import Testing
import Foundation
@testable import KleothCore

@Suite struct DictationContextFitTests {
    /// `fitted` with the arguments most cases leave alone.
    private func fit(_ text: String, before: String, after: String = "", singleLine: Bool = false) -> String {
        DictationContextFit.fitted(text, before: before, after: after, singleLine: singleLine)
    }

    @Test func boundaryClassifiesStartsAndMidSentence() {
        let cases: [(before: String, expected: DictationContextFit.Boundary)] = [
            ("", .fieldStart),
            ("  ", .fieldStart),
            ("Hi.\n", .lineStart),
            ("Hi.\n  ", .lineStart),
            ("Done.", .sentenceStart),
            ("Done. ", .sentenceStart),
            ("Готово!", .sentenceStart),
            ("Wait…", .sentenceStart),
            ("He said \"stop.\"", .sentenceStart),
            ("(see above.)", .sentenceStart),
            ("I think the problem is", .midSentence),
            ("Note:", .midSentence),
            ("items,", .midSentence),
            ("A —", .midSentence),
            ("He said \"", .midSentence),
            ("(«", .midSentence),
            ("Посмотри функцию экспорта в", .midSentence),
            // Also pinned by the rules: a tab and an NBSP are spaces; CRLF, U+2028 and U+2029 are
            // line breaks; closers stack (a Russian closing quote, then a bracket).
            ("Done.\t\u{00A0}", .sentenceStart),
            ("Hi.\r\n", .lineStart),
            ("Hi.\u{2028}", .lineStart),
            ("Hi.\u{2029} ", .lineStart),
            ("(«Готово.»)", .sentenceStart),
            ("Why?", .sentenceStart),
            // “ closes a German or Russian quote after a sentence end, and opens one after a space (R11).
            ("„Готово.“", .sentenceStart),
            ("He said “", .midSentence),
        ]
        for (before, expected) in cases {
            #expect(DictationContextFit.boundary(before: before) == expected, "before: \(before.debugDescription)")
        }
    }

    @Test func fittedSpacesAfterAWordButNotAfterWhitespaceOrAnOpeningBracket() {
        #expect(fit("that…", before: "is") == " that…")
        #expect(fit("that…", before: "is ") == "that…")
        #expect(fit("that…", before: "(") == "that…")
        #expect(fit("that…", before: "He said \"") == "that…")
        #expect(fit("that…", before: "She said \"hi\"") == " that…")
        // Every listed opener; a straight quote opens after nothing or after another opener, and
        // closes (an apostrophe here) after a letter.
        for before in ["see [", "see {", "said «", "said “", "said ‘", "\"", "see (\"", "said \"'", "sagte ‚"] {
            #expect(fit("that…", before: before) == "that…", "before: \(before.debugDescription)")
        }
        #expect(fit("that…", before: "the users'") == " that…")
        // „ and ‚ only ever open; “ after a letter closes, like a straight quote (R11).
        #expect(fit("привет", before: "он сказал „") == "привет")
        #expect(fit("and", before: "„Готово“") == " and")
    }

    @Test func fittedSpacesBeforeAFollowingWordOnly() {
        #expect(fit("big", before: "Hello", after: "world") == " big ")
        #expect(fit("big", before: "Hello", after: ", then") == " big")
        #expect(fit("big", before: "Hello", after: " world") == " big")
        #expect(fit("big", before: "Hello", after: "") == " big")
        // A digit and a Cyrillic letter start a word too; nothing to paste gets no spaces either.
        #expect(fit("big", before: "Hello", after: "42") == " big ")
        #expect(fit("big", before: "Hello", after: "мир") == " big ")
        #expect(fit(" \n ", before: "Hello", after: "world") == "")
        // A bracket or quote that only ever opens starts a word too; an ambiguous quote doesn't (R10).
        #expect(fit("big", before: "word ", after: "(see above)") == "big ")
        for after in ["[1]", "{x}", "«да»", "„ja“", "‚ja‘"] {
            #expect(fit("big", before: "word ", after: after) == "big ", "after: \(after.debugDescription)")
        }
        #expect(fit("big", before: "word ", after: "“quoted”") == "big")
        #expect(fit("big", before: "word ", after: "\"quoted\"") == "big")
    }

    @Test func fittedNeverSpacesBeforePunctuation() {
        #expect(fit(", and more", before: "word") == ", and more")
        // Closing and terminal punctuation only (R4)…
        for text in [". Next", "; and", ": this", "! Yes", "? No", "… and", ") too", "] too", "} too", "» too", "” too", "’ too", "% more"] {
            #expect(fit(text, before: "word") == text, "text: \(text.debugDescription)")
        }
        // …an opening quote or a dash still gets its space.
        #expect(fit("\"quoted\"", before: "He said") == " \"quoted\"")
        #expect(fit("— and more", before: "word") == " — and more")
    }

    @Test func fittedCapitalizesAtStartsAndNeverLowercases() {
        #expect(fit("hello", before: "") == "Hello")          // field start
        #expect(fit("hello", before: "Hi.\n") == "Hello")     // line start
        #expect(fit("hello", before: "Done. ") == "Hello")    // sentence start
        #expect(fit("Hello", before: "I said ") == "Hello")   // mid-sentence keeps a capital…
        #expect(fit("hello", before: "I said ") == "hello")   // …and adds none
        // Only the first letter changes, Cyrillic included; a sentence start with no space after
        // the period gets both the space and the capital.
        #expect(fit("hello iOS", before: "") == "Hello iOS")
        #expect(fit("NASA said so", before: "Done. ") == "NASA said so")
        #expect(fit("привет", before: "Готово! ") == "Привет")
        #expect(fit("hello", before: "Done.") == " Hello")
    }

    @Test func singleLineCollapsesLineBreaks() {
        #expect(fit("a\n\nb\n c", before: "see ", singleLine: true) == "a b c")
        #expect(fit("a\n\nb\n c", before: "see ", singleLine: false) == "a\n\nb\n c")
        // Only runs holding a line break collapse (CRLF and U+2028 are line breaks); the ends are
        // trimmed either way.
        #expect(fit("a  b\n\tc", before: "see ", singleLine: true) == "a  b c")
        #expect(fit("a\r\nb\u{2028}c", before: "see ", singleLine: true) == "a b c")
        #expect(fit("\n a b \n", before: "see ", singleLine: false) == "a b")
    }

    @Test func mergeKeepsTheSelectionsOuterWhitespace() {
        #expect(DictationContextFit.insideSelectionWhitespace("Tuesday at 11", selection: "  Monday\n") == "  Tuesday at 11\n")
        // The merged text's own outer whitespace goes; a selection without any adds none.
        #expect(DictationContextFit.insideSelectionWhitespace(" Tuesday at 11\n", selection: "Monday") == "Tuesday at 11")
        // A selection that is only whitespace (a space between two words) still separates on both sides.
        #expect(DictationContextFit.insideSelectionWhitespace("Tuesday", selection: " ") == " Tuesday ")
    }

    @Test func appendedKeepsTheSelectionAndSeparatesOnce() {
        #expect(DictationContextFit.appended("And log it.", to: "Add a retry.") == "Add a retry. And log it.")
        #expect(DictationContextFit.appended("- c", to: "- a\n- b") == "- a\n- b\n- c")
        #expect(DictationContextFit.appended("world", to: "Hello ") == "Hello world ")
        #expect(DictationContextFit.appended("x", to: "") == "x")
        #expect(DictationContextFit.appended("  ", to: "x") == "x")
        // The dictation's own outer whitespace goes; a selected line's trailing break stays last.
        #expect(DictationContextFit.appended(" And log it.\n", to: "Add a retry.") == "Add a retry. And log it.")
        #expect(DictationContextFit.appended("- c", to: "- a\n- b\n") == "- a\n- b\n- c\n")
        // Attaching punctuation takes no separator; lines are judged on the selection's text without
        // its outer whitespace; a selection using CRLF gets a CRLF (R3).
        #expect(DictationContextFit.appended(", and more", to: "word") == "word, and more")
        #expect(DictationContextFit.appended("x", to: "\nHello") == "\nHello x")
        #expect(DictationContextFit.appended("- c", to: "- a\r\n- b") == "- a\r\n- b\r\n- c")
    }

    @Test func echoGuardFiresOnLongRunsTheTranscriptDoesNotHold() {
        // 45 letters once case, spaces and punctuation are dropped.
        let sentence = "Today we parse the whole file before writing anything."
        let before = "Looked at MeetingStore. \(sentence) It is slow on big files."
        let transcript = "so we should stream it instead"
        let echo = "\(sentence) So we should stream it instead."

        // Repeated from the field and never said → an echo.
        #expect(DictationContextFit.echoesContext(echo, before: before, after: "", transcript: transcript))
        // The speaker said it too → not an echo.
        #expect(!DictationContextFit.echoesContext(
            echo, before: before, after: "",
            transcript: "today we parse the whole file before writing anything so we should stream it instead"
        ))
        // A 30-letter repeat is too short to call.
        #expect(!DictationContextFit.echoesContext(
            "Parse the whole file before writing? No, stream it.", before: before, after: "", transcript: "no stream it"
        ))
        // Case, punctuation and spacing don't hide a repeat, in either script, from before or after.
        #expect(DictationContextFit.echoesContext(
            "TODAY, we parse the WHOLE file — before writing anything!!", before: before, after: "", transcript: transcript
        ))
        #expect(DictationContextFit.echoesContext(
            "ОНА ЧИТАЕТ ВЕСЬ ФАЙЛ ЦЕЛИКОМ прежде чем что то писать. Надо стримить.",
            before: "", after: "Она читает весь файл целиком, прежде чем что-то писать.", transcript: "надо стримить"
        ))
        // The threshold is 40 letters: a 40-letter repeat fires, a 39-letter one doesn't.
        let count = "Count: zero one two three four five six seven eight nine ten."
        #expect(DictationContextFit.echoesContext(
            "Zero, one, two, three, four, five, six, seven, eight, nine.", before: count, after: "", transcript: ""
        ))
        #expect(!DictationContextFit.echoesContext(
            "Then one, two, three, four, five, six, seven, eight, nine, ten — done.", before: count, after: "", transcript: ""
        ))
    }
}
