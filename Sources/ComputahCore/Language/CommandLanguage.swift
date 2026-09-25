import Foundation

/// Meaning lives in prompt resources; code retains source spans and validates typed answers.
enum LanguagePrompts {
    private struct Document: Decodable {
        let shared: [String: String]
        let prompts: [String: String]
    }
    static let values: [String: String] = {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Computah_ComputahCore.bundle")
        let bundle = packaged.flatMap { Bundle(url: $0) } ?? Bundle.module
        guard let url = bundle.url(forResource: "language", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else {
            preconditionFailure("Missing language prompt resource")
        }
        precondition(document.shared.values.allSatisfy { !$0.contains("{{") }, "Prompt fragments cannot nest")
        return document.prompts.mapValues { template in
            let expanded = document.shared.reduce(template) { text, fragment in
                text.replacingOccurrences(of: "{{" + fragment.key + "}}", with: fragment.value)
            }
            precondition(!expanded.contains("{{"), "Unknown prompt fragment")
            return expanded
        }
    }()
    static func text(_ key: String) -> String {
        guard let value = values[key] else { preconditionFailure("Missing prompt: \(key)") }
        return value
    }
}

struct SourceToken {
    let text: String
    let range: NSRange
    let modelText: String

    static func read(_ source: String, from offset: Int = 0) throws -> [SourceToken] {
        let ns = source as NSString
        guard offset >= 0, offset <= ns.length,
              Range(NSRange(location: offset, length: ns.length - offset), in: source) != nil else {
            throw JevFailure.invalid("Invalid source boundary.")
        }
        // Lexical positions only. No command verbs, sentence splitting or quote interpretation.
        let regex = try NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+|[^\s]"#)
        let protected = SensitiveText.protectedRanges(in: source)
        return regex.matches(in: source, range: NSRange(location: offset, length: ns.length - offset)).map {
            match in
            let text = ns.substring(with: match.range)
            return SourceToken(text: text, range: match.range,
                modelText: protected.contains { NSIntersectionRange($0, match.range).length > 0 }
                    ? "[REDACTED CREDENTIAL]" : text)
        }
    }
}

public enum GoalRelationship: String, Codable, CaseIterable { case replace, revise, resume, append, cancel, unclear }

enum CommandRoute: String { case application, navigation, controls }
enum ValueFormat: String, CaseIterable { case absent, literal, address, number, percent }

struct InterpretedCommand {
    let source: String
    let clause: CommandClause
    let route: CommandRoute?
    let app: InstalledApplication?
    let format: ValueFormat
    let valueRange: NSRange?
    var value: String?
    var followupStartUTF16: Int? = nil
    var relationship: GoalRelationship? = nil
    var valueSource: String? = nil
    var actionID: String? = nil
    var activatesApp: Bool = false
    var valueIsNormalized: Bool = true

    var canType: Bool { format == .literal || format == .address }
    var canSetNumber: Bool { format == .number || format == .percent }

    var modelValue: String? {
        guard let value, let valueRange else { return value }
        let original = valueSource ?? source
        return SensitiveText.protectedRanges(in: original).contains { NSIntersectionRange($0, valueRange).length > 0 }
            ? SensitiveText.redact(original, range: valueRange) : value
    }
}

private struct ValueSelection {
    var format: String?
    var first: String?
    var last: String?
    init() {}
    init(_ judgments: JevJudgments) {
        format = judgments.answer("format")
        first = judgments.answer("value_start")
        last = judgments.answer("value_end")
    }
}

struct CommandLanguage {
    let selector: JevSelector

