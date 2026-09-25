import AppKit

struct ListenChord {
    private var held = false
    mutating func update(_ flags: NSEvent.ModifierFlags) -> Bool {
        let both = flags.contains([.control, .option])
        defer { held = both }
        return both && !held && flags.intersection([.command, .shift]).isEmpty
    }
}

@MainActor final class ListenShortcut {
    private var local: Any?
    private var global: Any?
    private var recovery: Timer?
    private var chord = ListenChord()
    private let modifiers: () -> NSEvent.ModifierFlags
    private let toggle: () -> Void
    init(
        modifiers: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags },
        toggle: @escaping () -> Void
    ) {
        self.modifiers = modifiers
        self.toggle = toggle
        // Keys already held at launch are not a new press.
        _ = chord.update(modifiers())
        local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.sample() }
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // Focus changes can miss a modifier event. Read the current system state
        // independently of event delivery, including release, so the chord re-arms.
        // Both paths read the same current state; a late event cannot replay a press.
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.005
        recovery = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func sample() {
        if chord.update(modifiers()) { toggle() }
    }
    func stop() {
        recovery?.invalidate()
        recovery = nil
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil
        global = nil
    }
}
