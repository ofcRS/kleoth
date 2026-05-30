import Foundation
import Testing
@testable import KleothCore

/// Helpers for locating and decoding the JSON fixtures bundled with the test
/// target. The `KleothCoreTests` target declares `.copy("Fixtures")`, so the
/// files are reachable through `Bundle.module` under the `Fixtures`
/// subdirectory.
enum Fixtures {
    enum FixtureError: Error, CustomStringConvertible {
        case notFound(String)
        var description: String {
            switch self {
            case .notFound(let name): return "Missing fixture \(name).json in Fixtures/"
            }
        }
    }

    /// Resolves a fixture URL from the test bundle, throwing if absent.
    static func url(_ resource: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: resource,
            withExtension: "json",
            subdirectory: "Fixtures"
        ) else {
            throw FixtureError.notFound(resource)
        }
        return url
    }

    /// Loads and decodes a `ScribeResponse` fixture using the same snake_case
    /// strategy the production decoders use.
    static func scribeResponse(_ resource: String) throws -> ScribeResponse {
        let data = try Data(contentsOf: url(resource))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ScribeResponse.self, from: data)
    }
}