    func interpret(_ source: String, from offset: Int = 0, apps: [InstalledApplication],
                   progress: [String] = [], controls: [AXCandidate] = [],
                   observation: AXSnapshot? = nil, fixedClause: CommandClause? = nil,
                   revisions: [String] = [], relationshipContext: [String: Any]? = nil, conversationContext: [String: Any] = [:], continuation: AXSnapshot? = nil) async throws -> InterpretedCommand {
        if let fixedClause {
            guard fixedClause.startUTF16 == offset, fixedClause.endUTF16 <= (source as NSString).length,
                  fixedClause.endUTF16 > offset,
                  (source as NSString).substring(with: NSRange(location: offset, length: fixedClause.endUTF16 - offset)) == fixedClause.text else {
                throw JevFailure.invalid("Invalid active source binding.")
            }
        }
        let tokens = try SourceToken.read(source, from: offset).filter { fixedClause == nil || NSMaxRange($0.range) <= fixedClause!.endUTF16 }
        guard !tokens.isEmpty else { throw JevFailure.invalid("No command.") }
        guard tokens.count <= 254 else {
            throw JevFailure.invalid("This utterance exceeds the source-selection limit. Please use a shorter request.")
        }
        let ns = source as NSString
        var state: [String: Any] = ["original_request": source, "consumed_utf16": offset,
            "verified_progress": progress,
            "remaining_request": SensitiveText.redact(source, range: NSRange(location: offset, length: (fixedClause?.endUTF16 ?? ns.length) - offset)),
            "source_tokens": tokens.enumerated().map { ["id": "t\($0.offset)", "text": $0.element.modelText,
                "start_utf16": $0.element.range.location, "end_utf16": NSMaxRange($0.element.range)] as [String: Any] }]
        if !conversationContext.isEmpty { state["conversation_context"] = conversationContext }
        var positions = tokens.enumerated().map {
            JevOption(id: "t\($0.offset)", description: "Source token \($0.offset): \($0.element.modelText)")
        }
        var valueTokens: [String: (source: String, sourceID: String, token: SourceToken, originalIndex: Int?)] = [:]
        for (index, token) in tokens.enumerated() { valueTokens["t\(index)"] = (source, "original", token, index) }
        var revisionState: [[String: Any]] = []
        for (revision, text) in revisions.enumerated() {
            let revisedTokens = try SourceToken.read(text)
            revisionState.append(["source_id": "revision\(revision)", "original_text": text,
                "tokens": revisedTokens.enumerated().map { ["id": "r\(revision)t\($0.offset)", "text": $0.element.modelText] }])
            for (index, token) in revisedTokens.enumerated() {
                let id = "r\(revision)t\(index)"
                positions.append(JevOption(id: id, description: "Revision \(revision) token \(index): \(token.modelText)"))
                valueTokens[id] = (text, "revision\(revision)", token, nil)
            }
        }
        guard positions.count <= 254 else { throw JevFailure.invalid("Source and revision spans exceed the selection limit.") }
        if !revisions.isEmpty { state["instruction_revisions"] = revisionState }
        let ends = tokens.indices.filter { fixedClause == nil || $0 == tokens.count - 1 }.map { index in
            JevOption(id: "t\(index)", description: "After token \(index): \(tokens[index].modelText)" +
                (index + 1 < tokens.count ? "; next: \(tokens[index + 1].modelText)" : "; end of request"))
        }
        func question(_ key: String, _ options: [JevOption]) -> JevQuestion {
            JevQuestion(instructions: (key == "action" ? "" : LanguagePrompts.text("premise") + "\n") + LanguagePrompts.text(key), options: options,
                        noneDescription: key == "action" ? LanguagePrompts.text("action_none") : nil,
                        optionBudget: key == "action" ? 64 : 254, key: key)
        }
        func valueQuestions() -> [JevQuestion] {
            [question("format", ValueFormat.allCases.map {
                JevOption(id: $0.rawValue, description: LanguagePrompts.text("format_" + $0.rawValue)) }),
             question("value_start", positions), question("value_end", positions)]
        }
        func operationOption(_ candidate: AXCandidate) -> JevOption {
            JevOption(id: candidate.id, description:
                (LanguagePrompts.values["operation_" + candidate.operation.rawValue].map { $0 + "\n" } ?? "") + candidate.description)
        }
        func controlFields(_ node: AXNode) -> [String: Any] {
            ["role": node.role, "label": node.label, "current_value": node.value, "focused": node.focused]
        }
        if let fixedClause { state["active_instruction"] = SensitiveText.redact(source, range: NSRange(location: fixedClause.startUTF16, length: fixedClause.endUTF16 - fixedClause.startUTF16)) }
        state["observed_scene"] = observation.map { $0.selectionEvidence } ?? "No AX observation available."
        if let observation {
            state["coverage"] = Dictionary(grouping: observation.coverage, by: { $0.reason.rawValue }).mapValues(\.count)
            let primaryIDs = Set(controls.map(\.id))
            let secondary = AXGrouping.candidates(in: observation, includeSecondary: true).filter { !primaryIDs.contains($0.id) }
            state["secondary_capabilities"] = Dictionary(grouping: secondary, by: \.groupID).keys.sorted().map { id in
                let members = secondary.filter { $0.groupID == id }
                return ["region": observation.nodes[id].label, "count": members.count,
                        "operations": Array(Set(members.map { $0.operation.rawValue })).sorted()] as [String: Any]
            }
        }
        let appOptions = apps.enumerated().map {
            JevOption(id: "app\($0.offset)", description: "Activate installed app: \($0.element.name); aliases=\(Set($0.element.aliases).subtracting([$0.element.name]).sorted().joined(separator: ", ")); bundle=\($0.element.bundleID)")
        }
        // Multiple operations on one native control are one target, not competing targets.
        let byNode = Dictionary(grouping: controls, by: \.nodeID)
        let targetGroups = Dictionary(uniqueKeysWithValues: byNode.values.filter { $0.count > 1 }.map { ("target_n\($0[0].nodeID)", $0) })
        var seenNodes = Set<Int>()
        let controlOptions = controls.compactMap { candidate -> JevOption? in
            guard seenNodes.insert(candidate.nodeID).inserted else { return nil }
            let members = byNode[candidate.nodeID]!
            if members.count == 1 { return JevOption(id: candidate.id, description: candidate.description) }
            return JevOption(id: "target_n\(candidate.nodeID)", description: "Interact with this observed control. Available operations: " + members.map(\.description).joined(separator: "; "))
        } + [
            JevOption(id: "inspect_secondary", description: LanguagePrompts.text("action_inspect_secondary")),
            JevOption(id: "reobserve", description: LanguagePrompts.text("action_reobserve")),
            JevOption(id: "already_satisfied", description: LanguagePrompts.text("action_already_satisfied"))]
        var questions = (fixedClause == nil ? [question("boundary", ends)] : []) + [
            question("route", [CommandRoute.application, .navigation, .controls].map {
                JevOption(id: $0.rawValue, description: LanguagePrompts.text("route_" + $0.rawValue)) }),
            ] + valueQuestions() + [
            question("application", appOptions.isEmpty ? [JevOption(id: "unavailable", description: "No application catalog available")] : appOptions),
            question("action", controlOptions)]
        let observedTargetIDs = Set(controls.map { byNode[$0.nodeID]!.count > 1 ? "target_n\($0.nodeID)" : $0.id })
        questions[questions.count - 1].observedControls = Dictionary(uniqueKeysWithValues:
            controlOptions.filter { observedTargetIDs.contains($0.id) }.map { ($0.id, $0.description) })
        // Bound speculative work by native target count, never by command text.
        // Other targets retain the selected-target follow-up below.
        var operationQuestions: [String: String] = [:]
        var operationTargets: [String: Any] = [:]
        for option in controlOptions.filter({ targetGroups[$0.id] != nil }).prefix(2) {
            guard let members = targetGroups[option.id], let first = members.first,
                  let observation, observation.nodes.indices.contains(first.nodeID) else { continue }
            let node = observation.nodes[first.nodeID]
            operationTargets[option.id] = [
                "selected_target": members.map(\.description),
                "selected_control": controlFields(node)]
            let premise = LanguagePrompts.text("operation_premise").replacingOccurrences(of: "{target}", with: option.id)
            operationQuestions[option.id] = "operation_" + option.id
            questions.append(JevQuestion(instructions: premise + "\n" + LanguagePrompts.text("operation"),
                options: members.map(operationOption), key: "operation_" + option.id))
        }
        if !operationTargets.isEmpty { state["operation_targets"] = operationTargets }
        var relationshipQuestions: [JevQuestion] = []
        if relationshipContext != nil {
            relationshipQuestions.append(JevQuestion(instructions: LanguagePrompts.text("relationship"),
                options: GoalRelationship.allCases.map { JevOption(id: $0.rawValue, description: LanguagePrompts.text("relationship_" + $0.rawValue)) }, key: "relationship"))
            relationshipQuestions.append(JevQuestion(instructions: LanguagePrompts.text("append_start"), options: tokens.enumerated().map {
                JevOption(id: "t\($0.offset)", description: "Start new work at source token \($0.offset): \($0.element.modelText)")
            }, key: "append_start"))
        }
        if let continuation {
            state["prior_binding"] = continuation.bindingEvidence
            state["current_binding"] = observation?.bindingEvidence ?? []
            questions.append(JevQuestion(instructions: LanguagePrompts.text("continuation_binding"),
                options: ["app_scope", "fresh_target", "same_document", "changed_or_unknown"].map {
                    JevOption(id: $0, description: LanguagePrompts.text("continuation_" + $0))
                }, key: "continuation_binding"))
        }
        // Isolate prior-goal context: a real trace selected the old app even after
        // correctly choosing replacement. Both independent requests start together.
        let relationState: [String: Any] = ["original_request": source,
            "source_tokens": state["source_tokens"] ?? [], "prior_goal": relationshipContext ?? [:],
            "observed_scene": observation?.selectionEvidence ?? "Unknown"]
        let actionRequest = Task { try await selector.judge(state: state, questions: questions) }
        defer { actionRequest.cancel() }
        let relationAnswers = try await selector.judge(state: relationState, questions: relationshipQuestions)
        let relationship = relationshipContext == nil ? nil : GoalRelationship(rawValue: relationAnswers.answer("relationship") ?? "unclear")
        func appendStart() async throws -> Int? {
            guard relationship == .append else { return nil }
            var answer = relationAnswers.answer("append_start")
            if answer == nil {
                var boundState = relationState
                boundState["selected_relationship"] = "append"
                let repair = try await selector.judge(state: boundState, questions: relationshipQuestions.filter { $0.key == "append_start" })
                answer = repair.answer("append_start")
            }
            guard let index = tokens.indices.first(where: { "t\($0)" == answer }) else {
                throw JevFailure.invalid("The added instruction's source boundary is unclear.")
            }
            return tokens[index].range.location
        }
        if let relationship, relationship != .replace {
            // Ignore failed speculative selection. Cancel and drain its URLSession
            // task before releasing this request's resources.
            actionRequest.cancel()
            _ = await actionRequest.result
            let end = fixedClause?.endUTF16 ?? ns.length
            let followupStart = try await appendStart()
            var result = InterpretedCommand(source: source,
                clause: CommandClause(text: ns.substring(with: NSRange(location: offset, length: end - offset)), startUTF16: offset, endUTF16: end),
                route: nil, app: nil, format: .absent, valueRange: nil, value: nil)
            result.relationship = relationship
            result.followupStartUTF16 = followupStart
            return result
        }
        let answers = try await withTaskCancellationHandler { try await actionRequest.value } onCancel: { actionRequest.cancel() }
        if continuation != nil, !["app_scope", "fresh_target", "same_document"].contains(answers.answer("continuation_binding") ?? "") {
            throw AXFailure.unavailable("The earlier document or item cannot be uniquely identified. Please identify the target before continuing.")
        }
        guard let endIndex = fixedClause == nil ? tokens.indices.first(where: { "t\($0)" == answers.answer("boundary") }) : tokens.indices.last else {
            throw JevFailure.invalid("The instruction boundary is unclear.")
        }
        let end = fixedClause?.endUTF16 ?? (endIndex + 1 < tokens.count ? tokens[endIndex + 1].range.location : ns.length)
        let clause = CommandClause(text: ns.substring(with: NSRange(location: offset, length: end - offset)),
                                   startUTF16: offset, endUTF16: end)
        let route = answers.answer("route").flatMap(CommandRoute.init(rawValue:))
        let appIndex = appOptions.firstIndex { $0.id == answers.answer("application") }
        let app = appIndex.map { apps[$0] }
        let needsActivation = route == .application || (route == .controls && app.map { target in
            observation.map { scene in
                scene.bundleID.map { $0 != target.bundleID } ?? (scene.appName != target.name)
            } ?? true
        } == true)
        var actionID: String? = route == nil ? nil : needsActivation ? appIndex.map { "app\($0)" } :
            route == .navigation ? "navigate" : answers.answer("action")
        var valueAnswers = ValueSelection(answers)
        var conditionalState = state
        conditionalState["active_instruction"] = SensitiveText.redact(source, range: NSRange(location: clause.startUTF16, length: clause.endUTF16 - clause.startUTF16))
        let selectedTarget = actionID
        if let targetID = actionID, let key = operationQuestions[targetID] {
            actionID = answers.answer(key)
            // Keep the first instruction's value answer, as for single-operation
            // targets. Resolve it again only if missing for the selected operation.
            if let target = operationTargets[targetID] as? [String: Any] {
                conditionalState["selected_control"] = target["selected_control"]
                conditionalState["selected_target"] = target["selected_target"]
            }
        } else if let members = actionID.flatMap({ targetGroups[$0] }) {
            conditionalState["selected_target"] = members.map(\.description)
            if let observation, let first = members.first, observation.nodes.indices.contains(first.nodeID) {
                let node = observation.nodes[first.nodeID]
                conditionalState["selected_control"] = controlFields(node)
            }
            let followup = try await selector.judge(state: conditionalState, questions: [
                JevQuestion(instructions: LanguagePrompts.text("operation"),
                    options: members.map(operationOption), key: "operation")] + valueQuestions())
            actionID = followup.answer("operation")
            valueAnswers = ValueSelection(followup)
        }
        // A selected target with no applicable operation is an inconsistent plan,
        // not proof that every other control is unsuitable. Reselect once from
        // concrete operations, excluding targets the operation judge rejected.
        if actionID == nil, let selectedTarget, let rejected = targetGroups[selectedTarget] {
            var rejectedNodes = Set(rejected.map(\.nodeID))
            for (target, key) in operationQuestions where answers.answer(key) == nil {
                rejectedNodes.formUnion(targetGroups[target, default: []].map(\.nodeID))
            }
            let alternatives = controls.filter { !rejectedNodes.contains($0.nodeID) }
            if !alternatives.isEmpty {
                conditionalState.removeValue(forKey: "selected_control")
                conditionalState.removeValue(forKey: "selected_target")
                conditionalState.removeValue(forKey: "operation_targets")
                let repaired = try await selector.judge(state: conditionalState, questions: [
                    question("action", alternatives.map { JevOption(id: $0.id, description: $0.description) })])
                actionID = repaired.answer("action")
                valueAnswers = ValueSelection()
            }
        }
        // Speculative value answers have no effect on inactive branches.
        var format: ValueFormat = .absent
        var valueRange: NSRange?
        var value: String?
        let selectedControl = controls.first { $0.id == actionID }
        let requiresValue = route == .navigation || selectedControl.map { [.typeText, .replaceText, .setNumber].contains($0.operation) } == true
        if requiresValue {
            if valueAnswers.format == nil || valueAnswers.format == ValueFormat.absent.rawValue {
                conditionalState["selected_target"] = selectedControl?.description ?? "Navigate to requested address"
                let resolved = try await selector.judge(state: conditionalState, questions: valueQuestions())
                valueAnswers = ValueSelection(resolved)
            }
            guard let raw = valueAnswers.format, let selected = ValueFormat(rawValue: raw) else {
                throw JevFailure.invalid("The instruction's value is unclear.")
            }
            format = selected
            if format != .absent {
                guard let firstID = valueAnswers.first, let lastID = valueAnswers.last,
                      let first = valueTokens[firstID], let last = valueTokens[lastID], first.source == last.source,
                      first.token.range.location <= last.token.range.location,
                      first.originalIndex.map({ $0 <= endIndex }) ?? true,
                      last.originalIndex.map({ $0 <= endIndex }) ?? true else {
                    throw JevFailure.invalid("The selected value crosses a source or instruction boundary.")
                }
                // IDs must belong to the same original/revision source even if texts happen to match.
                guard first.sourceID == last.sourceID else {
                    throw JevFailure.invalid("Value bounds belong to different source versions.")
                }
                let range = NSRange(location: first.token.range.location,
                                    length: NSMaxRange(last.token.range) - first.token.range.location)
                valueRange = range
                value = (first.source as NSString).substring(with: range)
            }
            guard route != .navigation || format == .address else {
                throw JevFailure.invalid("Navigation has no complete address.")
            }
        }
        var result = InterpretedCommand(source: source, clause: clause, route: route, app: app, format: format,
                                  valueRange: valueRange, value: value)
        result.relationship = relationship
        result.valueSource = valueAnswers.first.flatMap { valueTokens[$0]?.source }
        result.actionID = actionID
        result.activatesApp = needsActivation
        result.valueIsNormalized = format == .literal || format == .absent
        return result
    }

