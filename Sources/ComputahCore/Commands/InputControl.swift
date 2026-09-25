import Foundation

/// One input lane. Revocation and admission share a lock; in-flight work drains
/// without holding that lock, so a new utterance can revoke authority promptly.
public struct InputAuditEvent: Codable, Sendable {
    public let generation: UUID
    public let event: String
    public let at: Date
}

public final class InputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    private var audit: [InputAuditEvent] = []
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let auditLimit: Int
    private var dropped = 0
    private var effects = 0

    /// Routine operation retains no audit trail. Explicit diagnostics may keep a bounded tail.
    public init(auditLimit: Int = 0) { self.auditLimit = max(0, auditLimit) }

    private func record(_ event: InputAuditEvent) {
        guard auditLimit > 0 else { return }
        if audit.count == auditLimit {
            audit.removeFirst()
            dropped += 1
        }
        audit.append(event)
    }

    public var effectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return effects
    }

    public var droppedAuditEvents: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    @discardableResult public func revoke() -> InputPermit {
        lock.lock()
        generation = UUID()
        let id = generation
        record(InputAuditEvent(generation: id, event: "revokedPrevious", at: Date()))
        lock.unlock()
        return InputPermit(gate: self, generation: id, counter: InputCounter())
    }

    fileprivate func check(_ id: UUID) throws {
        lock.lock()
        let valid = generation == id
        lock.unlock()
        guard valid else { throw CancellationError() }
    }

    fileprivate func begin(_ id: UUID, counter: InputCounter, effect: Bool) throws -> InputLease {
        try Task.checkCancellation()
        lock.lock()
        defer { lock.unlock() }
        guard generation == id else { throw CancellationError() }
        guard inFlight == 0 else { throw AXFailure.unavailable("Another native input is still finishing.") }
        inFlight += 1
        record(InputAuditEvent(generation: id, event: effect ? "admittedEffect" : "admittedPointerMove", at: Date()))
        if effect {
            counter.value += 1
            effects += 1
        }
        return InputLease(gate: self)
    }

    fileprivate func end() {
        lock.lock()
        inFlight -= 1
        let ready = inFlight == 0 ? waiters : []
        if inFlight == 0 { waiters.removeAll() }
        lock.unlock()
        for waiter in ready { waiter.resume() }
    }

    fileprivate func count(_ counter: InputCounter) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counter.value
    }

    public func events() -> [InputAuditEvent] {
        lock.lock()
        defer { lock.unlock() }
        return audit
    }

    /// Only waits for a native transaction, never for a model request or workflow.
    public func drain() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if inFlight == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

public final class InputLease: @unchecked Sendable {
    private let gate: InputGate
    private let lock = NSLock()
    private var finished = false
    fileprivate init(gate: InputGate) { self.gate = gate }
    public func finish() {
        lock.lock()
        let needsFinish = !finished
        finished = true
        lock.unlock()
        if needsFinish { gate.end() }
    }
    deinit { finish() }
}

// Owned by permit copies and pending effects, never retained by the gate.
// Access is synchronized by that permit's gate lock.
private final class InputCounter: @unchecked Sendable { var value = 0 }

public struct InputPermit: Sendable {
    fileprivate let gate: InputGate
    public let generation: UUID
    fileprivate let counter: InputCounter
    public static func standalone() -> InputPermit { InputGate().revoke() }
    public var dispatchCount: Int { gate.count(counter) }
    public func check() throws {
        try Task.checkCancellation()
        try gate.check(generation)
    }
    public func begin(effect: Bool = true) throws -> InputLease {
        try gate.begin(generation, counter: counter, effect: effect)
    }
    public func perform<T>(effect: Bool = true, _ operation: () throws -> T) throws -> T {
        let lease = try begin(effect: effect)
        defer { lease.finish() }
        return try operation()
    }
    /// Once down is sent, up is mandatory even if revocation occurs during hold.
    func pair(down: () -> Void, up: () -> Void, hold: () -> Void = {}) throws {
        try perform {
            down()
            defer { up() }
            hold()
        }
    }
}

func cancellableNative<T>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let worker = Task.detached(priority: .userInitiated, operation: operation)
    return try await withTaskCancellationHandler {
        try await worker.value
    } onCancel: {
        worker.cancel()
    }
}
