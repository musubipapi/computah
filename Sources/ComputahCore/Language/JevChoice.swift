import Foundation
import CryptoKit

public struct JevOption {
    public let id: String
    public let description: String
    public init(id: String, description: String) {
        self.id = id
        self.description = description
    }
}

struct JevQuestion {
    let instructions: String
    let options: [JevOption]
    var noneDescription: String? = nil
    var optionBudget: Int = 254
    var observedControls: [String: String] = [:]
    var key: String? = nil
}

struct JevJudgments {
    let ids: [String?]
    var requests: Int = 0
    var shortlists: [[String]] = []
    var answers: [String: String] = [:]
    func answer(_ key: String) -> String? { answers[key] }
}

public enum JevFailure: LocalizedError {
    case invalid(String)
    case contextLimit
    case service(Int)
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): detail
        case .contextLimit: "Jev context still exceeds its limit after splitting the options."
        case .service(let code): "Jev returned HTTP \(code)."
        }
    }
}

public struct JevSelector {
    public let apiKey: String
    public let model: String
    public var endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public var traceDirectory: URL? = nil
    var usage = ModelUsageTracker()
    public var costs: JevCosts? = nil
    public var session: URLSession
    public init(apiKey: String, model: String = "jev-1.13.0", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    private struct Answer {
        let choice: String
        let probabilities: [String: Double]
    }

    /// Independent questions share state and one request. No question consumes another's answer.
    func judge(state: [String: Any], questions: [JevQuestion]) async throws -> JevJudgments {
        let keys = questions.compactMap(\.key)
        guard Set(keys).count == keys.count else { throw JevFailure.invalid("Duplicate question keys.") }
        let callUsage = ModelUsageTracker()
        var result = try await judge(state: state, questions: questions, usage: callUsage)
        result.answers = Dictionary(uniqueKeysWithValues: zip(questions, result.ids).compactMap { question, answer in
            guard let key = question.key, let answer else { return nil }
            return (key, answer)
        })
        result.requests = callUsage.snapshot.requests
        return result
    }

    private func judge(state: [String: Any], questions: [JevQuestion], usage callUsage: ModelUsageTracker) async throws -> JevJudgments {
        guard !questions.isEmpty else { return JevJudgments(ids: []) }
        guard questions.allSatisfy({ !$0.options.isEmpty && Set($0.options.map(\.id)).count == $0.options.count &&
            !$0.options.contains(where: { $0.id == "none_here" }) }) else {
            throw JevFailure.invalid("Invalid semantic question options.")
        }
        guard questions.allSatisfy({ (1...254).contains($0.optionBudget) }) else {
            throw JevFailure.invalid("Invalid choice budget.")
        }
        if questions.contains(where: { $0.options.count > $0.optionBudget }) {
            var expanded: [JevQuestion] = []
            var groups: [[Int]] = []
            for question in questions {
                var indexes: [Int] = []
                for start in stride(from: 0, to: question.options.count, by: question.optionBudget) {
                    indexes.append(expanded.count)
                    expanded.append(JevQuestion(instructions: question.instructions,
                        options: Array(question.options[start..<min(start + question.optionBudget, question.options.count)]),
                        noneDescription: (question.noneDescription ?? "No offered answer applies.") + " This question shows one subset. The answer may be in another subset; do not select an inapplicable option.",
                        observedControls: question.observedControls,
                        key: question.key.map { $0 + "_part\(indexes.count - 1)" }))
                }
                groups.append(indexes)
            }
            let first = try await judge(state: state, questions: expanded, usage: callUsage)
            var ids = [String?](repeating: nil, count: questions.count)
            var shortlists = [[String]](repeating: [], count: questions.count)
            var finalists: [JevQuestion] = []
            var destinations: [Int] = []
            for (index, group) in groups.enumerated() {
                if group.count == 1 {
                    ids[index] = first.ids[group[0]]
                    shortlists[index] = first.shortlists[group[0]]
                } else if group.allSatisfy({ first.ids[$0] == nil }) {
                    // Preserve unanimous abstention; another round must not manufacture an action.
                    ids[index] = nil
                    // An outer mixed comparison may still need this branch's
                    // contenders after nested request-size splitting.
                    shortlists[index] = group.flatMap { first.shortlists[$0] }
                } else {
                    // Near-equivalent valid controls can divide their probability,
                    // allowing no-match to win one subset. Keep its candidates for
                    // the global comparison when another subset is positive.
                    let retained = Set(group.flatMap { first.shortlists[$0] })
                    finalists.append(JevQuestion(instructions: questions[index].instructions,
                        options: questions[index].options.filter { retained.contains($0.id) },
                        noneDescription: questions[index].noneDescription,
                        observedControls: questions[index].observedControls, key: questions[index].key))
                    destinations.append(index)
                }
            }
            let final = try await judge(state: state, questions: finalists, usage: callUsage)
            for (index, destination) in destinations.enumerated() {
                ids[destination] = final.ids[index]
                shortlists[destination] = final.shortlists[index]
            }
            return JevJudgments(ids: ids, shortlists: shortlists)
        }
        let wireKeys = questions.enumerated().map { $0.element.key ?? "q\($0.offset)" }
        guard Set(wireKeys).count == wireKeys.count else { throw JevFailure.invalid("Duplicate wire question keys.") }
        var wire: [String: Any] = [:]
        for (index, question) in questions.enumerated() {
            var criteria = Dictionary(uniqueKeysWithValues: question.options.map { ($0.id, $0.description) })
            criteria["none_here"] = question.noneDescription ?? "Insufficient information, ambiguity, or no applicable offered answer."
            wire[wireKeys[index]] = ["type": "choice", "instructions": question.instructions, "criteria": criteria]
        }
        var requestState = state
        var observedIDs = Set<String>()
        let observedControls = questions.flatMap { question in
            question.options.compactMap { option -> String? in
                guard let observed = question.observedControls[option.id], observedIDs.insert(option.id).inserted else { return nil }
                return observed
            }
        }
        if !observedControls.isEmpty { requestState["available_controls"] = observedControls }
        do {
            let result = try await send(state: requestState, questions: wire, chunks: questions.map(\.options), keys: wireKeys, usage: callUsage)
            return JevJudgments(ids: result.map { $0.choice == "none_here" ? nil : $0.choice },
                                shortlists: zip(questions, result).map { question, answer in
                question.options.sorted { (answer.probabilities[$0.id] ?? 0) > (answer.probabilities[$1.id] ?? 0) }
                    .prefix(3).map(\.id)
            })
        } catch JevFailure.contextLimit {
            // Split questions, never discard source positions or candidates.
            if questions.count == 1 {
                var question = questions[0]
                // Keep three contenders from each half. At six or fewer, another
                // split could retain every finalist and recurse without progress.
                guard question.options.count > 6 else { throw JevFailure.contextLimit }
                question.optionBudget = (question.options.count + 1) / 2
                return try await judge(state: state, questions: [question], usage: callUsage)
            }
            let middle = questions.count / 2
            let left = try await judge(state: state, questions: Array(questions[..<middle]), usage: callUsage)
            let right = try await judge(state: state, questions: Array(questions[middle...]), usage: callUsage)
            return JevJudgments(ids: left.ids + right.ids, shortlists: left.shortlists + right.shortlists)
        }
    }

    private func send(state: [String: Any], questions: [String: Any], chunks: [[JevOption]], keys: [String], usage callUsage: ModelUsageTracker) async throws -> [Answer] {
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw JevFailure.invalid("Add TYPESAFE_API_KEY to the project-root .env file.") }
        let body: [String: Any] = ["model": model, "state": state, "questions": questions]
        // Keep identical semantic inputs in the same wire order across processes.
        let data = try JSONSerialization.data(withJSONObject: SensitiveText.json(body), options: [.sortedKeys])
        guard data.count < 180_000 else { throw JevFailure.contextLimit }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let responseData: Data
            let response: URLResponse
            let costTicket = costs?.beginRequest()
            usage.beginRequest()
            callUsage.beginRequest()
            do { (responseData, response) = try await session.data(for: request) }
            catch {
                try Task.checkCancellation()
                if let transport = error as? URLError,
                   [.timedOut, .networkConnectionLost].contains(transport.code), attempt == 0 {
                    // Retrying this read-only judgment cannot duplicate native input.
                    continue
                }
                if let transport = error as? URLError, transport.code == .cancelled { throw error }
                throw JevFailure.invalid("Jev interpretation request failed after \(attempt + 1) attempt(s): \(error.localizedDescription)")
            }
            let payload = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
            let reportedTokens = (payload?["usage"] as? [String: Any])?["input_tokens"] as? Int
            costs?.received(costTicket, model: payload?["model"] as? String ?? model, inputTokens: reportedTokens)
            usage.received(inputTokens: reportedTokens)
            callUsage.received(inputTokens: reportedTokens)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let traceDirectory {
                if let responseObject = try? JSONSerialization.jsonObject(with: responseData),
                   let trace = try? JSONSerialization.data(withJSONObject: SensitiveText.json([
                    "request": body, "response": responseObject, "status": status,
                    "requestSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                   ])) {
                    try? PrivateFile.write(trace, to: traceDirectory.appendingPathComponent(UUID().uuidString + ".json"))
                }
            }
            guard status == 200 else {
                if status == 400, String(decoding: responseData, as: UTF8.self).contains("max_tokens_exceeded") {
                    throw JevFailure.contextLimit
                }
                throw JevFailure.service(status)
            }
            do {
                return try decode(responseData, chunks: chunks, keys: keys)
            } catch JevFailure.invalid(let detail) {
                if attempt == 0 { continue }
                throw JevFailure.invalid("Jev returned two invalid Choice replies. Last: \(detail)")
            }
        }
        throw JevFailure.invalid("Jev response validation did not finish.")
    }

    private func decode(_ responseData: Data, chunks: [[JevOption]], keys: [String]) throws -> [Answer] {
        guard let payload = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any],
              let rawAnswers = payload["answers"] as? [String: [String: Any]],
              rawAnswers.count == chunks.count else { throw JevFailure.invalid("Jev response has missing answers.") }
        var answers: [Answer] = []
        for (index, chunk) in chunks.enumerated() {
            let validIDs = Set(chunk.map(\.id) + ["none_here"])
            guard let raw = rawAnswers[keys[index]], raw["type"] as? String == "choice" else {
                throw JevFailure.invalid("Question \(index) has no Choice answer.")
            }
            guard let choice = raw["choice"] as? String, validIDs.contains(choice) else {
                throw JevFailure.invalid("Question \(index) selected an unknown option.")
            }
            guard let probabilities = raw["probabilities"] as? [String: Double],
                  Set(probabilities.keys) == validIDs else {
                throw JevFailure.invalid("Question \(index) omitted or added probability options.")
            }
            guard let confidence = raw["confidence"] as? Double, (0...1).contains(confidence),
                  probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  abs(probabilities.values.reduce(0, +) - 1) < 0.03 else {
                throw JevFailure.invalid("Question \(index) returned invalid probabilities.")
            }
            guard (probabilities[choice] ?? 0) >=
                  (probabilities.values.max() ?? 0) - 0.000_001 else {
                throw JevFailure.invalid("Question \(index) selected a non-leading option.")
            }
            answers.append(Answer(choice: choice, probabilities: probabilities))
        }
        return answers
    }
}
