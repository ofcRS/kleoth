import Testing
import Foundation
@testable import KleothCore

@Suite struct MultipartTests {
    private let crlf = "\r\n"

    private struct Built {
        let data: Data
        let text: String
        let boundary: String
        let fileURL: URL
        let bodyURL: URL
    }

    /// Builds a multipart body on disk via the streaming API and returns the
    /// raw bytes, decoded text, boundary, and the temp URLs to clean up.
    private func buildBody(
        fields: [String: String],
        fileFieldName: String = "file",
        mimeType: String = "audio/mp4",
        fileContents: String = "AUDIO-BYTES",
        fileExtension: String = "m4a"
    ) throws -> Built {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-mp-src-\(UUID().uuidString).\(fileExtension)")
        try Data(fileContents.utf8).write(to: fileURL)

        let (bodyURL, boundary) = try Multipart.writeBody(
            fields: fields,
            fileFieldName: fileFieldName,
            fileURL: fileURL,
            mimeType: mimeType
        )

        let data = try Data(contentsOf: bodyURL)
        let text = String(decoding: data, as: UTF8.self)
        return Built(data: data, text: text, boundary: boundary, fileURL: fileURL, bodyURL: bodyURL)
    }

    private func cleanup(_ built: Built) {
        try? FileManager.default.removeItem(at: built.fileURL)
        try? FileManager.default.removeItem(at: built.bodyURL)
    }

    @Test func bodyBeginsWithBoundaryDelimiter() throws {
        let built = try buildBody(fields: ["model_id": "scribe_v2"])
        defer { cleanup(built) }
        #expect(
            built.text.hasPrefix("--\(built.boundary)\(crlf)"),
            "Body should begin with --<boundary>CRLF. Got prefix:\n\(String(built.text.prefix(80)))"
        )
    }

    @Test func bodyUsesCRLFLineEndings() throws {
        let built = try buildBody(fields: ["model_id": "scribe_v2"])
        defer { cleanup(built) }
        // Every line terminator is CRLF; there must be no bare LF that is not
        // immediately preceded by a CR.
        let bytes = Array(built.data)
        for (i, byte) in bytes.enumerated() where byte == 0x0A { // LF
            #expect(i > 0, "LF at index 0 cannot be part of a CRLF")
            if i > 0 {
                #expect(bytes[i - 1] == 0x0D, "LF at index \(i) is not preceded by CR")
            }
        }
        // And there is at least one CRLF present.
        #expect(built.text.contains(crlf))
    }

    @Test func bodyIncludesFileContentDispositionWithNameFile() throws {
        let built = try buildBody(fields: [:], fileFieldName: "file")
        defer { cleanup(built) }
        #expect(
            built.text.contains("Content-Disposition: form-data; name=\"file\""),
            "Missing file Content-Disposition. Body:\n\(built.text)"
        )
        // Filename echoes the source file's last path component.
        #expect(built.text.contains("filename=\"\(built.fileURL.lastPathComponent)\""))
        // The declared mime type is present.
        #expect(built.text.contains("Content-Type: audio/mp4"))
    }

    @Test func bodyEndsWithClosingBoundary() throws {
        let built = try buildBody(fields: ["diarize": "true"])
        defer { cleanup(built) }
        #expect(
            built.text.hasSuffix("--\(built.boundary)--\(crlf)"),
            "Body should end with the closing --<boundary>--CRLF. Got suffix:\n\(String(built.text.suffix(80)))"
        )
    }

    @Test func bodyEmbedsFieldValuesAndFileBytes() throws {
        let built = try buildBody(
            fields: ["model_id": "scribe_v2"],
            fileContents: "AUDIO-BYTES"
        )
        defer { cleanup(built) }
        // Field part is present with its CRLF-separated header/value layout.
        #expect(built.text.contains("Content-Disposition: form-data; name=\"model_id\""))
        #expect(built.text.contains("\(crlf)\(crlf)scribe_v2\(crlf)"))
        // The streamed file bytes survive verbatim.
        #expect(built.text.contains("AUDIO-BYTES"))
    }

    // MARK: - In-memory API parity

    @Test func inMemoryFinalizedBodyShapeMatchesContract() {
        var mp = Multipart(boundary: "TESTBOUNDARY")
        mp.addField(name: "model_id", value: "scribe_v2")
        mp.addFile(name: "file", filename: "audio.m4a", contentType: "audio/mp4", data: Data("XYZ".utf8))
        let text = String(decoding: mp.finalizedBody(), as: UTF8.self)

        #expect(text.hasPrefix("--TESTBOUNDARY\(crlf)"))
        #expect(text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\""))
        #expect(text.hasSuffix("--TESTBOUNDARY--\(crlf)"))
        #expect(mp.contentType == "multipart/form-data; boundary=TESTBOUNDARY")
    }
}
