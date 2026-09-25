import Foundation
import ComputahCore
import Combine

@MainActor final class JevCostStore: ObservableObject {
    @Published private(set) var total: JevCosts.Total
    @Published private(set) var storageError: String?
    let tracker: JevCosts
    private let file: URL
    private let writer = DispatchQueue(label: "computah.costs", qos: .utility)
    private var canSave = true

    init(file: URL) {
        self.file = file
        var restored = JevCosts.Total()
        var failure: String?
        if FileManager.default.fileExists(atPath: file.path) {
            do { restored = try JSONDecoder().decode(JevCosts.Total.self, from: Data(contentsOf: file)) }
            catch { failure = "Saved cost totals could not be read. Reset to start a new total." }
        }
        total = restored
        tracker = JevCosts(total: restored)
        storageError = failure
        canSave = failure == nil
        tracker.onChange { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func setEnabled(_ enabled: Bool) { tracker.setEnabled(enabled); refresh() }

    func reset() {
        canSave = true
        storageError = nil
        tracker.reset()
        refresh()
    }

    private func refresh() {
        let current = tracker.snapshot
        guard current != total else { return }
        total = current
        guard canSave else { return }
        do {
            let data = try JSONEncoder().encode(current)
            let destination = file
            writer.async { [weak self] in
                do { try PrivateFile.write(data, to: destination) }
                catch {
                    Task { @MainActor [weak self] in
                        self?.storageError = "Cost totals could not be saved. This session's total is still shown."
                    }
                }
            }
        } catch { storageError = "Cost totals could not be saved." }
    }

    /// Flush only on quit. Request processing never waits for a disk write.
    func flush() {
        refresh()
        writer.sync {}
    }
}