    func resolveValue(_ command: InterpretedCommand) async throws -> InterpretedCommand {
        guard !command.valueIsNormalized, let raw = command.value else { return command }
        if command.modelValue != raw {
            // Normalization would otherwise resend an isolated fragment without its
            // original credential marker. Only local, literal parsing is permitted.
            let locallyRepresentable = command.format == .address ? Self.validatedURL(raw) != nil :
                Double(raw).map(\.isFinite) == true
            guard locallyRepresentable else {
                throw JevFailure.invalid("A protected value needs a literal address or decimal representation before it can be used.")
            }
        }
        let normalized: String
        switch command.format {
        case .address: normalized = try await address(raw)
        case .number, .percent:
            let number = try await number(raw)
            normalized = number + (command.format == .percent ? "%" : "")
        case .literal, .absent: return command
        }
        var result = command
        result.value = normalized
        result.valueIsNormalized = true
        return result
    }

    func number(_ source: String, locales: [Locale] = [Locale.current, Locale(identifier: "en_US_POSIX")]) async throws -> String {
        if let value = Double(source), value.isFinite { return String(value) }
        var numbers: [Double] = []
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        for locale in locales {
            formatter.locale = locale
            if let value = formatter.number(from: source.lowercased(with: locale))?.doubleValue, value.isFinite, !numbers.contains(value) {
                numbers.append(value)
            }
        }
        if !numbers.isEmpty {
            let options = numbers.enumerated().map { JevOption(id: "v\($0.offset)", description: String($0.element)) }
            let result = try await selector.judge(state: ["value_source": source], questions: [
                JevQuestion(instructions: LanguagePrompts.text("number"), options: options, key: "number")])
            if let index = options.firstIndex(where: { $0.id == result.answer("number") }) {
                return String(numbers[index])
            }
        }
        throw JevFailure.invalid("The numeric expression could not be confirmed. Please state the value as a decimal number.")
    }

