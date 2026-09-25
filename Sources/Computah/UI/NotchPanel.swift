import AppKit
import QuartzCore

// The notch never takes keyboard focus from the target application.
private final class NotchWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Screen-space hit regions do not move during a window animation. Brief edge
// jitter must not reverse an expansion that is still in progress.
struct NotchHoverState {
    private(set) var inside = false
    private var outsideSince: Double?
    static func activationRegion(in notch: NSRect) -> NSRect {
        // AppKit screen coordinates grow upward: raise the bottom edge while
        // keeping the trigger flush with the top of the physical notch.
        NSRect(
            x: notch.minX + 10, y: notch.minY + 10,
            width: max(0, notch.width - 20), height: max(0, notch.height - 10))
    }
    mutating func sample(_ point: NSPoint, closed: NSRect, open: NSRect, now: Double, revealed: Bool = false)
        -> Bool
    {
        let inContent = (inside || revealed) && open.insetBy(dx: -4, dy: -4).contains(point)
        if Self.activationRegion(in: closed).contains(point) || inContent {
            inside = true
            outsideSince = nil
        } else if inside {
            if outsideSince == nil { outsideSince = now }
            if now - (outsideSince ?? now) >= 0.18 {
                inside = false
                outsideSince = nil
            }
        }
        return inside
    }
}

@MainActor final class NotchController: NSObject {
    private let panel: NotchWindow
    private let surface = NotchSurface(frame: .zero)
    private var screenObserver: NSObjectProtocol?
    private var hovered = false
    private var hoverState = NotchHoverState()
    private var hoverTimer: Timer?
    private var closedFrame = NSRect.zero
    private var openFrame = NSRect.zero
    private var targetFrame = NSRect.zero
    private var menuOpen = false
    private var listening = false
    private var expanded = false
    private var transitionID = 0
    private var openingTimer: Timer?
    var toggle: (() -> Void)?
    var debug: (() -> Void)?

