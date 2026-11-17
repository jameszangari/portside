import Foundation
import XCTest

/// Reads JSON fixtures from `Tests/portsideTests/Fixtures`. Located from this
/// file's path, so no resource bundle is needed.
enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func data(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("missing fixture \(name)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    static func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
