import Testing
import Foundation
@testable import KleothCore

/// Covers the `repeatedFields:` parameter added for Scribe's array-valued
/// `keyterms` form field. The legacy body must be untouched when it is empty.
@Suite struct MultipartRepeatedFieldTests {
    private let crlf = "\r\n"

    private struct Built {
        let data: Data
        let text: String
        let boundary: String
        let fileURL: URL
        let bodyURL: URL
    }

    private func makeSourceFile(_ contents: String = "AUDIO-BYTES") throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-mprf-src-\(UUID().uuidString).m4a")
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }

    private func build(
        fields: [String: String],
        repeatedFields: [(name: String, value: String)],
        fileURL: URL,
        boundary: String
    ) throws -> Built {
        let (bodyURL, usedBoundary) = try Multipart.writeBody(
            fields: fields,
            repeatedFields: repeatedFields,
            fileFieldName: "file",
            fileURL: fileURL,
            mimeType: "audio/mp4",
            boundary: boundary
        )
        let data = try Data(contentsOf: bodyURL)
        return Built(
            data: data,
            text: String(decoding: data, as: UTF8.self),
            boundary: usedBoundary,
            fileURL: fileURL,
            bodyURL: bodyURL
        )
    }

    @Test func repeatedFieldsEmitOnePartPerValueInOrder() throws {
        let fileURL = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let built = try build(
            fields: [:],
            repeatedFields: [
                (name: "keyterms", value: "Kleoth"),
                (name: "keyterms", value: "WhisperKit"),
                (name: "keyterms", value: "Scribe"),
            ],
            fileURL: fileURL,
            boundary: "kleoth-fixed-repeat"
        )
        defer { try? FileManager.default.removeItem(at: built.bodyURL) }

        let header = "Content-Disposition: form-data; name=\"keyterms\"\(crlf)\(crlf)"
        let parts = built.text.components(separatedBy: header)
        #expect(
            parts.count == 4,
            "Expected exactly 3 keyterms parts (one per value). Body:\n\(built.text)"
        )

        // Values appear in the caller's order.
        let kleoth = try #require(built.text.range(of: "\(header)Kleoth\(crlf)"))
        let whisper = try #require(built.text.range(of: "\(header)WhisperKit\(crlf)"))
        let scribe = try #require(built.text.range(of: "\(header)Scribe\(crlf)"))
        #expect(kleoth.lowerBound < whisper.lowerBound)
        #expect(whisper.lowerBound < scribe.lowerBound)
    }

    @Test func emptyRepeatedFieldsBodyIsByteIdenticalToLegacy() throws {
        let fileURL = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let boundary = "kleoth-fixed-identity"
        let fields = ["model_id": "scribe_v2"]

        // Legacy call site: no repeatedFields argument at all.
        let (legacyURL, _) = try Multipart.writeBody(
            fields: fields,
            fileFieldName: "file",
            fileURL: fileURL,
            mimeType: "audio/mp4",
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: legacyURL) }
        let legacy = try Data(contentsOf: legacyURL)

        let built = try build(fields: fields, repeatedFields: [], fileURL: fileURL, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: built.bodyURL) }

        #expect(
            built.data == legacy,
            "An empty repeatedFields must not change a single byte of the body."
        )
    }

    @Test func repeatedFieldsCoexistWithFieldsAndFilePartIsLast() throws {
        let fileURL = try makeSourceFile("BYTES-XYZ")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let built = try build(
            fields: ["model_id": "scribe_v2"],
            repeatedFields: [(name: "keyterms", value: "Kleoth")],
            fileURL: fileURL,
            boundary: "kleoth-fixed-coexist"
        )
        defer { try? FileManager.default.removeItem(at: built.bodyURL) }

        let modelRange = try #require(built.text.range(of: "name=\"model_id\""))
        let keytermRange = try #require(built.text.range(of: "name=\"keyterms\""))
        let fileRange = try #require(built.text.range(of: "name=\"file\"; filename="))

        #expect(modelRange.lowerBound < keytermRange.lowerBound, "Keyed fields come first.")
        #expect(keytermRange.lowerBound < fileRange.lowerBound, "The file part stays last.")
        #expect(built.text.hasSuffix("--\(built.boundary)--\(crlf)"))
        #expect(built.text.contains("BYTES-XYZ"))
    }
}
