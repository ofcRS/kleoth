import Foundation

/// Builds `multipart/form-data` request bodies for file uploads
/// (e.g. the Scribe transcription endpoint).
public struct Multipart {
    public let boundary: String

    public init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    /// The value for the `Content-Type` HTTP header.
    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// Appends a simple text field to the multipart body.
    public mutating func addField(name: String, value: String) {
        fatalError("unimplemented")
    }

    /// Appends a file part with the given binary contents.
    public mutating func addFile(
        name: String,
        filename: String,
        contentType: String,
        data: Data
    ) {
        fatalError("unimplemented")
    }

    /// Finalizes and returns the encoded multipart body.
    public func finalizedBody() -> Data {
        fatalError("unimplemented")
    }
}
