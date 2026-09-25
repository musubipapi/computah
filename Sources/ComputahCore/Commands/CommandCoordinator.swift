import Foundation

public enum CommandTurnOutcome: String, Codable { case completed, cancelled, unconfirmed, superseded }

public struct CommandTurnResult: Codable {
    public let turnID: String
    public let outcome: CommandTurnOutcome
    public let status: String
    public init(turnID: String, outcome: CommandTurnOutcome, status: String) {
        self.turnID = turnID; self.outcome = outcome; self.status = status
    }
}

/// One active goal and one newest turn. Semantic append is explicit; submissions
/// are never placed into an automatic FIFO.
@MainActor public final class CommandCoordinator {
    public var onStatus: ((String, Bool) -> Void)?
    public var onRelationship: ((GoalRelationship) -> Void)?
    public var inputAudit: [InputAuditEvent] { gate.events() }
    public var inputEffectCount: Int { gate.effectCount }
    public var droppedInputAuditEvents: Int { gate.droppedAuditEvents }
    public var beforeObservation: ((InputPermit) async throws -> Void)?
    public var onTurnStarted: ((String) -> Void)?
    public var onTurnFinished: ((CommandTurnResult) -> Void)?
    private var activeSubmission: String?
    public var onResult: ((WorkflowResult, Bool) -> Void)?
    public private(set) var running = false
    private var engine: CommandEngine
    private let gate: InputGate
    private var permit: InputPermit
    private var task: Task<Void, Never>?
    private var checkpoint: WorkflowCheckpoint?
    private var turnID: String?
    // SpeechTurnIdentity rejects older provider turns before they reach this API.
    // Keep a bounded duplicate-final window for current speech/typed submissions.
    private var finalized: [String] = []
    private var eager: Task<PreparedAction, Error>?
    private var eagerText: String?
    private var unresolved: [String] = []

    public init(engine: CommandEngine, auditLimit: Int = 0) {
        self.gate = InputGate(auditLimit: auditLimit)
        self.engine = engine
        self.permit = gate.revoke()
    }

    /// A transport event suspends old authority without inferring semantic intent.
    public func beginTurn(_ id: String) {
        guard turnID != id, !finalized.contains(id) else { return }
        finishTurn(.superseded, status: "A newer input turn suspended this request.")
        turnID = id
        engine.selector.usage = ModelUsageTracker()
        discardEager()
        permit = gate.revoke()
        try? checkpoint?.authorize(permit)
        task?.cancel()
        running = false
        onStatus?("Listening to the new request…", false)
    }

    private func prepareFresh(
        _ text: String, ticket: InputPermit, relationship: [String: Any]?, conversation: [String: Any]
    ) async throws -> PreparedAction {
        var runner = engine
        runner.inputPermit = ticket
        try await beforeObservation?(ticket)
        return try await runner.prepare(
            text, from: 0, relationshipContext: relationship, conversationContext: conversation)
    }

    public func discardEager() {
        eager?.cancel(); eager = nil; eagerText = nil
    }

    public func prepareEager(_ text: String, turn id: String) {
        beginTurn(id)
        guard !finalized.contains(id), eagerText != text else { return }
        discardEager()
        eagerText = text
        let ticket = permit
        let prior = checkpoint
        let relationship = relationshipContext(prior)
        let conversation = conversationContext(prior)
        eager = Task {
            await gate.drain()
            try ticket.check()
            return try await prepareFresh(text, ticket: ticket, relationship: relationship, conversation: conversation)
        }
    }

