import AppKit
import ComputahCore
import SwiftUI

extension App {
    enum InputSource: String, Codable { case microphone, suppliedAudio, typed, commandLine, scenario }
    struct InputRecord: Codable {
        let source: InputSource
        let turnID: String
        let text: String
        let receivedAt: Date
    }
    struct RunRecord: Codable, Identifiable {
        let command: String
        let status: String
        let observation: String?
        let action: String?
        let requests: Int?
        let inputTokens: Int?
        let elapsed: TimeInterval?
        let recordedAt: Date
        var events: [WorkflowEvent]? = nil
        var complete: Bool? = nil
        var recordID: UUID? = UUID()
        var id: String { recordID?.uuidString ?? "\(recordedAt.timeIntervalSince1970):\(command)" }
    }

    /// Local provenance for finalized inputs, separate from observed workflow results.
    /// Never records audio, credentials, or interim transcripts.
    func recordInput(_ text: String, source: InputSource, turnID: String) {
        guard recordsDiagnostics else { return }
        let folder = root.appendingPathComponent("outputs/computah/inputs", isDirectory: true)
        let file = folder.appendingPathComponent("\(UUID().uuidString).json")
        do {
            let entry = InputRecord(source: source, turnID: turnID, text: text, receivedAt: Date())
            try PrivateFile.write(SensitiveText.encodedJSON(diagnosticEncoder().encode(entry)), to: file)
        } catch {
            fputs("Could not save input-source diagnostics.\n", stderr)
        }
    }

    func record(_ entry: RunRecord) {
        recentRuns.append(entry)
        recentRuns = Array(recentRuns.suffix(30))
        refreshHistory()
        guard recordsDiagnostics else { return }
        let folder = root.appendingPathComponent("outputs/computah/runs", isDirectory: true)
        let file = folder.appendingPathComponent("\(UUID().uuidString).json")
        do {
            try PrivateFile.write(SensitiveText.encodedJSON(diagnosticEncoder().encode(entry)), to: file)
        } catch {
            status += " · Could not save run details: \(error.localizedDescription)"
        }
    }

    private func diagnosticEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func refreshHistory() {
        // Merge persisted history with current results, including a run whose save failed.
        var byID = Dictionary(debugState.runs.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        for run in recentRuns { byID[run.id] = run }
        debugState.runs = Array(byID.values.sorted { $0.recordedAt > $1.recordedAt }.prefix(30))
    }

    private func loadSavedHistory() {
        guard recordsDiagnostics else { return }
        let folder = root.appendingPathComponent("outputs/computah/runs", isDirectory: true)
        Task { [weak self] in
            let saved = await Task.detached(priority: .utility) {
                RunHistoryStore.load(from: folder)
            }.value
            guard let self else { return }
            debugState.runs = saved
            refreshHistory()  // Include runs completed while the disk read was in flight.
        }
    }

    func showReview() {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            appBeforeReview = NSWorkspace.shared.frontmostApplication
        }
        if review == nil {
            loadSavedHistory()
            let window = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                backing: .buffered, defer: false)
            window.title = "Computah · Debug"
            window.minSize = NSSize(width: 800, height: 620)
            window.isReleasedWhenClosed = false
            window.center()
            window.level = .floating
            window.hidesOnDeactivate = false
            window.contentView = NSHostingView(
                rootView: DebugPanel(
                    state: debugState, costs: jevCosts,
                    toggleListening: { [weak self] in self?.toggleVoice() },
                    beginCommand: { [weak self] in self?.beginDebugCommand() },
                    submitCommand: { [weak self] text in self?.submitDebugCommand(text) }))
            review = window
        }
        debugState.savesDiagnostics = recordsDiagnostics
        refreshHistory()
        refresh()
        review?.orderFrontRegardless()
    }
}

/// Select by save time before decoding. Opening the panel never reads more than
/// the newest 30 report bodies, regardless of how long diagnostics were enabled.
enum RunHistoryStore {
    static func load(from folder: URL, limit: Int = 30, read: (URL) throws -> Data = { try Data(contentsOf: $0) })
        -> [App.RunRecord]
    {
        guard limit > 0 else { return [] }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        let newest = files.compactMap { file -> (URL, Date)? in
            guard file.pathExtension == "json", let values = try? file.resourceValues(forKeys: keys),
                values.isRegularFile == true
            else { return nil }
            return (file, values.contentModificationDate ?? .distantPast)
        }.sorted { left, right in
            left.1 == right.1 ? left.0.lastPathComponent < right.0.lastPathComponent : left.1 > right.1
        }.prefix(limit)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return newest.compactMap { file, _ in
            guard let data = try? read(file) else { return nil }
            return try? decoder.decode(App.RunRecord.self, from: data)
        }.sorted { $0.recordedAt > $1.recordedAt }
    }
}
