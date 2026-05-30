import Foundation

/// Builds `multipart/form-data` request bodies for file uploads
/// (e.g. the Scribe transcription endpoint).
///
/// Two modes are provided:
///
/// 1. The instance API (`addField`, `addFile`, `finalizedBody`) assembles a
///    body entirely in memory. Suitable for small payloads only.
/// 2. ``Multipart/writeBody(fields:fileFieldName:fileURL:mimeType:boundary:)``
///    streams the body to a temporary file on disk, copying the source file
///    in fixed-size chunks. This is the path the Scribe client uses because
///    audio files can be multiple gigabytes and must never be loaded into
///    memory in full.
///
/// Every line break in a multipart body is CRLF (`\r\n`), per RFC 2046.
public struct Multipart {
    public let boundary: String

    /// Accumulated body bytes for the in-memory API.
    private var body = Data()

    public init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    /// The value for the `Content-Type` HTTP header.
    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// Appends a simple text field to the multipart body.
    public mutating func addField(name: String, value: String) {
        body.append(Self.crlfData("--\(boundary)"))
        body.append(Self.crlfData("Content-Disposition: form-data; name=\"\(name)\""))
        body.append(Self.crlfData(""))
        body.append(Self.crlfData(value))
    }

    /// Appends a file part with the given binary contents.
    public mutating func addFile(
        name: String,
        filename: String,
        contentType: String,
        data: Data
    ) {
        body.append(Self.crlfData("--\(boundary)"))
        body.append(Self.crlfData("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\""))
        body.append(Self.crlfData("Content-Type: \(contentType)"))
        body.append(Self.crlfData(""))
        body.append(data)
        body.append(Self.crlfData(""))
    }

    /// Finalizes and returns the encoded multipart body.
    public func finalizedBody() -> Data {
        var result = body
        result.append(Self.crlfData("--\(boundary)--"))
        return result
    }

    // MARK: - Streaming (temp file) construction

    /// Default boundary for the streaming API: `"kleoth-<UUID>"`.
    public static func makeBoundary() -> String {
        "kleoth-\(UUID().uuidString)"
    }

    /// Writes a `multipart/form-data` body to a temporary file and returns the
    /// file's URL together with the boundary used.
    ///
    /// Layout, with `\r\n` written between and after every header/value line:
    ///
    /// ```
    /// --<boundary>\r\n
    /// Content-Disposition: form-data; name="<k>"\r\n
    /// \r\n
    /// <value>\r\n
    /// ... (repeated for each field) ...
    /// --<boundary>\r\n
    /// Content-Disposition: form-data; name="<fileFieldName>"; filename="<lastPathComponent>"\r\n
    /// Content-Type: <mimeType>\r\n
    /// \r\n
    /// <file bytes streamed in chunks>\r\n
    /// --<boundary>--\r\n
    /// ```
    ///
    /// The source file is copied in fixed-size chunks via `FileHandle`, so a
    /// multi-gigabyte upload never resides in memory in full.
    ///
    /// - Parameters:
    ///   - fields: Ordered-insensitive text fields to emit before the file part.
    ///   - fileFieldName: The form field name for the binary part (e.g. `"file"`).
    ///   - fileURL: The source file whose bytes form the file part.
    ///   - mimeType: The `Content-Type` for the file part.
    ///   - boundary: The multipart boundary; defaults to `"kleoth-<UUID>"`.
    /// - Returns: The temporary body file URL and the boundary string.
    /// - Throws: Any file-system error encountered while reading the source
    ///   file or writing the temporary body file.
    public static func writeBody(
        fields: [String: String],
        fileFieldName: String,
        fileURL: URL,
        mimeType: String,
        boundary: String = Multipart.makeBoundary()
    ) throws -> (bodyURL: URL, boundary: String) {
        let fileManager = FileManager.default
        let bodyURL = fileManager.temporaryDirectory
            .appendingPathComponent("kleoth-multipart-\(UUID().uuidString).tmp")

        // Create the (empty) destination file up front.
        guard fileManager.createFile(atPath: bodyURL.path, contents: nil) else {
            throw MultipartError.cannotCreateTempFile(bodyURL)
        }

        let writeHandle = try FileHandle(forWritingTo: bodyURL)
        // Best-effort cleanup of the write handle on any error.
        var didCloseWriteHandle = false
        func closeWriteHandle() {
            guard !didCloseWriteHandle else { return }
            didCloseWriteHandle = true
            try? writeHandle.close()
        }
        defer { closeWriteHandle() }

        do {
            // 1. Text fields.
            for (key, value) in fields {
                try writeHandle.kleoth_write(crlfData("--\(boundary)"))
                try writeHandle.kleoth_write(crlfData("Content-Disposition: form-data; name=\"\(key)\""))
                try writeHandle.kleoth_write(crlfData(""))
                try writeHandle.kleoth_write(crlfData(value))
            }

            // 2. File part header.
            let filename = fileURL.lastPathComponent
            try writeHandle.kleoth_write(crlfData("--\(boundary)"))
            try writeHandle.kleoth_write(
                crlfData("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"")
            )
            try writeHandle.kleoth_write(crlfData("Content-Type: \(mimeType)"))
            try writeHandle.kleoth_write(crlfData(""))

            // 3. File bytes, streamed in chunks.
            let readHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? readHandle.close() }
            let chunkSize = 1 << 20 // 1 MiB
            while true {
                let chunk = try readHandle.kleoth_read(upToCount: chunkSize)
                guard let chunk, !chunk.isEmpty else { break }
                try writeHandle.kleoth_write(chunk)
            }

            // 4. Trailing CRLF after file bytes, then closing boundary.
            try writeHandle.kleoth_write(crlfData(""))
            try writeHandle.kleoth_write(crlfData("--\(boundary)--"))
        } catch {
            closeWriteHandle()
            try? fileManager.removeItem(at: bodyURL)
            throw error
        }

        closeWriteHandle()
        return (bodyURL, boundary)
    }

    // MARK: - Helpers

    /// Encodes `line` as UTF-8 followed by a CRLF terminator.
    private static func crlfData(_ line: String) -> Data {
        var data = Data(line.utf8)
        data.append(0x0D) // \r
        data.append(0x0A) // \n
        return data
    }
}

/// Errors thrown while building a multipart body.
public enum MultipartError: Error, CustomStringConvertible, Sendable {
    case cannotCreateTempFile(URL)

    public var description: String {
        switch self {
        case .cannotCreateTempFile(let url):
            return "Could not create temporary multipart body file at \(url.path)."
        }
    }
}

// MARK: - FileHandle bridging

/// Cross-version `FileHandle` wrappers that prefer the throwing APIs available
/// on the deployment targets (macOS 13+) and avoid the deprecated variants.
private extension FileHandle {
    func kleoth_write(_ data: Data) throws {
        try self.write(contentsOf: data)
    }

    func kleoth_read(upToCount count: Int) throws -> Data? {
        try self.read(upToCount: count)
    }
}