    public func submit(_ original: String, turn id: String = UUID().uuidString) {
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !finalized.contains(id) else { return }
        beginTurn(id)
        finalized.append(id)
        if finalized.count > 128 { finalized.removeFirst() }
        let ready = eagerText == text ? eager : nil
        if ready == nil { discardEager() } else { eager = nil; eagerText = nil }
        let ticket = permit
        let prior = checkpoint
        let relationship = relationshipContext(prior)
        let conversation = conversationContext(prior)
        unresolved = Array((unresolved + [text]).suffix(8))
        var runner = engine
        runner.inputPermit = ticket
        activeSubmission = id
        onTurnStarted?(id)
        running = true
        onStatus?("Finding an action…", true)
        task = Task { [weak self] in
            guard let self else { return }
            let start = Date()
            @MainActor func report(_ result: WorkflowResult, current: Bool) {
                // Include final-turn planning and reconciliation, not just the
                // workflow that consumes an already prepared first action.
                onResult?(WorkflowResult(command: result.command, status: result.status, complete: result.complete,
                    events: result.events, elapsed: Date().timeIntervalSince(start), usage: runner.selector.usage.snapshot), current)
            }
            do {
                await gate.drain()
                try ticket.check()
                let initial: PreparedAction
                if let ready {
                    initial = try await withTaskCancellationHandler { try await ready.value } onCancel: { ready.cancel() }
                } else {
                    initial = try await prepareFresh(text, ticket: ticket, relationship: relationship, conversation: conversation)
                }
                var prepared = initial
                try ticket.check()
                var relationship = prepared.interpretation?.relationship ?? .replace
                if let prior, [.resume, .revise, .append].contains(relationship) {
                    let cursor = prior.read().cursor
                    try prior.authorize(ticket)
                    guard try await runner.reconcile(prior) else {
                        publish("The earlier action's result is still unknown. I need that resolved before continuing it.", ticket: ticket)
                        return
                    }
                    if relationship == .revise, prior.read().cursor != cursor {
                        // The old effect completed before interruption. It is immutable history;
                        // re-judge the follow-up against the newly observed progress.
                        prepared = try await runner.prepare(text, from: 0,
                            relationshipContext: relationshipContext(prior), conversationContext: conversationContext(prior))
                        relationship = prepared.interpretation?.relationship ?? .unclear
                    }
                }
                try ticket.check()
                if relationship == .replace, prepared.interpretation?.route == nil, !prepared.hasExecutablePlan {
                    // An unclear fragment must not retire the last useful checkpoint.
                    // A clear semantic route with a missing target is still a new
                    // goal and must replace old work. No command wording is tested.
                    let result = try await runner.runWorkflow(text, preparedFirst: prepared)
                    report(result, current: true)
                    publish(result.status, ticket: ticket, outcome: result.complete ? .completed : .unconfirmed)
                    return
                }
                onRelationship?(relationship)
                switch relationship {
                case .cancel:
                    checkpoint = nil
                    unresolved.removeAll()
                    publish("Stopped the previous task.", ticket: ticket, outcome: .cancelled)
                    return
                case .unclear:
                    publish("I’m paused. Should this replace the previous task or change it?", ticket: ticket)
                    return
                case .replace:
                    checkpoint = WorkflowCheckpoint(source: text)
                case .resume, .revise, .append:
                    guard let prior else {
                        publish("There is no previous instruction to continue. Please state the next action.", ticket: ticket)
                        return
                    }
                    checkpoint = prior
                    try prior.authorize(ticket)
                    if relationship == .revise {
                        prior.update(generation: ticket.generation) { $0.revisions[$0.cursor, default: []].append(text) }
                    } else if relationship == .append {
                        guard let start = prepared.interpretation?.followupStartUTF16 else {
                            publish("The added instruction's source boundary is unclear.", ticket: ticket)
                            return
                        }
                        prior.update(generation: ticket.generation) { $0.followups.append(FollowupInstruction(source: text, startUTF16: start)) }
                    }
                }
                // Reconciliation may have completed the prior instruction. Running its
                // checkpoint then sends no input, reports completion for resume, and
                // advances to the exact validated source span for append.
                unresolved.removeAll()
                guard var active = checkpoint else { return }
                var first: PreparedAction? = relationship == .replace ? prepared : nil
                while true {
                    try ticket.check()
                    let result = try await runner.runWorkflow(active.source, preparedFirst: first, checkpoint: active)
                    let current = (try? ticket.check()) != nil
                    report(result, current: current)
                    guard current else { return }
                    guard result.complete else { publish(result.status, ticket: ticket, outcome: result.complete ? .completed : .unconfirmed); return }
                    let followups = active.read().followups
                    guard let next = followups.first else { publish(result.status, ticket: ticket, outcome: result.complete ? .completed : .unconfirmed); return }
                    let new = WorkflowCheckpoint(source: next.source)
                    try new.authorize(ticket)
                    let priorProgress = active.read().backgroundProgress + ["The preceding request completed: " + active.source] + active.read().verified
                    new.update(generation: ticket.generation) {
                        $0.cursor = next.startUTF16
                        $0.followups = Array(followups.dropFirst())
                        $0.backgroundProgress = priorProgress
                        $0.referenceContext = self.conversationContext(active)
                    }
                    checkpoint = new
                    active = new
                    first = nil
                }
            } catch {
                guard (try? ticket.check()) != nil else { return }
                let status = CommandEngine.failureStatus(error, didDispatch:
                    ticket.dispatchCount > 0 || self.checkpoint?.read().pending?.wasDispatched == true)
                onResult?(WorkflowResult(command: text, status: status, complete: false, events: [],
                                         elapsed: Date().timeIntervalSince(start), usage: runner.selector.usage.snapshot), true)
                publish(status, ticket: ticket)
            }
        }
    }

