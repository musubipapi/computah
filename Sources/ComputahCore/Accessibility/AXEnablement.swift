import Foundation

/// Successful setup belongs to one process lifetime, never to a recycled PID.
final class AXEnablement: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: [pid_t: Date] = [:]
    private var revision: UInt64 = 0
    private let capacity = 128

    func ensure(pid: pid_t, launchedAt: Date?, enable: () -> Bool) {
        lock.lock()
        let cached = launchedAt.map { enabled[pid] == $0 } ?? false
        let observedRevision = revision
        lock.unlock()
        guard !cached else { return }

        // A blocked native call must not serialize captures of unrelated apps.
        guard enable(), let launchedAt else { return }
        lock.lock()
        defer { lock.unlock() }
        // Recovery may have invalidated setup while the native call was blocked.
        guard revision == observedRevision else { return }
        enabled[pid] = launchedAt
        if enabled.count > capacity, let oldest = enabled.min(by: { $0.value < $1.value })?.key {
            enabled.removeValue(forKey: oldest)
        }
    }

    func invalidate(pid: pid_t) {
        lock.lock()
        enabled.removeValue(forKey: pid)
        revision &+= 1
        lock.unlock()
    }
}
