import Foundation
import XCTest
@testable import NokoCordCore

final class TanOriginalsTests: XCTestCase {
    private func fixture(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Tans")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

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

    func testFocusShieldFixtureDefinesAllPresentationProfilesAndSafeCleanup() throws {
        let focus = try XCTUnwrap(TanPackage.originals.first { $0.id == "noko.focus-shield" })
        let javascript = try XCTUnwrap(focus.javascript)
        let stylesheet = try XCTUnwrap(focus.css)
        let fixture = try fixture("focus-shield/fixture.html")

        for profile in ["screen-share", "meeting", "streaming"] {
            XCTAssertTrue(javascript.contains(profile), "Missing Focus Shield profile: \(profile)")
            XCTAssertTrue(stylesheet.contains(profile), "Missing Focus Shield profile CSS: \(profile)")
            XCTAssertTrue(fixture.contains("data-fixture-\(profile)"), "Fixture lacks \(profile) presentation anchor")
        }
        XCTAssertTrue(javascript.contains("data-noko-focus-shield-indicator"))
        XCTAssertTrue(javascript.contains("aria-live"))
        XCTAssertTrue(javascript.contains("aria-pressed"))
        XCTAssertTrue(javascript.contains("prefers-reduced-motion"))
        XCTAssertTrue(javascript.contains("matchMedia"))
        XCTAssertTrue(javascript.contains("document.activeElement"))
        XCTAssertTrue(javascript.contains("api.onCleanup"))
        XCTAssertFalse(javascript.contains("fetch("))
        XCTAssertFalse(javascript.contains("localStorage"))
        XCTAssertFalse(javascript.contains("window.webkit"))
    }

    func testCodeWorkbenchFixtureDefinesBoundedAccessibleDynamicRendering() throws {
        let workbench = try XCTUnwrap(TanPackage.originals.first { $0.id == "noko.code-workbench" })
        let javascript = try XCTUnwrap(workbench.javascript)
        let stylesheet = try XCTUnwrap(workbench.css)
        let fixture = try fixture("code-workbench/fixture.html")

        for marker in ["MutationObserver", "requestAnimationFrame", "pendingRoots", "scanBudget", "aria-controls", "aria-expanded", "aria-keyshortcuts", "role", "aria-live", "contenteditable", "navigator.clipboard", "focus()"] {
            XCTAssertTrue(javascript.contains(marker), "Missing Code Workbench contract: \(marker)")
        }
        XCTAssertTrue(stylesheet.contains(":focus-visible"))
        XCTAssertTrue(stylesheet.contains("prefers-reduced-motion"))
        XCTAssertTrue(fixture.contains("data-fixture-dynamic-root"))
        XCTAssertTrue(fixture.contains("contenteditable=\"true\""))
        XCTAssertFalse(javascript.contains("window.webkit"))
        XCTAssertFalse(javascript.contains("fetch("))
        XCTAssertFalse(javascript.contains("localStorage"))
        XCTAssertFalse(javascript.contains("eval("))
    }

    func testTanFixturesContainDeterministicMutationBudgetAndSafeModeInputs() throws {
        let budget = try fixture("support/mutation-budget.html")
        let safeMode = try fixture("support/safe-mode.html")

        XCTAssertTrue(budget.contains("data-fixture-editor-mutations=\"1000\""))
        XCTAssertTrue(budget.contains("data-fixture-message-mutations=\"1000\""))
        XCTAssertTrue(budget.contains("data-fixture-one-frame=\"true\""))
        XCTAssertTrue(safeMode.contains("data-fixture-safe-mode=\"true\""))
        XCTAssertFalse(safeMode.contains("NokoTan.register"))
    }
}
