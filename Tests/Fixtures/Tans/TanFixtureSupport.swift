import Foundation

enum TanFixtureSupport {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()

    static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func html(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }
}