    private func address(_ source: String) async throws -> String {
        if Self.validatedURL(source) != nil { return source }
        let tokens = try SourceToken.read(source)
        let symbols = [".", "/", ":", "-", "_", "?", "=", "&", "#", "%", "+", "@", "~"]
        let options = [JevOption(id: "copy", description: "Copy this source token exactly")] +
            symbols.enumerated().map { JevOption(id: "s\($0.offset)", description: "Address punctuation: \($0.element)") }
        let questions = tokens.indices.map { index in
            JevQuestion(instructions: LanguagePrompts.text("address_symbol") + "\ntarget_token=\(index)", options: options, key: "address_\(index)")
        }
        let result = try await selector.judge(state: ["address_source": source,
            "tokens": tokens.enumerated().map { ["id": $0.offset, "text": $0.element.modelText] as [String: Any] }], questions: questions)
        var output = ""
        for (token, answer) in zip(tokens, result.ids) {
            if answer == "copy" { output += token.text }
            else if let index = options.dropFirst().firstIndex(where: { $0.id == answer }) { output += symbols[index - 1] }
            else { throw JevFailure.invalid("The spoken address is unclear.") }
        }
        guard Self.validatedURL(output) != nil else { throw JevFailure.invalid("The address is incomplete or invalid.") }
        return output
    }

    static func validatedURL(_ source: String) -> URL? {
        guard !source.isEmpty, !source.contains(where: \.isWhitespace) else { return nil }
        guard var parts = URLComponents(string: source.contains("://") ? source : "https://" + source),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, host.contains("."), parts.user == nil, parts.password == nil else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.first != "-" && $0.last != "-" &&
            $0.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) }) else { return nil }
        parts.host = host.lowercased()
        return parts.url
    }
}
