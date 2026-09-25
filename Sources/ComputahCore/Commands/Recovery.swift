import Foundation

struct RecoveryResult {
    var snapshot: AXSnapshot
    var candidates: [AXCandidate]
    var interpretation: InterpretedCommand
    var reads = 0
    var captureSeconds = 0.0
    var modelSeconds = 0.0
}

extension CommandEngine {
    /// Separate candidate breadth from native read depth. No utterance filtering.
    func recover(_ source: String, offset: Int, interpretation: InterpretedCommand,
                 snapshot: AXSnapshot, primary: [AXCandidate], progress: [String],
                 excluded: Set<String>, revisions: [String], conversationContext: [String: Any] = [:],
                 continuation: AXSnapshot? = nil) async throws -> RecoveryResult {
        var result = RecoveryResult(snapshot: snapshot, candidates: primary, interpretation: interpretation)
        var observationBinding = snapshot
        let language = CommandLanguage(selector: selector)
        func candidates(_ scene: AXSnapshot, secondary: Bool = false) -> [AXCandidate] {
            availableCandidates(scene, excluded: excluded, includeSecondary: secondary)
        }
        func choose(_ choices: [AXCandidate], _ scene: AXSnapshot, stage: String) async throws {
            try inputPermit.check()
            let start = Date()
            let answer = try await language.interpret(source, from: offset, apps: [],
                progress: progress + ["Recovery scope: \(stage). Missing choices here do not prove global absence. Use a directly offered action when it advances the instruction."],
                controls: choices, observation: scene, fixedClause: interpretation.clause, revisions: revisions,
                conversationContext: conversationContext, continuation: continuation)
            result.modelSeconds += Date().timeIntervalSince(start)
            result.snapshot = scene; result.candidates = choices; result.interpretation = answer
        }
        func resolved() -> Bool {
            result.interpretation.route != .controls || result.interpretation.actionID == "already_satisfied" ||
                result.candidates.contains { $0.id == result.interpretation.actionID }
        }
        func read(_ request: ObservationRequest) async throws -> AXSnapshot {
            try inputPermit.check()
            let start = Date()
            let scene = try await readObservation(request)
            result.captureSeconds += Date().timeIntervalSince(start); result.reads += 1
            guard scene.canObserveAfter(observationBinding, foregroundPID: observationForegroundPID()) else { throw AXFailure.changed }
            if observationBinding.isMenuOnly, scene.windowHandle != nil { observationBinding = scene }
            return scene
        }
        // An abstention from an unfinished traversal is not evidence of absence.
        // Broaden once directly instead of asking the model to infer capture mechanics.
        if interpretation.actionID == nil, snapshot.unfinishedVisibleRead {
            let expanded = try await read(.expanded(snapshot.pid))
            try await choose(candidates(expanded), expanded, stage: "one completed broader read after primary traversal ran out of budget")
            return result
        }
        let primaryIDs = Set(primary.map(\.id))
        let secondary = candidates(snapshot, secondary: true).filter { !primaryIDs.contains($0.id) }
        // 255 Choice slots minus no-match and three no-input outcomes.
        if interpretation.actionID == "inspect_secondary", !secondary.isEmpty && secondary.count <= 251 {
            try await choose(secondary, snapshot, stage: "new capabilities already captured; no native reread")
            if resolved() { return result }
        } else if interpretation.actionID == "inspect_secondary", secondary.count > 251 {
            let byRegion = Dictionary(grouping: candidates(snapshot, secondary: true), by: \.groupID)
            let owners = byRegion.keys.sorted()
            let options = owners.map { id -> JevOption in
                let node = snapshot.nodes[id]
                let members = byRegion[id, default: []]
                let examples = members.prefix(4).map(\.description).joined(separator: "; ")
                return JevOption(id: "region\(id)", description: "\(node.role): \(node.label); \(members.count) capabilities; examples: \(examples)")
            } + [JevOption(id: "fresh_visible", description: "No observed region has sufficient relevant evidence; read the current visible surface again.")]
            let start = Date()
            let answer = try await selector.judge(state: ["instruction": interpretation.clause.modelText(in: source),
                "revisions": revisions, "scene": snapshot.selectionEvidence, "verified_progress": progress, "reference_context": conversationContext],
                questions: [JevQuestion(instructions: LanguagePrompts.text("recovery_region"), options: options)])
            result.modelSeconds += Date().timeIntervalSince(start)
            if let owner = owners.first(where: { "region\($0)" == answer.ids.first.flatMap({ $0 }) }) {
                try await choose(byRegion[owner, default: []], snapshot, stage: "one observed structural region")
                if resolved() { return result }
                let region = try await read(.region(snapshot, owner))
                try await choose(candidates(region), region, stage: "fresh bounded region; primary controls")
                if resolved() { return result }
            }
        }
        // Refresh primary controls before adding any further secondary options.
        let fresh = try await read(.recovery(snapshot.pid))
        try await choose(candidates(fresh), fresh, stage: "fresh visible surface; primary controls")
        if resolved() { return result }
        if fresh.unfinishedVisibleRead {
            let expanded = try await read(.expanded(snapshot.pid))
            try await choose(candidates(expanded), expanded, stage: "one broader bounded fallback; primary controls only")
        }
        return result
    }
}
