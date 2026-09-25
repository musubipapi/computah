import AppKit

/// Listening cues, owned by the UI so headless diagnostics stay silent.
@MainActor final class ListeningSounds {
    private var wasListening = false
    private let activation: NSSound?
    private let deactivation: NSSound?

    init() {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Computah_Computah.bundle")
        let bundle = packaged.flatMap { Bundle(url: $0) } ?? Bundle.module
        activation = bundle.url(forResource: "sparkle", withExtension: "wav", subdirectory: "Sounds")
            .flatMap { NSSound(contentsOf: $0, byReference: false) }
        deactivation = bundle.url(forResource: "droplet", withExtension: "wav", subdirectory: "Sounds")
            .flatMap { NSSound(contentsOf: $0, byReference: false) }
    }

    func update(listening: Bool) {
        guard listening != wasListening else { return }
        wasListening = listening
        // Stop either tail before playing the next cue on rapid toggles.
        activation?.stop()
        deactivation?.stop()
        if listening { activation?.play() } else { deactivation?.play() }
    }
}
