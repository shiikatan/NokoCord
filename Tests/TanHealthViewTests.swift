import Foundation
import XCTest
@testable import NokoCordCore

final class TanHealthViewTests: XCTestCase {
    private func record(
        health: TanHealth,
        approved: Bool = true
    ) -> TanTrustRecord {
        TanTrustRecord(
            tanID: "fixture.health",
            contentHash: String(repeating: "a", count: 64),
            approvedCapabilities: [],
            approvedAt: approved ? Date(timeIntervalSince1970: 100) : nil,
            lastKnownGoodVersion: "1.0.0",
            lastKnownGoodHash: String(repeating: "a", count: 64),
            health: health,
            failureCount: health == .failed ? 1 : 0,
            quarantineReason: health == .quarantined ? "Repeated startup failures" : nil
        )
    }

    func testHealthPresentationCoversEveryUserVisibleState() {
        let awaiting = TanHealthPresentation.make(record: nil, isEnabled: false, reloadRequired: false)
        XCTAssertEqual(awaiting.state, .awaitingApproval)

        let healthy = TanHealthPresentation.make(record: record(health: .healthy), isEnabled: true, reloadRequired: false)
        XCTAssertEqual(healthy.state, .enabledHealthy)

        let disabled = TanHealthPresentation.make(record: record(health: .healthy), isEnabled: false, reloadRequired: false)
        XCTAssertEqual(disabled.state, .disabled)

        let failed = TanHealthPresentation.make(record: record(health: .failed), isEnabled: true, reloadRequired: false)
        XCTAssertEqual(failed.state, .failedDegraded)

        let quarantined = TanHealthPresentation.make(record: record(health: .quarantined), isEnabled: false, reloadRequired: false)
        XCTAssertEqual(quarantined.state, .quarantined)

        let reload = TanHealthPresentation.make(record: record(health: .healthy), isEnabled: true, reloadRequired: true)
        XCTAssertEqual(reload.state, .reloadRequired)
    }

    func testHealthPresentationPrioritizesRecoverySafetyAndHasActionableCopy() {
        let quarantined = TanHealthPresentation.make(record: record(health: .quarantined), isEnabled: false, reloadRequired: true)
        XCTAssertEqual(quarantined.state, .quarantined)
        XCTAssertFalse(quarantined.title.isEmpty)
        XCTAssertFalse(quarantined.message.isEmpty)
        XCTAssertNotNil(quarantined.action)

        for state in TanHealthDisplayState.allCases {
            let presentation = TanHealthPresentation.forState(state)
            XCTAssertFalse(presentation.title.isEmpty)
            XCTAssertFalse(presentation.message.isEmpty)
        }
    }
}
