import AppKit
import Foundation

public struct CommandClause: Codable, Equatable {
    public let text: String
    public let startUTF16: Int
    public let endUTF16: Int

    func modelText(in source: String) -> String {
        SensitiveText.redact(source, range: NSRange(location: startUTF16, length: endUTF16 - startUTF16))
    }
}

public struct WorkflowEvent: Codable {
    public let clause: CommandClause
    public let action: String
    public let before: String
    public let after: String
    public var outcome: String
    public let selectionSeconds: Double
    public let verificationSeconds: Double
    public var requests: Int
    public var captureSeconds: Double = 0
    public var selectionDetails: String? = nil
    public var inputTokens: Int? = nil
    public var modelSeconds: Double? = nil
    public var preparationSeconds: Double? = nil
    public var recoveryReads: Int? = nil
}

public struct WorkflowResult: Codable {
    public let command: String
    public let status: String
    public let complete: Bool
    public let events: [WorkflowEvent]
    public let elapsed: Double
    public var usage: ModelUsage? = nil
    public var requests: Int { usage?.requests ?? events.reduce(0) { $0 + $1.requests } }
    public var inputTokens: Int? {
        if let usage { return usage.inputTokens }
        guard events.allSatisfy({ $0.inputTokens != nil }) else { return nil }
        return events.reduce(0) { $0 + ($1.inputTokens ?? 0) }
    }
}

struct OutcomeJudgment {
    let id: String?
    let requests: Int
    let elapsed: TimeInterval
}

extension CommandEngine {
    static func failureStatus(_ error: Error, didDispatch: Bool) -> String {
        "Stopped: \(error.localizedDescription) " + (didDispatch
            ? "Input was dispatched; some effects may be partial or unconfirmed. Check the app before repeating."
            : "No input was sent for this attempt.")
    }

