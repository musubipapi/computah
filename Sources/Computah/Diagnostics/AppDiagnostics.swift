import AppKit
import ApplicationServices
import ComputahCore

private let diagnosticTimeoutNanoseconds: UInt64 = 90_000_000_000

extension App {
    func startDiagnosticIfRequested() -> Bool {
        if let argument = LaunchOptions.current.value("--trace-dir") {
            engine.selector.traceDirectory = URL(fileURLWithPath: argument)
        }
        if let argument = LaunchOptions.current.value("--initial-nodes"),
            let nodes = Int(argument)
        {
            engine.useDiagnosticInitialNodeLimit(nodes)
        }
        if LaunchOptions.current.contains("--physical-activation") { engine.useDiagnosticPhysicalActivation() }
        if LaunchOptions.current.contains("--native-activation") { engine.useDiagnosticNativeActivation() }
        if let argument = LaunchOptions.current.value("--scenario") {
            runScenario(URL(fileURLWithPath: argument))
            return true
        }
        if let argument = LaunchOptions.current.value("--audio-pcm") {
            runAudioDiagnostic(URL(fileURLWithPath: argument))
            return true
        }
        if let argument = LaunchOptions.current.value("--command") {
            let command = argument
            var submitted = false
            coordinator.onResult = { result, current in
                guard current else { return }
                self.finishDiagnostic(result, outcome: result.complete ? .completed : .unconfirmed)
            }
            coordinator.onStatus = { message, active in
                // Some semantic outcomes (cancel or unclear) stop without a workflow result.
                guard submitted && !active else { return }
                self.finishDiagnostic(["command": command, "status": message], outcome: .unconfirmed)
            }
            let turnID = UUID().uuidString
            recordInput(command, source: .commandLine, turnID: turnID)
            coordinator.submit(command, turn: turnID)
            submitted = true
            Task {
                try? await Task.sleep(nanoseconds: diagnosticTimeoutNanoseconds)
                self.finishDiagnostic(
                    ["command": command], outcome: .timedOut,
                    error: "Command timed out; completion unproven.")
            }
            return true
        }
        return false
    }

    func runAudioDiagnostic(_ file: URL) {
        do {
            let pcm = try Data(contentsOf: file)
            guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 16_000 * 2 * 60 else {
                throw AXFailure.unavailable("Audio diagnostic requires at most 60 seconds of raw 16 kHz mono PCM16.")
            }
            guard let key = credential("DEEPGRAM_API_KEY"), !key.isEmpty, !key.contains("\n") else {
                throw AXFailure.unavailable("Missing Deepgram credential.")
            }
            let started = Date()
            var results: [WorkflowResult] = []
            var turns = DiagnosticTurns()
            coordinator.onTurnStarted = { turns.begin($0) }
            coordinator.onTurnFinished = { turns.finish($0) }
            var speech: [[String: Any]] = []
            var statuses: [ScenarioStatus] = []
            var finalTurns = Set<String>()
            var inputFinished = false
            var finished = false
            var starting = true
            func save(_ error: String? = nil, timedOut: Bool = false) {
                guard !finished else { return }
                finished = true
                let report = ScenarioReport(
                    results: results, statuses: statuses, relationships: [],
                    inputAudit: coordinator.inputAudit, elapsed: Date().timeIntervalSince(started),
                    droppedAuditEvents: coordinator.droppedInputAuditEvents, turns: turns.results)
                finishDiagnostic(
                    report,
                    outcome: diagnosticOutcome(timedOut: timedOut, failed: error != nil, turns: turns),
                    error: error,
                    additional: [
                        "speechEvents": speech,
                        "audioSeconds": Double(pcm.count) / 32_000, "inputFinished": inputFinished,
                    ])
            }
            func finishIfReady() {
                if inputFinished && !finalTurns.isEmpty && turns.count >= finalTurns.count && turns.resolved && turns.results.last?.outcome != .superseded && !coordinator.running {
                    save()
                }
            }
            voice.onProviderEvent = { payload in
                speech.append(["seconds": Date().timeIntervalSince(started), "payload": payload])
            }
            voice.onDiagnosticInputFinished = {
                inputFinished = true
                finishIfReady()
            }
            connectVoiceCallbacks(source: .suppliedAudio, status: { message in
                statuses.append(
                    ScenarioStatus(
                        seconds: Date().timeIntervalSince(started), message: message, running: self.coordinator.running)
                )
                if !finished && !self.voice.isListening && !starting { save(message) }
            })
            let forwardText = voice.onText
            voice.onText = { text, final, turnID in
                // Count accepted final turns, not raw provider events rejected by speech identity.
                if final && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { finalTurns.insert(turnID) }
                forwardText?(text, final, turnID)
                finishIfReady()
            }
            coordinator.onResult = { result, _ in results.append(result) }
            coordinator.onStatus = { message, active in
                statuses.append(
                    ScenarioStatus(seconds: Date().timeIntervalSince(started), message: message, running: active))
                if !active { finishIfReady() }
            }
            voice.start(key: key, diagnosticPCM: pcm)
            starting = false
            Task {
                try? await Task.sleep(nanoseconds: diagnosticTimeoutNanoseconds)
                if !finished { save("Audio diagnostic timed out; completion unproven.", timedOut: true) }
            }
        } catch {
            failDiagnostic(error)
        }
    }