    override init() {
        panel = NotchWindow(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        super.init()
        panel.title = "Computah · Notch"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.alphaValue = 1
        panel.appearance = nil
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        let host = NSView(frame: .zero)
        host.addSubview(surface)
        surface.autoresizingMask = [.width, .height]
        panel.contentView = host
        surface.toggle = { [weak self] in self?.toggleFromMenu() }
        surface.showMenu = { [weak self] event in self?.showMenu(event) }
        surface.debug = { [weak self] in self?.debug?() }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleHover() }
        }
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.position(animated: false) }
        }
        position(animated: false)
    }
    private func sampleHover() {
        guard !menuOpen, !closedFrame.isEmpty else { return }
        let pointer = NSEvent.mouseLocation
        // Transparent wings in the menu-bar row must pass clicks to macOS.
        panel.ignoresMouseEvents =
            !(NotchHoverState.activationRegion(in: closedFrame).contains(pointer)
            || (expanded && openFrame.contains(pointer)))
        let next = hoverState.sample(
            pointer, closed: closedFrame, open: openFrame,
            now: ProcessInfo.processInfo.systemUptime, revealed: expanded)
        guard next != hovered else { return }
        hovered = next
        position(animated: true)
    }
    func audioLevel(_ level: Double) { surface.audioLevel = level }
    func show() {
        position(animated: false)
        panel.orderFrontRegardless()
    }
    func update(listening: Bool, transcript: String, needsSetup: Bool) {
        let changed = self.listening != listening
        self.listening = listening
        surface.update(listening: listening, transcript: transcript, needsSetup: needsSetup)
        if changed { position(animated: true) }
    }
    private func position(animated: Bool) {
        // Prefer the physical notch, even when an external monitor is the primary display.
        guard
            let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
                ?? NSScreen.screens.first
        else { return }
        let hasNotch = screen.safeAreaInsets.top > 0
        let inset = hasNotch ? screen.safeAreaInsets.top : NSStatusBar.system.thickness
        let gap: CGFloat
        let center: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            gap = right.minX - left.maxX
            center = (left.maxX + right.minX) / 2
        } else {
            gap = 160
            center = screen.frame.midX
        }
        let wasExpanded = expanded
        expanded = hovered || listening || menuOpen
        // A single compact row sits below the menu bar, joined to the camera housing.
        let openWidth = min(gap + 208, screen.frame.width - 40)
        closedFrame = NSRect(x: center - gap / 2, y: screen.frame.maxY - inset, width: gap, height: inset)
        openFrame = NSRect(
            x: center - openWidth / 2, y: screen.frame.maxY - inset - 44, width: openWidth, height: 44)
        surface.expanded = expanded
        surface.notchWidth = gap
        surface.contentTop = screen.frame.maxY - inset
        let frame = expanded ? openFrame.union(closedFrame) : closedFrame
        guard targetFrame != frame else { return }
        targetFrame = frame
        transitionID += 1
        let currentTransition = transitionID
        surface.hideContents()
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        openingTimer?.invalidate()
        openingTimer = nil
        if animate && expanded && !wasExpanded {
            animateOpening(to: frame)
        } else if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.transitionID == currentTransition, self.expanded else { return }
                    self.surface.revealContents(animated: true)
                }
            }
        } else {
            panel.setFrame(frame, display: true)
            if expanded { surface.revealContents(animated: false) }
        }
        surface.needsLayout = true
        surface.needsDisplay = true
    }
    private func animateOpening(to frame: NSRect) {
        // Sample a continuous rebound at 60 Hz. Smoothstep gives each turning
        // point zero velocity, so expansion and settling never jerk or pause.
        let frames = [
            panel.frame,
            NSRect(x: frame.minX - 5, y: frame.minY - 9, width: frame.width + 10, height: frame.height + 9),
            NSRect(x: frame.minX + 1, y: frame.minY + 2, width: frame.width - 2, height: frame.height - 2),
            frame,
        ]
        let times = [0.0, 0.22, 0.33, 0.42]
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                if elapsed >= times[3] {
                    timer.invalidate()
                    self.openingTimer = nil
                    self.panel.setFrame(frame, display: true)
                    self.surface.revealContents(animated: true)
                } else {
                    let step = elapsed < times[1] ? 0 : elapsed < times[2] ? 1 : 2
                    let t = (elapsed - times[step]) / (times[step + 1] - times[step])
                    let amount = CGFloat(t * t * (3 - 2 * t))
                    let from = frames[step]
                    let to = frames[step + 1]
                    self.panel.setFrame(
                        NSRect(
                            x: from.minX + (to.minX - from.minX) * amount,
                            y: from.minY + (to.minY - from.minY) * amount,
                            width: from.width + (to.width - from.width) * amount,
                            height: from.height + (to.height - from.height) * amount), display: true)
                }
                self.surface.needsLayout = true
                self.surface.needsDisplay = true
            }
        }
        openingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func showMenu(_ event: NSEvent) {
        menuOpen = true
        position(animated: false)
        let menu = NSMenu()
        let listeningItem = menu.addItem(
            withTitle: listening ? "Stop listening" : "Start listening", action: #selector(toggleFromMenu),
            keyEquivalent: "")
        listeningItem.target = self
        menu.addItem(.separator())
        let debugItem = menu.addItem(
            withTitle: "Open Debug Mode…", action: #selector(openDebug), keyEquivalent: "")
        debugItem.target = self
        menu.addItem(
            withTitle: "Quit Computah", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: surface)
        menuOpen = false
        sampleHover()
        position(animated: true)
    }
    @objc private func toggleFromMenu() {
        toggle?()
    }
    @objc private func openDebug() {
        debug?()
    }
    func close() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        hoverTimer?.invalidate()
        hoverTimer = nil
        transitionID += 1
        openingTimer?.invalidate()
        openingTimer = nil
        surface.stopAnimation()
        panel.close()
    }
}