    /// Advance only through semantically selected source intervals after verified completion.
    public func runWorkflow(
        _ command: String, preparedFirst: PreparedAction? = nil,
        checkpoint supplied: WorkflowCheckpoint? = nil
    ) async throws -> WorkflowResult {
        let checkpoint = supplied ?? WorkflowCheckpoint(source: command)
        guard checkpoint.source == command else { throw JevFailure.invalid("Checkpoint source mismatch.") }
        try checkpoint.authorize(inputPermit)
        let started = Date()
        let usageStart = selector.usage.snapshot
        if checkpoint.read().pending != nil, !(try await reconcile(checkpoint)) {
            let status = "Earlier input remains unconfirmed. No replay was sent."
            checkpoint.update(generation: inputPermit.generation) {
                $0.executionStatus = "stopped"
                $0.lastStopReason = status
            }
            return WorkflowResult(command: command,
                status: status, complete: false, events: [],
                elapsed: Date().timeIntervalSince(started), usage: selector.usage.snapshot.since(usageStart))
        }
        let prior = checkpoint.read()
        // Speculative preparation is reusable only for a fresh replacement.
        // Resumed work must pass its historical binding through fresh selection.
        let usePreparedFirst =
            prior.cursor == 0 && prior.active == nil && prior.pending == nil && prior.observed == nil
            && prior.noInputReference == nil && preparedFirst?.interpretation?.source == command
            && preparedFirst?.interpretation?.clause.startUTF16 == 0
        checkpoint.update(generation: inputPermit.generation) {
            $0.executionStatus = "running"
            if usePreparedFirst, let preparedFirst { $0.referenceContext = preparedFirst.referenceContext }
        }
        let resume = checkpoint.read()
        let dispatchStart = inputPermit.dispatchCount
        var events: [WorkflowEvent] = []
        var measureCurrentStep: (() -> Void)?
        var current: AXSnapshot?
        var expectedPID: pid_t? = (resume.noInputBinding ?? resume.observed)?.pid
        func result(_ status: String, _ complete: Bool) -> WorkflowResult {
            measureCurrentStep?()  // Flush the current step before copying events into the result.
            checkpoint.update(generation: inputPermit.generation) {
                $0.executionStatus = complete ? "completed" : "stopped"
                $0.lastStopReason = complete ? "" : status
            }
            return WorkflowResult(
                command: command, status: status, complete: complete, events: events,
                elapsed: Date().timeIntervalSince(started),
                usage: selector.usage.snapshot.since(usageStart).adding(
                    usePreparedFirst ? preparedFirst?.usage ?? ModelUsage() : ModelUsage()))
        }
        var cursor = resume.cursor
        var completed = resume.verified.count
        var verifiedProgress = resume.verified
        do {
            while cursor < (command as NSString).length {
                try inputPermit.check()
                guard completed < 32 else { return result("Stopped at the instruction limit.", false) }
                let initial: PreparedAction
                if usePreparedFirst, cursor == 0, let preparedFirst, preparedFirst.interpretation?.source == command,
                    preparedFirst.interpretation?.clause.startUTF16 == 0
                {
                    initial = preparedFirst
                } else {
                    initial = try await prepare(
                        command, from: cursor, observation: current,
                        progress: resume.backgroundProgress + verifiedProgress,
                        revisions: checkpoint.read().revisions[cursor, default: []],
                        conversationContext: resume.referenceContext,
                        continuation: cursor == resume.cursor ? (resume.noInputBinding ?? resume.observed) : nil,
                        activatedApps: checkpoint.read().activatedApps)
                }
                guard let interpretation = initial.interpretation, interpretation.clause.endUTF16 > cursor else {
                    return result("No valid instruction boundary was selected.", false)
                }
                let clause = interpretation.clause
                checkpoint.update(generation: inputPermit.generation) { $0.active = clause }
                var history = cursor == resume.cursor ? resume.history : []
                var excluded = cursor == resume.cursor ? resume.excluded : Set<String>()
                var satisfied = false
                var retriedSatisfaction = false
                var satisfactionReferenceEvidence: String?
                var recoveredBeforeDispatch = false
                var recoveryBinding = checkpoint.read().noInputBinding
                for attempt in 0..<6 {
                    let attemptStart = Date()
                    let prepared: PreparedAction
                    if attempt == 0 {
                        prepared = initial
                    } else {
                        prepared = try await prepare(
                            command, from: cursor, observation: current,
                            progress: resume.backgroundProgress + verifiedProgress + history, excluded: excluded,
                            interpretation: interpretation, revisions: checkpoint.read().revisions[cursor, default: []],
                            conversationContext: resume.referenceContext, continuation: recoveryBinding,
                            activatedApps: checkpoint.read().activatedApps)
                    }
                    try inputPermit.check()
                    let prepareStart =
                        attempt == 0 ? Date().addingTimeInterval(-prepared.preparationSeconds) : attemptStart
                    let eventStart = events.count
                    let verificationUsageStart = selector.usage.snapshot
                    var verificationModelSeconds = 0.0
                    measureCurrentStep = {
                        let usage = prepared.usage.adding(selector.usage.snapshot.since(verificationUsageStart))
                        for index in eventStart..<events.count {
                            events[index].requests = usage.requests
                            events[index].inputTokens = usage.inputTokens
                            events[index].modelSeconds = prepared.modelSeconds + verificationModelSeconds
                            events[index].captureSeconds = prepared.captureSeconds
                            events[index].preparationSeconds = prepared.preparationSeconds
                            events[index].recoveryReads = prepared.recoveryReads
                        }
                    }
                    defer {
                        measureCurrentStep?()
                        measureCurrentStep = nil
                    }
                    if let expectedPID, let observed = prepared.snapshot, observed.pid != expectedPID {
                        return result("The target application changed. Stopped before input.", false)
                    }
                    if prepared.interpretation?.actionID == "already_satisfied", let before = prepared.snapshot {
                        if satisfactionReferenceEvidence == nil {
                            // Persist before the fresh read: errors/cancellation can stop
                            // this run, but a later resume still refers to this object.
                            let reference = checkpoint.read().noInputBinding ?? before
                            checkpoint.update(generation: inputPermit.generation) {
                                if $0.noInputBinding == nil {
                                    $0.noInputReference = NoInputReference(startUTF16: cursor, snapshot: reference)
                                }
                            }
                            if recoveryBinding == nil { recoveryBinding = reference }
                            let evidence = reference.evidence
                            satisfactionReferenceEvidence =
                                "Original observation before no-input confirmation; historical object reference only, not proof of current completion:\n"
                                + String(evidence.prefix(6_000))
                                + (evidence.count > 6_000
                                    ? "\nOriginal observation truncated; missing evidence is unknown." : "")
                        }
                        let verifyStart = Date()
                        let confirmation = try await confirmSatisfied(
                            before: before,
                            goal: clause.modelText(in: command) + Self.revisionContext(checkpoint.read().revisions[cursor, default: []]),
                            history: history, referenceContext: checkpoint.read().verificationContext,
                            beforeEvidence: satisfactionReferenceEvidence)
                        let fresh = confirmation.snapshot
                        let judgment = confirmation.judgment
                        verificationModelSeconds = judgment.elapsed
                        let complete = judgment.id == "complete"
                        events.append(
                            WorkflowEvent(
                                clause: clause, action: "Already satisfied — no input", before: before.evidence,
                                after: fresh.evidence, outcome: complete ? "complete" : "unknown",
                                selectionSeconds: verifyStart.timeIntervalSince(prepareStart),
                                verificationSeconds: Date().timeIntervalSince(verifyStart),
                                requests: prepared.requests + judgment.requests,
                                selectionDetails: "Judge=\(judgment.id ?? "none"); evidence:\n" + confirmation.evidence)
                        )
                        if !complete {
                            guard !retriedSatisfaction else {
                                return result("Current state did not confirm completion. Stopped without sending another action.", false)
                            }
                            retriedSatisfaction = true
                            if recoveryBinding == nil { recoveryBinding = before }
                            current = fresh
                            history.append(
                                "The proposed already-satisfied state was not confirmed by a fresh read. No input was sent. Select from this refreshed observation for the same instruction."
                            )
                            continue
                        }
                        current = fresh
                        expectedPID = fresh.pid
                        satisfied = true
                        break
                    }
                    guard prepared.launch != nil || prepared.candidate != nil || prepared.navigation != nil else {
                        events.append(
                            WorkflowEvent(
                                clause: clause, action: "No input",
                                before: prepared.snapshot?.evidence ?? prepared.observation,
                                after: "", outcome: prepared.emptyStatus,
                                selectionSeconds: Date().timeIntervalSince(prepareStart),
                                verificationSeconds: 0, requests: prepared.requests,
                                selectionDetails: prepared.observation))
                        return result(prepared.emptyStatus, false)
                    }
                    if let url = prepared.navigation {
                        checkpoint.update(generation: inputPermit.generation) {
                            $0.pending = PendingInstruction(
                                clause: clause, prepared: prepared, dispatchCount: inputPermit.dispatchCount)
                        }
                        guard let browser = prepared.navigationBrowser else {
                            return result("No browser was selected and none is registered for HTTPS.", false)
                        }
                        let navigation = try await navigate(
                            url, browser: browser, prepared: prepared,
                            clause: clause, prepareStart: prepareStart)
                        current = navigation.snapshot
                        expectedPID = navigation.pid
                        verificationModelSeconds = navigation.modelSeconds
                        events.append(navigation.event)
                        guard navigation.verified else {
                            return result("Navigation requested; the destination document is not yet observed.", false)
                        }
                        satisfied = true
                        break
                    }
                    let before = prepared.snapshot
                    // App launches are independently verified by the workspace's foreground PID.
                    if let launch = prepared.launch {
                        checkpoint.update(generation: inputPermit.generation) {
                            $0.pending = PendingInstruction(
                                clause: clause, prepared: prepared, dispatchCount: inputPermit.dispatchCount)
                        }
                        let activation = try await activate(
                            launch, prepared: prepared, clause: clause,
                            prepareStart: prepareStart, referenceContext: checkpoint.read().verificationContext)
                        verificationModelSeconds = activation.modelSeconds
                        events.append(activation.event)
                        guard activation.verified else {
                            return result("Application activation was not verified.", false)
                        }
                        checkpoint.update(generation: inputPermit.generation) {
                            $0.pending = nil
                            $0.observed = nil
                        }
                        expectedPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
                        current = nil
                        if !activation.complete {
                            history.append(
                                "The target application \(launch.name) is now foreground. Activation is only a prerequisite; the instruction remains unfinished."
                            )
                            checkpoint.update(generation: inputPermit.generation) {
                                $0.history = history
                                $0.activatedApps.insert(launch.bundleID)
                            }
                            continue
                        }
                        satisfied = true
                        break
                    }
                    guard let before, let candidate = prepared.candidate else {
                        return result("No observed target.", false)
                    }
                    expectedPID = before.pid
                    try inputPermit.check()
                    let valueAlreadyPresent = prepared.literal.map { literal in
                        let node = before.nodes[candidate.nodeID]
                        return candidate.operation == .replaceText && node.value == literal ||
                            candidate.operation == .setNumber && Self.numericTargetMatches(node.value, literal: literal, node: node)
                    } ?? false
                    if valueAlreadyPresent {
                        events.append(WorkflowEvent(
                            clause: clause, action: "No input — requested value already present",
                            before: before.evidence, after: before.evidence,
                            outcome: "Value observed; selecting the next action",
                            selectionSeconds: Date().timeIntervalSince(prepareStart), verificationSeconds: 0,
                            requests: prepared.requests))
                        excluded.insert(candidate.description)
                        history.append("The selected control already has the requested value. No input was sent. This proves only the value; select a next action or verify the whole goal and intended object.")
                        current = before
                        checkpoint.update(generation: inputPermit.generation) {
                            $0.history = history
                            $0.excluded = excluded
                        }
                        continue
                    }
                    let eventIndex = events.count
                    events.append(
                        WorkflowEvent(
                            clause: clause, action: candidate.description, before: before.evidence,
                            after: "", outcome: "Input intended; outcome unknown until observed",
                            selectionSeconds: Date().timeIntervalSince(prepareStart), verificationSeconds: 0,
                            requests: prepared.requests, selectionDetails: prepared.observation))
                    // Verification must use the exact candidate and observation dispatched.
                    // A stale target stops here instead of secretly replacing that binding.
                    checkpoint.update(generation: inputPermit.generation) {
                        $0.pending = PendingInstruction(
                            clause: clause, prepared: prepared, dispatchCount: inputPermit.dispatchCount)
                    }
                    let dispatchCount = inputPermit.dispatchCount
                    let receipt: String
                    do { receipt = try await executePrepared(prepared) } catch {
                        try inputPermit.check()
                        guard !recoveredBeforeDispatch,
                            inputPermit.dispatchCount == dispatchCount
                        else { throw error }
                        recoveredBeforeDispatch = true
                        let fresh = try await readObservation(.recovery(before.pid))
                        guard fresh.canObserveAfter(before, foregroundPID: observationForegroundPID()) else { throw AXFailure.changed }
                        // A menu-only startup had no document window to preserve. Bind its
                        // first foreground window now; later recovery must retain it.
                        recoveryBinding = before.isMenuOnly && fresh.windowHandle != nil ? fresh : before
                        current = fresh
                        history.append(
                            "The selected operation failed preflight; no input was dispatched. The old target is invalid. Original selected target: \(candidate.description). Re-establish that intended item or a permitted fresh named target from the original instruction."
                        )
                        events[eventIndex] = WorkflowEvent(
                            clause: clause, action: candidate.description,
                            before: before.evidence, after: fresh.evidence,
                            outcome: "notDispatched; refreshed for reselection",
                            selectionSeconds: Date().timeIntervalSince(prepareStart), verificationSeconds: 0,
                            requests: prepared.requests, selectionDetails: error.localizedDescription)
                        checkpoint.update(generation: inputPermit.generation) {
                            $0.pending = nil
                            $0.observed = fresh
                            $0.history = history
                        }
                        continue
                    }
                    events[eventIndex].selectionDetails = prepared.observation + "\n" + receipt
                    let selectionSeconds = Date().timeIntervalSince(prepareStart)
                    let verifyStart = Date()
                    let verification = try await verifyControl(
                        prepared, before: before, candidate: candidate,
                        goal: clause.modelText(in: command) + Self.revisionContext(checkpoint.read().revisions[cursor, default: []]),
                        history: history, referenceContext: checkpoint.read().verificationContext)
                    let after = verification.after
                    let verdict = verification.verdict
                    verificationModelSeconds += verification.modelSeconds
                    events[eventIndex] = WorkflowEvent(
                        clause: clause, action: candidate.description, before: before.evidence,
                        after: after.evidence, outcome: verdict, selectionSeconds: selectionSeconds,
                        verificationSeconds: Date().timeIntervalSince(verifyStart), requests: prepared.requests,
                        captureSeconds: before.readSeconds, selectionDetails: prepared.observation + "\n" + receipt)
                    current = after
                    checkpoint.update(generation: inputPermit.generation) { $0.observed = after }
                    if verdict == "complete" {
                        satisfied = true
                        break
                    }
                    guard verdict == "progress" else {
                        return result(
                            verdict == "contradicted"
                                ? "Observed result conflicts with the request. Stopped without replaying input."
                                : "Action sent; its outcome is still unknown. Stopped without replaying it.", false)
                    }
                    excluded.removeAll()
                    history.append(
                        "Observed intermediate progress after \(candidate.description). This effect is resolved. Choose a new intentional action for the remaining goal from the current state.\n"
                            + after.verificationEvidence(from: before, target: candidate, limit: 2_000))
                    if candidate.operation == .replaceText, prepared.literal != nil {
                        history.append(
                            "Verified exact field readback after replacement: \(prepared.interpretation?.modelValue ?? "[private value]"). The previous field value was replaced, not retained. This establishes the field value only; check the remaining required effects."
                        )
                    }
                    checkpoint.update(generation: inputPermit.generation) {
                        $0.pending = nil
                        $0.history = history
                        $0.excluded = excluded

                    }
                }
                guard satisfied else {
                    return result("The step needs further interaction; stopped at the action limit.", false)
                }
                checkpoint.update(generation: inputPermit.generation) {
                    $0.finishClause(clause, source: command, observed: current)
                    // The checkpoint owns completion; the loop reads back its progress.
                    cursor = $0.cursor
                    completed = $0.verified.count
                    verifiedProgress = $0.verified
                }
            }
        } catch {
            let status = Self.failureStatus(error, didDispatch:
                inputPermit.dispatchCount > dispatchStart || checkpoint.read().pending?.wasDispatched == true)
            if let last = events.last, last.outcome == "Input intended; outcome unknown until observed" {
                events[events.count - 1].outcome = status
            }
            return result(
                error is CancellationError
                    ? "Superseded by a newer request. Earlier input remains subject to observation."
                    : status, false)
        }
        return result(completed == 0 ? "No command." : "Completed and observed.", completed > 0)
    }

