import Foundation

extension App {
    var recordsDiagnostics: Bool { LaunchOptions.current.contains("--record-diagnostics") }

    var diagnosticAuditLimit: Int {
        LaunchOptions.current.contains("--scenario") || LaunchOptions.current.contains("--audio-pcm") ? 4_096 : 0
    }

    var root: URL {
        if let path = LaunchOptions.current.value("--root") {
            return URL(fileURLWithPath: path)
        }
        if let path = ProcessInfo.processInfo.environment["COMPUTAH_PROJECT_ROOT"] {
            return URL(fileURLWithPath: path)
        }
        // A developer bundle in outputs/ is relocatable with its checkout.
        // This supports Finder launch without baking a personal path into Info.plist.
        let bundle = Bundle.main.bundleURL
        let checkout = bundle.deletingLastPathComponent().deletingLastPathComponent()
        if bundle.pathExtension == "app",
           FileManager.default.fileExists(atPath: checkout.appendingPathComponent("Package.swift").path) {
            return checkout
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    func credential(_ name: String) -> String? {
        guard let content = try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let pieces = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2, pieces[0].trimmingCharacters(in: .whitespaces) == name else { continue }
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
        return nil
    }

}
