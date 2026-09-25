import AppKit
import ApplicationServices
import ComputahCore

enum NativeInspection {
    static func runIfRequested() -> Int32? {
        if LaunchOptions.current.contains("--inspect") || LaunchOptions.current.contains("--inspect-app") {
            do {
                var pid: pid_t?
                if let argument = LaunchOptions.current.value("--inspect-app") {
                    pid = NSRunningApplication.runningApplications(withBundleIdentifier: argument).first?.processIdentifier
                    guard pid != nil else { throw AXFailure.unavailable("The inspected app must already be running.") }
                }
                let initialBudget = LaunchOptions.current.contains("--inspect-initial")
                let snapshot = try AXReader.capture(maxNodes: initialBudget ? 900 : 1_500,
                    seconds: initialBudget ? 0.35 : 1.5,
                    allChildren: LaunchOptions.current.contains("--inspect-all-children"), pid: pid)
                if let argument = LaunchOptions.current.value("--snapshot-json") {
                    let url = URL(fileURLWithPath: argument)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try PrivateFile.write(SensitiveText.encodedJSON(encoder.encode(snapshot.nodes)), to: url)
                }
                let candidates = AXGrouping.candidates(in: snapshot)
                let groups = AXGrouping.groups(in: snapshot, candidates: candidates)
                print("\(snapshot.appName): \(snapshot.nodes.count) AX nodes, \(candidates.count) actions, \(groups.count) regions; partial=\(snapshot.partial); read=\(snapshot.readSeconds)s")
                print("coverage: " + snapshot.coverage.map { "\($0.reason.rawValue)@\($0.nodeID.map(String.init) ?? "surface")" }.joined(separator: ", "))
                print(snapshot.evidence)
                if LaunchOptions.current.contains("--inspect-focus") { print(AXActor.inspectFocus(in: snapshot)) }
                for candidate in candidates { print(candidate.id + ": " + candidate.description) }
                if let argument = LaunchOptions.current.value("--inspect-hits") {
                    let label = argument
                    for candidate in candidates where candidate.operation == .pressClick && candidate.description.localizedCaseInsensitiveContains(label) {
                        print("hit: " + candidate.description + " " + AXActor.inspectClick(candidate, in: snapshot, hover: LaunchOptions.current.contains("--hover")))
                    }
                }
                for node in snapshot.nodes where !node.actions.isEmpty {
                    print("geometry \(node.id): \(node.role) \(node.label); \(String(describing: node.frame)); \(node.actions); orientation=\(node.orientation)")
                }
            } catch {
                fputs("Inspect failed: \(error.localizedDescription)\n", stderr)
                return 1
            }
            return 0
        }
        return nil
    }
}
