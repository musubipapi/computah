import AppKit
import Foundation

public struct PreparedAction {
    let snapshot: AXSnapshot?
    let launch: InstalledApplication?
    let candidate: AXCandidate?
    let literal: String?
    public let description: String?
    let emptyStatus: String
    public let observation: String
    public var requests: Int { usage.requests }
    var permit: InputPermit = .standalone()
    var navigation: URL? = nil
    var navigationBrowser: InstalledApplication? = nil
    var interpretation: InterpretedCommand? = nil
    var captureSeconds: Double = 0
    var modelSeconds: Double = 0
    var preparationSeconds: Double = 0
    var recoveryReads: Int = 0
    var referenceContext: [String: Any] = [:]
    var usage = ModelUsage()

    var hasExecutablePlan: Bool {
        launch != nil || navigation != nil || candidate != nil || interpretation?.actionID == "already_satisfied"
    }

    /// Workflow handles app launches and navigation. This sends one observed control action.
    func execute(physicalActivation: Bool = true) async throws -> String {
        guard let snapshot, let candidate else {
            throw AXFailure.unavailable("The selected action has no observed control.")
        }
        return try await cancellableNative {
            try AXActor.perform(candidate, in: snapshot, text: literal, permit: permit,
                                physicalActivation: physicalActivation)
        }
    }

}

enum ObservationRequest { case initial, recovery(pid_t), expanded(pid_t), region(AXSnapshot, Int), verification(pid_t) }

public struct CommandEngine {
    public var inputPermit: InputPermit = .standalone()
    public var selector: JevSelector
    var executePrepared: (PreparedAction) async throws -> String = { try await $0.execute() }
    var observationForegroundPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var readObservation: (ObservationRequest) async throws -> AXSnapshot = { request in
        try Task.checkCancellation()
        return try await cancellableNative {
            switch request {
            case .initial:
                return try await AXReader.captureReady(maxNodes: 900, seconds: 0.35, promptForPermission: false)
            case .verification(let pid):
                return try await AXReader.captureReady(pid: pid)
            case .recovery(let pid):
                AXReader.invalidateEnablement(pid: pid)
                return try AXReader.capture(maxNodes: 1_200, seconds: 0.45, pid: pid, promptForPermission: false)
            case .expanded(let pid):
                AXReader.invalidateEnablement(pid: pid)
                return try AXReader.capture(maxNodes: 2_000, seconds: 0.65, allChildren: true, pid: pid, promptForPermission: false)
            case .region(let old, let id):
                guard old.handles.indices.contains(id) else { throw AXFailure.changed }
                let fresh = try AXReader.capture(maxNodes: 900, seconds: 0.35, allChildren: true,
                    pid: old.pid, promptForPermission: false, subtree: old.handles[id])
                guard fresh.sameWindow(as: old) else { throw AXFailure.changed }
                return fresh
            }
        }
    }
    public init(selector: JevSelector) {
        self.selector = selector
    }

    public mutating func useDiagnosticInitialNodeLimit(_ nodes: Int) {
        let normal = readObservation
        readObservation = { request in
            if case .initial = request {
                return try await cancellableNative {
                    try AXReader.capture(maxNodes: max(1, min(nodes, 3_000)), seconds: 0.35, promptForPermission: false)
                }
            }
            return try await normal(request)
        }
    }

    /// Compare delivery mechanisms in independent live trials, never as replay
    /// after an unknown native effect. Target selection and validation are shared.
    public mutating func useDiagnosticPhysicalActivation() {
        executePrepared = { try await $0.execute(physicalActivation: true) }
    }

    public mutating func useDiagnosticNativeActivation() {
        executePrepared = { try await $0.execute(physicalActivation: false) }
    }

    public func prepare(_ command: String, observation: AXSnapshot? = nil,
                        progress: [String] = [], excluded: Set<String> = []) async throws -> PreparedAction {
        try await prepare(command, from: 0, observation: observation, progress: progress, excluded: excluded)
    }

