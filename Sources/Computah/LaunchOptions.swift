import Foundation

/// Parse once. Launch flags are a CLI protocol, never natural-language intent.
struct LaunchOptions {
    static let current = LaunchOptions(Array(CommandLine.arguments.dropFirst()))
    private var values: [String: String] = [:]
    private var flags: Set<String> = []
    private(set) var errors: [String] = []

    init(_ arguments: [String]) {
        let valued: Set<String> = [
            "--root", "--trace-dir", "--initial-nodes", "--scenario", "--audio-pcm",
            "--command", "--report", "--inspect-app", "--snapshot-json", "--inspect-hits",
        ]
        let switches: Set<String> = [
            "--help", "--record-diagnostics", "--physical-activation", "--native-activation", "--inspect",
            "--inspect-initial", "--inspect-all-children", "--inspect-focus", "--hover",
        ]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if valued.contains(option) {
                guard index + 1 < arguments.count,
                    !valued.contains(arguments[index + 1]), !switches.contains(arguments[index + 1])
                else {
                    errors.append("Missing value for \(option).")
                    index += 1
                    continue
                }
                values[option] = arguments[index + 1]
                index += 2
            } else {
                if switches.contains(option) {
                    flags.insert(option)
                } else {
                    errors.append("Unknown launch option: \(option).")
                }
                index += 1
            }
        }
        if let raw = values["--initial-nodes"], Int(raw).map({ $0 > 0 }) != true {
            errors.append("--initial-nodes must be a positive integer.")
        }
        if let command = values["--command"], command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("--command must not be empty.")
        }
        let modes = ["--scenario", "--audio-pcm", "--command"].filter { values[$0] != nil }
        let inspection = flags.contains("--inspect") || values["--inspect-app"] != nil
        if modes.count + (inspection ? 1 : 0) > 1 { errors.append("Choose one diagnostic mode per invocation.") }
        if flags.contains("--physical-activation") && flags.contains("--native-activation") {
            errors.append("Choose one activation method per diagnostic run.")
        }
    }

    func value(_ name: String) -> String? { values[name] }
    func contains(_ name: String) -> Bool { flags.contains(name) || values[name] != nil }
}
