import XCTest
@testable import NokoCordCore

@MainActor
final class CapturePermissionGateTests: XCTestCase {
    private actor ControlledPermission {
        private var started = 0
        private var pending: [Int: CheckedContinuation<Bool, Never>] = [:]
        private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func request() async -> Bool {
            started += 1
            let current = started
            let ready = waiters.filter { $0.target <= current }
            waiters.removeAll { $0.target <= current }
            ready.forEach { $0.continuation.resume() }
            return await withCheckedContinuation { pending[current] = $0 }
        }

        func waitForRequest(_ target: Int) async {
            guard started < target else { return }
            await withCheckedContinuation { continuation in
                waiters.append((target: target, continuation: continuation))
            }
        }

        func finishRequest(_ request: Int, allowed: Bool) {
            pending.removeValue(forKey: request)?.resume(returning: allowed)
        }
    }

    private actor InvocationProbe {
        private var count = 0

        func record() { count += 1 }
        func value() -> Int { count }
    }

    func testInvalidatingOutstandingGrantPreventsCallback() async {
        let permission = ControlledPermission()
        let gate = CapturePermissionGate()
        var grants: [Int] = []
        var denials = 0

        let task = gate.begin(
            permission: { await permission.request() },
            granted: { grants.append($0) },
            denied: { denials += 1 }
        )
        await permission.waitForRequest(1)

        gate.invalidate()
        await permission.finishRequest(1, allowed: true)
        await task.value

        XCTAssertTrue(grants.isEmpty)
        XCTAssertEqual(denials, 0)
    }

    func testImmediateInvalidationPreventsPermissionInvocation() async {
        let probe = InvocationProbe()
        let gate = CapturePermissionGate()

        let task = gate.begin(
            permission: {
                await probe.record()
                return true
            },
            granted: { _ in },
            denied: {}
        )
        gate.invalidate()
        await task.value

        let invocations = await probe.value()
        XCTAssertEqual(invocations, 0)
    }

    func testSecondRequestSupersedesFirstEvenWhenFirstReturnsDenied() async {
        let permission = ControlledPermission()
        let gate = CapturePermissionGate()
        var grants: [Int] = []
        var denials = 0

        let first = gate.begin(
            permission: { await permission.request() },
            granted: { grants.append($0) },
            denied: { denials += 1 }
        )
        await permission.waitForRequest(1)

        let second = gate.begin(
            permission: { await permission.request() },
            granted: { grants.append($0) },
            denied: { denials += 1 }
        )
        await permission.waitForRequest(2)

        await permission.finishRequest(1, allowed: false)
        await permission.finishRequest(2, allowed: true)
        await first.value
        await second.value

        XCTAssertEqual(grants, [2])
        XCTAssertEqual(denials, 0)
    }

    func testCurrentDeniedCallbackCalledOnce() async {
        let gate = CapturePermissionGate()
        var denials = 0

        let task = gate.begin(
            permission: { false },
            granted: { _ in },
            denied: { denials += 1 }
        )
        await task.value

        XCTAssertEqual(denials, 1)
    }

    func testCurrentGrantReturnsAcceptedTokenThenInvalidationRejectsIt() async {
        let gate = CapturePermissionGate()
        var grantedToken: Int?

        let task = gate.begin(
            permission: { true },
            granted: { grantedToken = $0 },
            denied: {}
        )
        await task.value

        let token = try? XCTUnwrap(grantedToken)
        XCTAssertTrue(token.map(gate.accepts) ?? false)
        gate.invalidate()
        XCTAssertFalse(token.map(gate.accepts) ?? true)
    }
}