    private func relationshipContext(_ prior: WorkflowCheckpoint?) -> [String: Any]? {
        guard let prior else { return nil }
        let state = prior.read()
        guard state.cursor < (prior.source as NSString).length || state.pending != nil else { return nil }
        var context = prior.semanticState
        context["unresolved_newer_utterances"] = unresolved
        return context
    }

    private func conversationContext(_ prior: WorkflowCheckpoint?) -> [String: Any] {
        var context: [String: Any] = ["unresolved_utterances": unresolved]
        if let prior, prior.read().cursor >= (prior.source as NSString).length, prior.read().pending == nil {
            context["completed_request"] = prior.source
            context["observed_result"] = prior.read().observed.map { AXReader.clipped($0.selectionEvidence, 4_000) } ?? "Unknown"
        }
        return context
    }

    private func finishTurn(_ outcome: CommandTurnOutcome, status: String) {
        guard let id = activeSubmission else { return }
        activeSubmission = nil
        onTurnFinished?(CommandTurnResult(turnID: id, outcome: outcome, status: status))
    }

    private func publish(_ message: String, ticket: InputPermit, outcome: CommandTurnOutcome = .unconfirmed) {
        guard (try? ticket.check()) != nil else { return }
        running = false
        finishTurn(outcome, status: message)
        onStatus?(message, false)
    }

    public func shutdown() {
        finishTurn(.superseded, status: "Execution stopped during shutdown.")
        permit = gate.revoke()
        try? checkpoint?.authorize(permit)
        task?.cancel()
        discardEager()
    }
}

extension CommandEngine {
    /// Resolve only a previously dispatched effect. Never redispatch to learn its result.
    func reconcile(_ checkpoint: WorkflowCheckpoint) async throws -> Bool {
        guard let pending = checkpoint.read().pending else { return true }
        guard pending.wasDispatched else {
            checkpoint.update(generation: inputPermit.generation) { $0.pending = nil }
            return true
        }
        try inputPermit.check()
        let fresh = try await readObservation(.initial)
        let prepared = pending.prepared
        let verdict: String
        if let app = prepared.launch {
            guard fresh.bundleID == app.bundleID else { return false }
            let answer = try await activationJudgment(
                appName: app.name, goal: pending.clause.modelText(in: checkpoint.source), referenceContext: checkpoint.read().verificationContext)
            verdict = answer.id ?? "unknown"
        } else if let url = prepared.navigation {
            guard let browser = prepared.navigationBrowser,
                  fresh.bundleID == browser.bundleID else { return false }
            verdict = try await destinationJudgment(url, snapshot: fresh).id ?? "unknown"
        } else if let before = prepared.snapshot, prepared.candidate != nil {
            guard fresh.pid == before.pid, observationForegroundPID() == before.pid else { return false }
            let answer = try await judgeControlOutcome(prepared, before: before, after: fresh,
                goal: pending.clause.modelText(in: checkpoint.source) + Self.revisionContext(checkpoint.read().revisions[pending.clause.startUTF16, default: []]),
                history: checkpoint.read().history, referenceContext: checkpoint.read().verificationContext)
            verdict = answer.id ?? "unknown"
        } else { return false }
        try inputPermit.check()
        guard verdict == "complete" || verdict == "progress" else { return false }
        checkpoint.update(generation: inputPermit.generation) { state in
            state.pending = nil
            state.observed = fresh
            if verdict == "complete" {
                state.finishClause(pending.clause, source: checkpoint.source, observed: fresh)
            } else {
                if let app = prepared.launch { state.activatedApps.insert(app.bundleID) }
                state.excluded.removeAll()
                var progress = "The interrupted action has now been observed as intermediate progress. Its effect is resolved; choose a new intentional action for the remaining goal."
                if let before = prepared.snapshot, let candidate = prepared.candidate {
                    progress += "\n" + fresh.verificationEvidence(from: before, target: candidate, limit: 2_000)
                }
                state.history.append(progress)
            }
        }
        return true
    }
}
