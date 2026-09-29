import XCTest
@testable import NokoCordCore

final class TanOriginalsTests: XCTestCase {
    func testC130OriginalsAreCapabilityFreeAndLifecycleManaged() throws {
        let focus = try XCTUnwrap(TanPackage.originals.first { $0.id == "noko.focus-shield" })
        let workbench = try XCTUnwrap(TanPackage.originals.first { $0.id == "noko.code-workbench" })

        for package in [focus, workbench] {
            XCTAssertNoThrow(try package.validate())
            XCTAssertEqual(package.manifest.target, .isolated)
            XCTAssertTrue(package.manifest.capabilities.isEmpty)
            XCTAssertTrue(package.javascript?.contains("api.onCleanup") == true)
            XCTAssertFalse(package.javascript?.contains("window.webkit") == true)
            XCTAssertFalse(package.javascript?.contains("fetch(") == true)
            XCTAssertFalse(package.javascript?.contains("localStorage") == true)
            XCTAssertFalse(package.javascript?.contains("setInterval") == true)
        }

        XCTAssertTrue(focus.javascript?.contains("data-noko-focus-shield") == true)
        XCTAssertTrue(workbench.javascript?.contains("data-noko-code-workbench") == true)
        XCTAssertTrue(workbench.javascript?.contains("data-noko-code-gutter") == true)
        XCTAssertTrue(workbench.css?.contains("data-noko-code-gutter") == true)
    }

    func testC130OriginalsHaveStableContentIdentity() throws {
        let focus = try XCTUnwrap(TanPackage.originals.first { $0.id == "noko.focus-shield" })
        let workbench = try XCTUnwrap(TanPackage.originals.first { $0.id == "noko.code-workbench" })
        XCTAssertNotEqual(focus.contentHash, workbench.contentHash)
        XCTAssertEqual(focus.manifest.version, "1.0.0")
        XCTAssertEqual(workbench.manifest.version, "1.0.0")
    }
}
