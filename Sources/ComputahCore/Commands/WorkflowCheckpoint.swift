import Foundation
import ApplicationServices

struct PendingInstruction {
    let clause: CommandClause
    let prepared: PreparedAction
    let dispatchCount: Int
    var wasDispatched: Bool { prepared.permit.dispatchCount > dispatchCount }
}

struct FollowupInstruction { let source: String; let startUTF16: Int }

/// Historical reference for an unfinished no-input claim, never current-state proof.
struct NoInputReference {
    let startUTF16: Int
    let snapshot: AXSnapshot
}

struct CheckpointState {
    var executionStatus = "planning"
    var lastStopReason = ""
    var backgroundProgress: [String] = []
    var followups: [FollowupInstruction] = []
    var revisions: [Int: [String]] = [:]
    var cursor = 0
    var verified: [String] = []
    var history: [String] = []
    var referenceContext: [String: Any] = [:]
    var activatedApps = Set<String>()
    var excluded = Set<String>()
    var active: CommandClause?
    var pending: PendingInstruction?
    var observed: AXSnapshot?
    var noInputReference: NoInputReference?

    var verificationContext: [String: Any] {
        var context = referenceContext
        context["verified_instructions"] = backgroundProgress + verified
        return context
    }

    var noInputBinding: AXSnapshot? {
        guard let noInputReference, noInputReference.startUTF16 == cursor else { return nil }
        return noInputReference.snapshot
    }

    private static func completionNote(_ clause: CommandClause, source: String) -> String {
        "Completed and observed source interval \(clause.startUTF16)..<\(clause.endUTF16): \(clause.modelText(in: source))"
    }

    mutating func finishClause(_ clause: CommandClause, source: String, observed: AXSnapshot?) {
        cursor = clause.endUTF16
        noInputReference = nil
        verified.append(Self.completionNote(clause, source: source))
        active = nil
        history = []
        excluded = []
        activatedApps = []
        pending = nil
        if let observed { self.observed = observed }
    }
}

/// Original source and observed progress survive task cancellation. This is not
/// a generated command rewrite, and dispatch alone never advances the cursor.
public final class WorkflowCheckpoint: @unchecked Sendable {
    public let source: String
    private let lock = NSLock()
    private var state = CheckpointState()
    private var generation: UUID?
    public init(source: String) { self.source = source }
    func read() -> CheckpointState {
        lock.lock(); defer { lock.unlock() }
        return state
    }
    func authorize(_ permit: InputPermit) throws {
        lock.lock(); defer { lock.unlock() }
        try permit.check()
        generation = permit.generation
    }
    func update(generation expected: UUID, _ body: (inout CheckpointState) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected else { return }
        body(&state)
    }
    var semanticState: [String: Any] {
        let value = read()
        return ["execution_status": value.executionStatus, "last_stop_reason": value.lastStopReason,
                "has_unfinished_work": value.cursor < (source as NSString).length,
                "phase": value.pending != nil ? "dispatched_or_pending" : value.active != nil ? "active_clause" : "between_clauses",
                "previous_request": source,
                "remaining_request": SensitiveText.redact(source, range: NSRange(location: value.cursor, length: (source as NSString).length - value.cursor)),
                "active_instruction": value.active?.modelText(in: source) ?? "",
                "revisions": value.revisions[value.cursor, default: []],
                "verified_progress": value.backgroundProgress + value.verified,
                "intermediate_progress": value.history,
                "pending_action": value.pending.map { ["action": $0.prepared.description ?? "", "dispatched": $0.wasDispatched,
                                                         "outcome": "unknown until observed"] as [String: Any] } ?? [:],
                "bound_scene": (value.noInputBinding ?? value.observed)?.selectionEvidence ?? "Unknown"]
    }
}