@MainActor private final class NotchSurface: NSView {
    var toggle: (() -> Void)?
    var showMenu: ((NSEvent) -> Void)?
    var expanded = false
    var notchWidth: CGFloat = 185
    var contentTop: CGFloat = .greatestFiniteMagnitude
    private let contentMask = CAShapeLayer()
    var audioLevel = 0.0
    private var displayedLevel = 0.0
    private var listening = false
    private var transcript = ""
    private var needsSetup = false
    private var contentOpacity: CGFloat = 0
    private var revealStarted: Double?
    private var offset: CGFloat = 0
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private let control = NSButton()
    private let more = NSButton()
    var debug: (() -> Void)?
    private let accent = NSColor.white
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = contentMask
        control.isBordered = false
        control.target = self
        control.action = #selector(clicked)
        control.bezelStyle = .regularSquare
        addSubview(control)
        more.isBordered = false
        more.target = self
        more.action = #selector(menuClicked)
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More options")
        more.contentTintColor = .white
        more.setAccessibilityLabel("More options")
        addSubview(more)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Computah notch")
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }
    // The opaque shell completes its expansion before any content appears.
    func hideContents() {
        revealStarted = nil
        setContentOpacity(0)
    }
    func revealContents(animated: Bool) {
        if animated {
            revealStarted = ProcessInfo.processInfo.systemUptime
        } else {
            revealStarted = nil
            setContentOpacity(1)
        }
    }
    private func setContentOpacity(_ value: CGFloat) {
        contentOpacity = value
        control.alphaValue = value
        more.alphaValue = value
        control.isEnabled = value == 1
        more.isEnabled = value == 1
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) { showMenu?(event) }
    @objc private func clicked() { toggle?() }
    @objc private func menuClicked() {
        if let event = NSApp.currentEvent { showMenu?(event) }
        else { debug?() }
    }
    func update(listening: Bool, transcript: String, needsSetup: Bool) {
        self.listening = listening
        self.needsSetup = needsSetup
        if transcript != self.transcript {
            self.transcript = transcript
            // A shorter phrase/correction must not remain scrolled beyond its end.
            let width = (transcript as NSString).size(withAttributes: textAttributes).width
            offset = min(offset, max(0, width - textWindow.width + 4))
        }
        control.image = NSImage(
            systemSymbolName: listening ? "stop.fill" : "mic.fill",
            accessibilityDescription: listening ? "Stop listening" : "Start listening")
        control.contentTintColor = accent
        control.setAccessibilityLabel(
            needsSetup ? "Add API keys to .env" : listening ? "Stop listening" : "Start listening")
        setAccessibilityValue(transcript.isEmpty ? (listening ? "Listening" : "Ready") : transcript)
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        // Keep the menu-bar strip clear throughout the frame animation too,
        // including subviews such as the microphone button.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentMask.frame = bounds
        contentMask.path = silhouette
        CATransaction.commit()
        control.isHidden = !expanded
        more.isHidden = !expanded
        let rowY = (visibleBody.height - 26) / 2
        control.frame = NSRect(x: bounds.width - 68, y: rowY, width: 26, height: 26)
        more.frame = NSRect(x: bounds.width - 38, y: rowY, width: 26, height: 26)
    }
    private var visibleBody: NSRect {
        let height = min(bounds.height, max(0, contentTop - (window?.frame.minY ?? contentTop)))
        return NSRect(x: 0, y: 0, width: bounds.width, height: height)
    }
    // One continuous outline: a narrow camera-width neck, concave shoulder
    // curves, and the compact rounded row below the menu bar.
    private var silhouette: CGPath {
        let w = bounds.width
        let h = bounds.height
        let body = visibleBody.height
        let neck = min(notchWidth, w)
        let left = (w - neck) / 2
        let right = (w + neck) / 2
        let join = min(8, left, max(0, h - body))
        let radius = min(14, body / 2)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: left, y: h))
        p.addLine(to: CGPoint(x: right, y: h))
        p.addLine(to: CGPoint(x: right, y: body + join))
        p.addCurve(
            to: CGPoint(x: right + join, y: body), control1: CGPoint(x: right, y: body + join * 0.45),
            control2: CGPoint(x: right + join * 0.45, y: body))
        p.addLine(to: CGPoint(x: w - radius, y: body))
        p.addCurve(
            to: CGPoint(x: w, y: body - radius), control1: CGPoint(x: w - radius * 0.45, y: body),
            control2: CGPoint(x: w, y: body - radius * 0.45))
        p.addLine(to: CGPoint(x: w, y: radius))
        p.addCurve(
            to: CGPoint(x: w - radius, y: 0), control1: CGPoint(x: w, y: radius * 0.45),
            control2: CGPoint(x: w - radius * 0.45, y: 0))
        p.addLine(to: CGPoint(x: radius, y: 0))
        p.addCurve(
            to: CGPoint(x: 0, y: radius), control1: CGPoint(x: radius * 0.45, y: 0),
            control2: CGPoint(x: 0, y: radius * 0.45))
        p.addLine(to: CGPoint(x: 0, y: body - radius))
        p.addCurve(
            to: CGPoint(x: radius, y: body), control1: CGPoint(x: 0, y: body - radius * 0.45),
            control2: CGPoint(x: radius * 0.45, y: body))
        p.addLine(to: CGPoint(x: left - join, y: body))
        p.addCurve(
            to: CGPoint(x: left, y: body + join), control1: CGPoint(x: left - join * 0.45, y: body),
            control2: CGPoint(x: left, y: body + join * 0.45))
        p.addLine(to: CGPoint(x: left, y: h))
        p.closeSubpath()
        return p
    }
    private var textWindow: NSRect {
        NSRect(x: 48, y: (visibleBody.height - 22) / 2, width: max(10, bounds.width - 124), height: 22)
    }
    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(0.1, now - lastTick)
        lastTick = now
        guard expanded else { return }
        if let start = revealStarted {
            let progress = min(1, (now - start) / 0.08)
            setContentOpacity(CGFloat(progress * progress * (3 - 2 * progress)))
            if progress == 1 { revealStarted = nil }
        }
        displayedLevel +=
            (audioLevel - displayedLevel) * min(1, elapsed * (audioLevel > displayedLevel ? 20 : 7))
        let width = (transcript as NSString).size(withAttributes: textAttributes).width
        let target = max(0, width - textWindow.width + 4)
        // Only transcript growth moves the line. There is no timed sweep or
        // replay: after the newest words settle, a pause stays visually still.
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        offset = reduced ? target : offset + (target - offset) * min(1, elapsed * 18)
        if abs(target - offset) < 0.25 { offset = target }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        guard expanded else { return }  // Fully transparent over the physical camera housing.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let shape = silhouette
        context.saveGState()
        context.setBlendMode(.copy)
        // Only the shaped panel is opaque; the menu-bar wings stay transparent.
        // Background opacity never follows the content fade or system glass settings.
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.addPath(shape)
        context.fillPath()
        context.restoreGState()
        NSGraphicsContext.saveGraphicsState()
        context.addPath(shape)
        context.clip()
        context.setAlpha(contentOpacity)
        if expanded {
            let phase = ProcessInfo.processInfo.systemUptime * 4
            for index in 0..<4 {
                let height: CGFloat =
                    listening
                    ? 4 + CGFloat(displayedLevel * (14 + (sin(phase + Double(index) * 1.2) + 1) * 8))
                    : CGFloat([7, 15, 20, 10][index])
                accent.setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: 16 + CGFloat(index) * 5, y: (visibleBody.height - height) / 2, width: 3,
                        height: height), xRadius: 1.5, yRadius: 1.5
                ).fill()
            }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: textWindow).addClip()
            let placeholder =
                needsSetup
                ? "Add API keys to .env"
                : listening ? "Go ahead, I’m listening…" : "Control + Option to begin"
            let text = transcript.isEmpty ? placeholder : transcript
            var attributes = textAttributes
            if transcript.isEmpty { attributes[.foregroundColor] = NSColor(white: 0.6, alpha: 1) }
            (text as NSString).draw(
                at: NSPoint(x: textWindow.minX - (transcript.isEmpty ? 0 : offset), y: textWindow.minY + 2),
                withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
