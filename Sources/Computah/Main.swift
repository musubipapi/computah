import AppKit

@main struct Computah {
    static func main() {
        if LaunchOptions.current.contains("--help") {
            print("""
            Computah — experimental voice and typed Mac automation
            Start the UI: Computah --root /path/to/checkout
            Optional history: --record-diagnostics
            Read native controls: --inspect or --inspect-app BUNDLE_ID
            Live input: --command TEXT | --scenario PATH | --audio-pcm PATH
            Explicit private outputs: --report PATH | --trace-dir PATH | --snapshot-json PATH
            Live diagnostics use real providers/apps. See docs/TESTING.md and docs/PRIVACY.md.
            """)
            return
        }
        if !LaunchOptions.current.errors.isEmpty {
            fputs(LaunchOptions.current.errors.joined(separator: "\n") + "\n", stderr)
            exit(1)
        }
        if let code = NativeInspection.runIfRequested() { exit(code) }
        let app = NSApplication.shared
        let delegate = App()
        app.delegate = delegate
        app.run()
    }
}
