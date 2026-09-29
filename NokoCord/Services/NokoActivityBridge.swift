import Foundation

/// A narrow boundary around the native activity SDK. Implementations must not
/// perform OAuth or account connection work; the bridge only updates or clears
/// activity through the app's configured transport.
public protocol NokoActivityTransport: Sendable {
    func update(activity: NokoActivity) async throws
    func clear() async throws
}

public enum NokoActivityBridgeResult: Equatable, Sendable {
    case published
    case unchanged
    case cleared
    case alreadyStopped
    /// A newer owner or activity replaced this request while it was queued.
    case superseded
}

public struct NokoActivityBridgeSnapshot: Equatable, Sendable {
    public let owner: NokoActivityOwner?
    public let desiredActivity: NokoActivity?
    public let lastPublishedOwner: NokoActivityOwner?
    public let lastPublishedActivity: NokoActivity?
    public let clearRequired: Bool
    public let generation: UInt64

    fileprivate init(
        owner: NokoActivityOwner?,
        desiredActivity: NokoActivity?,
        lastPublishedOwner: NokoActivityOwner?,
        lastPublishedActivity: NokoActivity?,
        clearRequired: Bool,
        generation: UInt64
    ) {
        self.owner = owner
        self.desiredActivity = desiredActivity
        self.lastPublishedOwner = lastPublishedOwner
        self.lastPublishedActivity = lastPublishedActivity
        self.clearRequired = clearRequired
        self.generation = generation
    }
}

/// Owns the app-wide desired activity and serializes all transport calls.
///
/// The transport queue is separate from actor isolation because actors are
/// reentrant while an async SDK call is in flight. Each SDK operation waits
/// for its predecessor before entering the transport.
public actor NokoActivityBridge {
    private enum QueuedResult: Sendable {
        case published
        case cleared
        case superseded
    }

    private let transport: any NokoActivityTransport
    private let operationQueue = NokoActivityOperationQueue()

    private var owner: NokoActivityOwner?
    private var desiredActivity: NokoActivity?
    private var lastPublished: (owner: NokoActivityOwner, activity: NokoActivity)?
    private var clearRequired = false
    private var generation: UInt64 = 0
    private var pendingOperations = 0

    public init(transport: any NokoActivityTransport) {
        self.transport = transport
    }

    /// Requests the activity for an owner. A failed update leaves this desired
    /// value in place, so a later identical request retries the transport.
    public func publish(
        _ activity: NokoActivity,
        ownedBy newOwner: NokoActivityOwner
    ) async throws -> NokoActivityBridgeResult {
        if let owner, owner != newOwner {
            clearRequired = true
        }
        owner = newOwner
        desiredActivity = activity
        generation &+= 1
        let requestGeneration = generation

        if pendingOperations == 0,
           !clearRequired,
           lastPublished?.owner == newOwner,
           lastPublished?.activity == activity {
            return .unchanged
        }

        let mustClearFirst = clearRequired
        pendingOperations += 1
        defer { pendingOperations -= 1 }

        let outcome = try await operationQueue.run { [transport] in
            guard await self.isCurrent(requestGeneration) else { return QueuedResult.superseded }

            if mustClearFirst {
                try await transport.clear()
                await self.recordClearIfCurrent(requestGeneration)
            }

            guard await self.isCurrent(requestGeneration) else { return QueuedResult.superseded }
            try await transport.update(activity: activity)
            await self.recordPublishCompletion(
                requestGeneration,
                owner: newOwner,
                activity: activity
            )
            return .published
        }

        guard generation == requestGeneration else { return .superseded }
        switch outcome {
        case .published:
            lastPublished = (newOwner, activity)
            return .published
        case .cleared:
            return .superseded
        case .superseded:
            return .superseded
        }
    }

    /// Reasserts the current desired activity after Discord relaunches or an
    /// RPC connection is restored. This deliberately bypasses deduplication
    /// and keeps the current owner in place.
    public func reassert() async throws -> NokoActivityBridgeResult {
        guard let currentOwner = owner, let activity = desiredActivity else {
            return .alreadyStopped
        }

        generation &+= 1
        let requestGeneration = generation
        let mustClearFirst = clearRequired
        pendingOperations += 1
        defer { pendingOperations -= 1 }

        let outcome = try await operationQueue.run { [transport] in
            guard await self.isCurrent(requestGeneration) else { return QueuedResult.superseded }

            if mustClearFirst {
                try await transport.clear()
                await self.recordClearIfCurrent(requestGeneration)
            }

            guard await self.isCurrent(requestGeneration) else { return QueuedResult.superseded }
            try await transport.update(activity: activity)
            await self.recordPublishCompletion(
                requestGeneration,
                owner: currentOwner,
                activity: activity
            )
            return .published
        }

        guard generation == requestGeneration else { return .superseded }
        switch outcome {
        case .published:
            lastPublished = (currentOwner, activity)
            return .published
        case .cleared, .superseded:
            return .superseded
        }
    }

    /// Stops the current owner and clears its activity. A stop from an old
    /// provider is ignored after another provider has taken ownership.
    public func stop(ownedBy requestedOwner: NokoActivityOwner? = nil) async throws -> NokoActivityBridgeResult {
        if let requestedOwner, owner != requestedOwner {
            return .alreadyStopped
        }
        guard owner != nil || clearRequired || lastPublished != nil else {
            return .alreadyStopped
        }

        owner = nil
        desiredActivity = nil
        clearRequired = true
        generation &+= 1
        let requestGeneration = generation

        pendingOperations += 1
        defer { pendingOperations -= 1 }

        let outcome = try await operationQueue.run { [transport] in
            guard await self.isCurrent(requestGeneration) else { return QueuedResult.superseded }
            try await transport.clear()
            await self.recordClearIfCurrent(requestGeneration)
            return .cleared
        }

        guard generation == requestGeneration else { return .superseded }
        switch outcome {
        case .cleared:
            return .cleared
        case .published, .superseded:
            return .superseded
        }
    }

    public func snapshot() -> NokoActivityBridgeSnapshot {
        NokoActivityBridgeSnapshot(
            owner: owner,
            desiredActivity: desiredActivity,
            lastPublishedOwner: lastPublished?.owner,
            lastPublishedActivity: lastPublished?.activity,
            clearRequired: clearRequired,
            generation: generation
        )
    }

    private func isCurrent(_ requestGeneration: UInt64) -> Bool {
        generation == requestGeneration
    }

    private func recordClearIfCurrent(_ requestGeneration: UInt64) {
        guard generation == requestGeneration else { return }
        clearRequired = false
        lastPublished = nil
    }

    private func recordPublishCompletion(
        _ requestGeneration: UInt64,
        owner publishedOwner: NokoActivityOwner,
        activity: NokoActivity
    ) {
        guard generation == requestGeneration else {
            // The SDK did publish this stale value, so the previously cached
            // value no longer describes Discord's state. Force the next
            // request to reach the transport even if it matches that old cache.
            lastPublished = nil
            return
        }
        lastPublished = (publishedOwner, activity)
    }
}

/// Serializes async transport calls, including while the bridge actor is
/// reentrant awaiting an SDK callback.
private actor NokoActivityOperationQueue {
    private var tail: Task<Void, Never>?

    func run<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let previous = tail
        let current = Task<Result, any Error> {
            await previous?.value
            return try await operation()
        }
        tail = Task {
            _ = try? await current.value
        }
        return try await current.value
    }
}