    func prepare(_ command: String, from offset: Int, observation supplied: AXSnapshot? = nil,
                 progress: [String] = [], excluded: Set<String> = [],
                 interpretation existing: InterpretedCommand? = nil, revisions: [String] = [],
                 relationshipContext: [String: Any]? = nil, conversationContext: [String: Any] = [:], continuation: AXSnapshot? = nil, activatedApps: Set<String> = []) async throws -> PreparedAction {
        let started = Date()
        let usageStart = selector.usage.snapshot
        var snapshot = supplied
        var captureSeconds = 0.0
        var modelSeconds = 0.0
        var recoveryReads = 0
        var captureFailure: String?
        if snapshot == nil {
            let start = Date()
            do { snapshot = try await readObservation(.initial) }
            catch is CancellationError { throw CancellationError() }
            catch { captureFailure = error.localizedDescription }
            captureSeconds += Date().timeIntervalSince(start)
        }
        try Task.checkCancellation()
        var apps = try await cancellableNative { AppRouting.installed() }
        if let browser = AppRouting.defaultBrowser() {
            if let index = apps.firstIndex(where: { $0.bundleID == browser.bundleID }) {
                let app = apps[index]
                apps[index] = InstalledApplication(name: app.name, bundleID: app.bundleID, url: app.url,
                                                   aliases: app.aliases + ["Registered default browser"])
            } else {
                apps.append(InstalledApplication(name: browser.name, bundleID: browser.bundleID, url: browser.url,
                                                 aliases: ["Registered default browser"]))
            }
        }
        apps.removeAll { activatedApps.contains($0.bundleID) }
        if let continuation {
            guard let snapshot, snapshot.sameWindow(as: continuation) else { throw AXFailure.changed }
        }
        let language = CommandLanguage(selector: selector)
        var scope = snapshot.map { availableCandidates($0, excluded: excluded) } ?? []
        var interpreted: InterpretedCommand
        if let existing, existing.source != command || existing.clause.startUTF16 != offset {
            throw JevFailure.invalid("Prepared interpretation belongs to a different instruction.")
        }
        let interpretStart = Date()
        interpreted = try await language.interpret(command, from: offset, apps: apps,
            progress: progress, controls: scope, observation: snapshot, fixedClause: existing?.clause, revisions: revisions, relationshipContext: relationshipContext, conversationContext: conversationContext, continuation: continuation)
        modelSeconds += Date().timeIntervalSince(interpretStart)
        func eligible(_ candidate: AXCandidate) -> Bool {
            guard !excluded.contains(candidate.description) else { return false }
            switch candidate.operation {
            case .typeText, .replaceText: return interpreted.canType && interpreted.value != nil
            case .setNumber: return interpreted.canSetNumber && interpreted.value != nil
            default: return true
            }
        }
        func prepared(candidate: AXCandidate? = nil, launch: InstalledApplication? = nil, navigation: URL? = nil,
                      status: String = "", description: String? = nil) -> PreparedAction {
            let details = "\(snapshot?.appName ?? "No AX observation"); nodes=\(snapshot?.nodes.count ?? 0); partial=\(snapshot?.partial ?? true); options=\(scope.count); selected=\(candidate?.id ?? interpreted.actionID ?? "none"); recovery reads=\(recoveryReads); capture=\(captureSeconds)s; model=\(modelSeconds)s"
            let usage = selector.usage.snapshot.since(usageStart)
            var result = PreparedAction(snapshot: interpreted.route == .controls || interpreted.relationship != nil ? snapshot : nil, launch: launch, candidate: candidate,
                literal: interpreted.value, description: description ?? candidate?.description, emptyStatus: status,
                observation: details)
            result.usage = usage
            result.permit = inputPermit
            result.navigation = navigation
            if navigation != nil {
                result.navigationBrowser = interpreted.app ?? AppRouting.defaultBrowser()
            }
            result.interpretation = interpreted
            result.referenceContext = conversationContext
            result.captureSeconds = captureSeconds
            result.modelSeconds = modelSeconds
            result.preparationSeconds = Date().timeIntervalSince(started)
            result.recoveryReads = recoveryReads
            return result
        }
        try Task.checkCancellation()
        if let relationship = interpreted.relationship, relationship != .replace {
            return prepared(status: "Goal relationship: " + relationship.rawValue)
        }
        if interpreted.activatesApp {
            guard let app = interpreted.app else { return prepared(status: "The requested app is unclear or unavailable.") }
            return prepared(launch: app, description: "Open \(app.name)")
        }
        if interpreted.route == nil {
            return prepared(status: "No clear action requested.")
        }
        if interpreted.route == .controls {
            var selected = interpreted.actionID
            let missingFromIncompleteRead = selected == nil && snapshot?.unfinishedVisibleRead == true
            if selected == "reobserve" || selected == "inspect_secondary" || missingFromIncompleteRead, let before = snapshot {
                let recovery = try await recover(command, offset: offset, interpretation: interpreted,
                    snapshot: before, primary: scope, progress: progress, excluded: excluded, revisions: revisions,
                    conversationContext: conversationContext, continuation: continuation)
                snapshot = recovery.snapshot
                scope = recovery.candidates
                interpreted = recovery.interpretation
                selected = interpreted.actionID
                captureSeconds += recovery.captureSeconds
                modelSeconds += recovery.modelSeconds
                recoveryReads += recovery.reads
            }
            if selected == "already_satisfied", snapshot != nil {
                return prepared(status: "Requested state needs fresh confirmation.", description: "Already satisfied — verify without input")
            }
            guard let candidate = scope.first(where: { $0.id == selected }) else {
                return prepared(status: captureFailure ?? "No matching control found after bounded observation; no further input sent.")
            }
            guard eligible(candidate) else {
                throw JevFailure.invalid("The selected action and source value disagree.")
            }
            if [.typeText, .replaceText, .setNumber].contains(candidate.operation) {
                let start = Date()
                let resolved = try await language.resolveValue(interpreted)
                modelSeconds += Date().timeIntervalSince(start)
                interpreted = resolved
            }
            return prepared(candidate: candidate)
        }
        let start = Date()
        let resolved = try await language.resolveValue(interpreted)
        modelSeconds += Date().timeIntervalSince(start)
        interpreted = resolved
        guard let value = interpreted.value, let url = CommandLanguage.validatedURL(value) else {
            return prepared(status: "The requested address is incomplete or unclear.")
        }
        return prepared(navigation: url, description: "Visit \(url.absoluteString)")
    }

    func availableCandidates(
        _ scene: AXSnapshot, excluded: Set<String>,
        includeSecondary: Bool = false
    ) -> [AXCandidate] {
        AXGrouping.candidates(in: scene, includeSecondary: includeSecondary).filter { candidate in
            !excluded.contains(candidate.description)
        }
    }
}