    struct ScenarioStep: Codable {
        let afterMilliseconds: Int
        let command: String
        let afterEffects: Int?
        let afterResults: Int?
        let afterIdle: Bool?
    }
    struct ScenarioStatus: Codable {
        let seconds: Double
        let message: String
        let running: Bool
    }
    struct ScenarioReport: Codable {
        let results: [WorkflowResult]
        let statuses: [ScenarioStatus]
        let relationships: [GoalRelationship]
        let inputAudit: [InputAuditEvent]
        let elapsed: Double
        let droppedAuditEvents: Int
        let turns: [CommandTurnResult]
    }
    func diagnosticOutcome(timedOut: Bool, failed: Bool = false, turns: DiagnosticTurns) -> DiagnosticOutcome {
        if timedOut { return .timedOut }
        if failed { return .failed }
        return turns.confirmed ? .completed : .unconfirmed
    }

    func runScenario(_ file: URL) {
        do {
            let steps = try JSONDecoder().decode([ScenarioStep].self, from: Data(contentsOf: file))
            guard !steps.isEmpty,
                steps.allSatisfy({
                    !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && (0...90_000).contains($0.afterMilliseconds) && ($0.afterEffects ?? 0) >= 0
                        && ($0.afterResults ?? 0) >= 0
                })
            else {
                throw AXFailure.unavailable(
                    "Scenario needs nonempty commands, delays from 0 to 90000 ms, and nonnegative counts.")
            }
            let started = Date()
            var results: [WorkflowResult] = []
            var turns = DiagnosticTurns()
            coordinator.onTurnStarted = { turns.begin($0) }
            coordinator.onTurnFinished = { turns.finish($0) }
            var statuses: [ScenarioStatus] = []
            var relationships: [GoalRelationship] = []
            var submittedAll = false
            var finished = false
            func save(timedOut: Bool = false) {
                guard !finished else { return }
                finished = true
                let report = ScenarioReport(
                    results: results, statuses: statuses, relationships: relationships,
                    inputAudit: coordinator.inputAudit, elapsed: Date().timeIntervalSince(started),
                    droppedAuditEvents: coordinator.droppedInputAuditEvents, turns: turns.results)
                finishDiagnostic(
                    report, outcome: diagnosticOutcome(timedOut: timedOut, turns: turns),
                    error: timedOut ? "Scenario timed out before all work was resolved." : nil)
            }
            coordinator.onResult = { result, _ in results.append(result) }
            coordinator.onRelationship = { relationships.append($0) }
            coordinator.onStatus = { message, active in
                statuses.append(
                    ScenarioStatus(seconds: Date().timeIntervalSince(started), message: message, running: active))
                if submittedAll && !active { save() }
            }
            Task {
                for (index, step) in steps.enumerated() {
                    // One submitted turn can report both reconciled prior work and
                    // its follow-up. Result count alone is not a sequential barrier.
                    if step.afterIdle == true {
                        while !finished && coordinator.running {
                            try? await Task.sleep(nanoseconds: 2_000_000)
                        }
                    }
                    if let count = step.afterResults {
                        while !finished && results.count < count {
                            try? await Task.sleep(nanoseconds: 2_000_000)
                        }
                    }
                    if let effects = step.afterEffects {
                        while !finished && coordinator.inputEffectCount < effects {
                            try? await Task.sleep(nanoseconds: 2_000_000)
                        }
                    }
                    if step.afterMilliseconds > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(step.afterMilliseconds) * 1_000_000)
                    }
                    guard !finished else { return }
                    let turnID = "scenario-\(index)"
                    recordInput(step.command, source: .scenario, turnID: turnID)
                    coordinator.submit(step.command, turn: turnID)
                    if index == steps.count - 1 { submittedAll = true }
                }
                if !coordinator.running { save() }
            }
            Task {
                try? await Task.sleep(nanoseconds: diagnosticTimeoutNanoseconds)
                save(timedOut: true)
            }
        } catch {
            failDiagnostic(error)
        }
    }

}

/// Workflow results are steps; this ledger accounts for every submitted input turn.
struct DiagnosticTurns {
    private var submitted: [String] = []
    private var outcomes: [String: CommandTurnResult] = [:]
    var count: Int { submitted.count }
    var results: [CommandTurnResult] { submitted.compactMap { outcomes[$0] } }
    var resolved: Bool { !submitted.isEmpty && submitted.allSatisfy { outcomes[$0] != nil } }
    var confirmed: Bool {
        resolved && results.allSatisfy { $0.outcome != .unconfirmed } &&
            [.completed, .cancelled].contains(results.last!.outcome)
    }
    mutating func begin(_ id: String) {
        if !submitted.contains(id) { submitted.append(id) }
    }
    mutating func finish(_ result: CommandTurnResult) {
        guard submitted.contains(result.turnID), outcomes[result.turnID] == nil else { return }
        outcomes[result.turnID] = result
    }
}
