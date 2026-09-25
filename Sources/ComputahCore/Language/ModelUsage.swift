import Foundation

/// Attempts are counted at the HTTP boundary. Missing provider usage stays unknown.
public struct ModelUsage: Codable, Equatable, Sendable {
    public var requests = 0
    public var reportedInputTokens = 0
    public var requestsWithoutTokenUsage = 0
    public var inputTokens: Int? { requestsWithoutTokenUsage == 0 ? reportedInputTokens : nil }

    func adding(_ other: ModelUsage) -> ModelUsage {
        ModelUsage(
            requests: requests + other.requests,
            reportedInputTokens: reportedInputTokens + other.reportedInputTokens,
            requestsWithoutTokenUsage: requestsWithoutTokenUsage + other.requestsWithoutTokenUsage)
    }

    func since(_ earlier: ModelUsage) -> ModelUsage {
        ModelUsage(
            requests: requests - earlier.requests,
            reportedInputTokens: reportedInputTokens - earlier.reportedInputTokens,
            requestsWithoutTokenUsage: max(0, requestsWithoutTokenUsage - earlier.requestsWithoutTokenUsage))
    }
}

final class ModelUsageTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var usage = ModelUsage()
    var snapshot: ModelUsage {
        lock.lock()
        defer { lock.unlock() }
        return usage
    }
    func beginRequest() {
        lock.lock()
        defer { lock.unlock() }
        usage.requests += 1
        usage.requestsWithoutTokenUsage += 1
    }
    func received(inputTokens: Int?) {
        guard let inputTokens, inputTokens >= 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        usage.reportedInputTokens += inputTokens
        usage.requestsWithoutTokenUsage -= 1
    }
}