    /// Dispatch navigation once, then observe the destination without replaying input.
    private func navigate(
        _ url: URL, browser: InstalledApplication, prepared: PreparedAction,
        clause: CommandClause, prepareStart: Date
    ) async throws
        -> (snapshot: AXSnapshot?, pid: pid_t, verified: Bool, modelSeconds: Double, event: WorkflowEvent)
    {
        let pid = try await openURL(url, browser: browser)
        let sent = Date()
        var current: AXSnapshot?
        var verified = false
        var lastEvidence: String?
        var modelSeconds = 0.0
        for _ in 0..<15 {
            let snapshot = try await observeAfterInput(pid: pid)
            current = snapshot
            verified = snapshot.bundleID == browser.bundleID && snapshot.observesDestination(url)
            if verified { break }
            let evidence = snapshot.destinationEvidence
            if !verified, snapshot.bundleID == browser.bundleID, evidence != lastEvidence {
                lastEvidence = evidence
                let answer = try await destinationJudgment(url, snapshot: snapshot)
                modelSeconds += answer.elapsed
                verified = answer.id == "complete"
            }
            if verified { break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        let event = WorkflowEvent(
            clause: clause, action: "Visit \(url.absoluteString)", before: prepared.observation,
            after: current?.evidence ?? "No browser observation yet.", outcome: verified ? "complete" : "unknown",
            selectionSeconds: sent.timeIntervalSince(prepareStart),
            verificationSeconds: Date().timeIntervalSince(sent), requests: prepared.requests)
        return (current, pid, verified, modelSeconds, event)
    }

    func destinationJudgment(_ url: URL, snapshot: AXSnapshot) async throws -> OutcomeJudgment {
        if snapshot.observesDestination(url) { return OutcomeJudgment(id: "complete", requests: 0, elapsed: 0) }
        let evidence = snapshot.destinationEvidence
        guard !evidence.isEmpty else { return OutcomeJudgment(id: nil, requests: 0, elapsed: 0) }
        return try await judgeOutcome(goal: url.absoluteString,
            evidence: evidence,
            options: [JevOption(id: "complete", description: LanguagePrompts.text("verify_complete")),
                      JevOption(id: "pending", description: LanguagePrompts.text("verify_pending"))],
            instructions: LanguagePrompts.text("verify_destination"))
    }

    /// Foregrounding can be the endpoint or a prerequisite; Jev decides from the original goal.
    private func activate(
        _ launch: InstalledApplication, prepared: PreparedAction,
        clause: CommandClause, prepareStart: Date, referenceContext: [String: Any]
    ) async throws
        -> (verified: Bool, complete: Bool, modelSeconds: Double, event: WorkflowEvent)
    {
        let verified = try await AppRouting.activate(launch, permit: inputPermit)
        let verifyStart = Date()
        var complete = false
        var modelSeconds = 0.0
        var requests = prepared.requests
        if verified {
            let judgment = try await activationJudgment(
                appName: launch.name, goal: prepared.interpretation.map { clause.modelText(in: $0.source) } ?? SensitiveText.redact(clause.text), referenceContext: referenceContext)
            try inputPermit.check()
            complete = judgment.id == "complete"
            modelSeconds = judgment.elapsed
            requests += judgment.requests
        }
        let event = WorkflowEvent(
            clause: clause, action: "Open \(launch.name)",
            before: prepared.observation, after: "Foreground verified=\(verified)",
            outcome: verified ? (complete ? "complete" : "progress") : "unknown",
            selectionSeconds: verifyStart.timeIntervalSince(prepareStart),
            verificationSeconds: Date().timeIntervalSince(verifyStart), requests: requests)
        return (verified, complete, modelSeconds, event)
    }

    private func confirmSatisfied(
        before: AXSnapshot, goal: String, history: [String],
        referenceContext: [String: Any], beforeEvidence: String?
    ) async throws
        -> (snapshot: AXSnapshot, evidence: String, judgment: OutcomeJudgment)
    {
        let fresh = try await observeAfterInput(pid: before.pid, boundTo: before)
        guard fresh.sameWindow(as: before) else {
            throw AXFailure.unavailable(
                "Window binding changed during confirmation: \(before.windowTitle) → \(fresh.windowTitle)."
            )
        }
        let evidence = fresh.verificationEvidence()
        let judgment = try await judgeOutcome(
            goal: goal, evidence: evidence,
            options: [
                JevOption(
                    id: "complete",
                    description: "Positive current evidence establishes the requested state; no input needed."),
                JevOption(id: "pending", description: "The requested state is not positively established."),
            ],
            instructions: LanguagePrompts.text("verify_satisfied"), history: history, checkObject: true,
            referenceContext: referenceContext, beforeEvidence: beforeEvidence)
        return (fresh, evidence, judgment)
    }

    private func verifyControl(
        _ prepared: PreparedAction, before: AXSnapshot, candidate: AXCandidate,
        goal: String, history: [String], referenceContext: [String: Any]
    ) async throws -> (after: AXSnapshot, verdict: String, modelSeconds: Double) {
        // An action may open a new window. Observe it without authorizing input;
        // the outcome and object judgments must establish the transition first.
        var after = try await observeAfterInput(pid: before.pid)
        var verdict = "pending"
        var modelSeconds = 0.0
        var lastJudged: String?
        for check in 0..<5 {
            let evidence = after.verificationEvidence(from: before, target: candidate)
            // Judge the first fresh observation even when a display summary is unchanged.
            // Subsequent identical evidence cannot add information.
            if evidence != lastJudged {
                lastJudged = evidence
                let judgment = try await judgeControlOutcome(prepared, before: before, after: after,
                    goal: goal, history: history, referenceContext: referenceContext)
                modelSeconds += judgment.elapsed
                verdict = judgment.id ?? "pending"
            }
            if verdict != "pending" { break }
            if check < 4 {
                try await Task.sleep(nanoseconds: UInt64(min(1.5, 0.2 * pow(2, Double(check))) * 1_000_000_000))
                after = try await observeAfterInput(pid: before.pid)
            }
        }
        return (after, verdict, modelSeconds)
    }

    /// Operation readback is evidence for the same whole-goal judgment on live and resumed paths.
    func judgeControlOutcome(_ prepared: PreparedAction, before: AXSnapshot, after: AXSnapshot,
                             goal: String, history: [String], referenceContext: [String: Any]) async throws -> OutcomeJudgment {
        guard let candidate = prepared.candidate else { throw AXFailure.changed }
        var evidence = "DISPATCHED (not proof): \(candidate.description)\n" + after.verificationEvidence(from: before, target: candidate)
        var windowFacts: [String: Bool] = ["same_native_window": after.sameWindow(as: before)]
        if let current = after.windowHandle, let previous = before.applicationWindows {
            windowFacts["current_window_existed_before_action"] = previous.contains { CFEqual($0, current) }
        }
        var numericMatched: Bool?
        if candidate.operation == .setNumber {
            numericMatched = prepared.literal.flatMap { literal in
                after.valueForSameControl(candidate, from: before).map {
                    Self.numericTargetMatches($0, literal: literal, node: before.nodes[candidate.nodeID])
                }
            } ?? false
            evidence += "\nExact numeric readback on the same native control matches requested value: \(numericMatched!). This establishes only the setting, not other required effects or semantic target identity."
        }
        let answer = try await judgeOutcome(goal: goal, evidence: evidence,
            options: ["complete", "progress", "contradicted", "pending"].map {
                JevOption(id: $0, description: LanguagePrompts.text("verify_" + $0))
            },
            instructions: LanguagePrompts.text("verify"),
            action: ["operation": candidate.operation.rawValue, "target": candidate.description,
                     "source_value": prepared.interpretation?.modelValue ?? ""],
            history: history, checkObject: true, referenceContext: referenceContext, windowFacts: windowFacts)
        if numericMatched == false && answer.id == "complete" ||
            answer.id == "progress" && !after.hasObservedChange(from: before) {
            return OutcomeJudgment(id: nil, requests: answer.requests, elapsed: answer.elapsed)
        }
        return answer
    }

    static func revisionContext(_ revisions: [String]) -> String {
        revisions.isEmpty
            ? ""
            : "\nUser revisions to this instruction (latest overrides conflicting earlier values):\n"
                + revisions.joined(separator: "\n")
    }

    func activationJudgment(appName: String, goal: String, referenceContext: [String: Any]) async throws -> OutcomeJudgment {
        try await judgeOutcome(
            goal: goal,
            evidence: "Observed foreground application: \(appName). No document, item, setting, or content change has been established.",
            options: [
                JevOption(id: "complete", description: "The instruction only requests this application in the foreground; that is now observed."),
                JevOption(id: "progress", description: "The instruction requires interaction inside the application; foregrounding is only a prerequisite."),
            ],
            instructions: LanguagePrompts.text("verify_activation"), referenceContext: referenceContext)
    }

    func judgeOutcome(
        goal: String, evidence: String, options: [JevOption], instructions: String, action: [String: String] = [:],
        history: [String] = [], checkObject: Bool = false, referenceContext: [String: Any] = [:],
        beforeEvidence: String? = nil, windowFacts: [String: Bool] = [:]
    ) async throws -> OutcomeJudgment {
        let started = Date()
        var questions = [
            JevQuestion(
                instructions: instructions, options: options,
                noneDescription: "The evidence is insufficient to determine the observed outcome; keep it unknown.",
                key: "outcome")
        ]
        if checkObject {
            questions.append(
                JevQuestion(
                    instructions: LanguagePrompts.text("verify_object"),
                    options: [
                        JevOption(
                            id: "same_intended_object",
                            description:
                                "The observed result applies to the intended object, preserving the prior object when required or using the explicitly requested new one."
                        ),
                        JevOption(
                            id: "wrong_object",
                            description: "The observed result applies to a different object than intended."),
                        JevOption(id: "unknown", description: "Insufficient relevant identity evidence."),
                    ], key: "object"))
            if options.contains(where: { $0.id == "progress" }) {
                questions.append(JevQuestion(instructions: LanguagePrompts.text("verify_progress_effect"),
                    options: ["resolved", "conflicting", "unknown"].map {
                        JevOption(id: $0, description: LanguagePrompts.text("progress_effect_" + $0))
                    }, key: "progress_effect"))
            }
        }
        var state: [String: Any] = [
            "user_goal": goal, "observed_evidence": evidence, "attempted_action": action,
            "instruction_history": history, "reference_context": referenceContext,
        ]
        if let beforeEvidence { state["before_evidence"] = beforeEvidence }
        if !windowFacts.isEmpty { state["native_window_facts"] = windowFacts }
        let judgment = try await selector.judge(state: state, questions: questions)
        var outcome = judgment.answer("outcome")
        // Completion requires both endpoint and object identity. Intermediate
        // prerequisites may act on a search field before the final object exists.
        if checkObject, outcome == "complete", judgment.answer("object") != "same_intended_object" {
            outcome =
                judgment.answer("object") == "wrong_object" && options.contains { $0.id == "contradicted" }
                ? "contradicted" : nil
        }
        if checkObject, outcome == "progress", judgment.answer("progress_effect") != "resolved" {
            outcome = judgment.answer("progress_effect") == "conflicting" ? "contradicted" : nil
        }
        return OutcomeJudgment(
            id: outcome, requests: judgment.requests,
            elapsed: Date().timeIntervalSince(started))
    }

    static func numericTargetMatches(_ value: String, literal: String, node: AXNode) -> Bool {
        guard let observed = Double(value), observed.isFinite,
            let numeric = Double(literal.replacingOccurrences(of: "%", with: "")), numeric.isFinite,
            let low = node.minimum, let high = node.maximum, low.isFinite, high.isFinite, high > low
        else { return false }
        let expected = literal.contains("%") ? low + (high - low) * numeric / 100 : numeric
        return (low...high).contains(expected) && abs(observed - expected) <= max(0.00001, (high - low) * 0.001)
    }

    private func observeAfterInput(pid: pid_t, boundTo before: AXSnapshot? = nil) async throws -> AXSnapshot {
        try await Task.sleep(nanoseconds: 60_000_000)
        try inputPermit.check()
        let snapshot = try await readObservation(.verification(pid))
        try inputPermit.check()
        guard snapshot.pid == pid, observationForegroundPID() == pid else {
            throw AXFailure.unavailable("The target app changed after input; outcome unknown.")
        }
        if let before, !snapshot.canObserveAfter(before, foregroundPID: observationForegroundPID()) {
            throw AXFailure.unavailable("The target window changed after input; outcome unknown. No input replayed.")
        }
        return snapshot
    }

    @MainActor private func openURL(_ url: URL, browser: InstalledApplication) async throws -> pid_t {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            let lease: InputLease
            do { lease = try inputPermit.begin() } catch {
                continuation.resume(throwing: error)
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: browser.url, configuration: configuration) { app, error in
                defer { lease.finish() }
                if let error {
                    continuation.resume(throwing: error)
                } else if let app {
                    continuation.resume(returning: app)
                } else {
                    continuation.resume(
                        throwing: AXFailure.unavailable("Browser launch did not return an application."))
                }
            }
        }
        return app.processIdentifier
    }
}
