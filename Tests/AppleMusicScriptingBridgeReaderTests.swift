import XCTest
@testable import NokoCordCore

final class AppleMusicScriptingBridgeReaderTests: XCTestCase {
    func testDatabaseIDConversionRejectsInvalidAndNonIntegralNumbersWithoutTrapping() {
        XCTAssertEqual(AppleMusicDatabaseID.from(42), 42)
        XCTAssertNotNil(AppleMusicDatabaseID.from(Double(Int64.max).nextDown))

        for invalid in [Double.nan, .infinity, -.infinity, 0, -1, 0.5, 1.5,
                        Double(Int64.max), Double.greatestFiniteMagnitude] {
            XCTAssertNil(AppleMusicDatabaseID.from(invalid), "Expected \(invalid) to be rejected")
        }
    }
}
