import AppKit
import AVFoundation
import Security

struct KeychainFailure: Error {
    let status: OSStatus
    var message: String { "Keychain could not complete the request (\(status)). Your keys were not printed or logged." }
}

struct KeyStore {
    let service: String
    init(service: String = "local.speechtest.api-keys") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func load(_ account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainFailure(status: errSecDecode)
        }
        return value
    }

    func save(_ value: String, account: String) throws {
        let request = query(account)
        let data = Data(value.utf8)
        let status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = request
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Speech Test — \(account) API key"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainFailure(status: added) }
        } else if status != errSecSuccess { throw KeychainFailure(status: status) }
    }

    func forget(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
    }
}

// Flux's numeric fields may arrive as JSON numbers or numeric strings.
func number(_ value: Any?) -> Double? {
    let result = (value as? Double) ?? (value as? String).flatMap(Double.init)
    return result.flatMap { $0.isFinite ? $0 : nil }
}

func probability(_ value: Any?) -> Double? {
    number(value).flatMap { (0...1).contains($0) ? $0 : nil }
}

func percent(_ value: Double?) -> String {
    value.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
}

struct WordInfo {
    let word: String
    let confidence: Double?
    let start: Double?
    let end: Double?

    init?(_ object: [String: Any]) {
        guard let word = object["word"] as? String else { return nil }
        self.word = word
        confidence = probability(object["confidence"])
        let parsedStart = number(object["start"]).flatMap { $0 >= 0 ? $0 : nil }
        start = parsedStart
        end = number(object["end"]).flatMap { $0 >= (parsedStart ?? 0) ? $0 : nil }
    }

    var row: String {
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.3fs", $0) } ?? "—" }
        return "\(word)\t\(percent(confidence))\t\(seconds(start))\t\(seconds(end))"
    }
}

// A small, dependency-free microphone → Deepgram Flux experiment.
struct TranscriptState {
    var completed: [Int: String] = [:]
    var activeTurn: Int?
    var partial = ""
    var lastSequence = -1
    var event = ""
    var turn: Int?
    var turnConfidence: Double?
    var trigger: String?
    var words: [WordInfo] = []
    var wordTurn: Int?

    @discardableResult mutating func apply(_ message: [String: Any]) -> Bool {
        guard message["type"] as? String == "TurnInfo",
              let turn = message["turn_index"] as? Int,
              let text = message["transcript"] as? String else { return false }
        if let sequence = message["sequence_id"] as? Int {
            guard sequence > lastSequence else { return false }
            lastSequence = sequence
        }
        self.turn = turn
        event = message["event"] as? String ?? "Update"
        turnConfidence = probability(message["end_of_turn_confidence"])
        trigger = message["trigger"] as? String
        // Keep the last spoken phrase inspectable during silent updates.
        // A new nonempty transcript replaces its entire word list, including revisions.
        if !text.isEmpty {
            words = (message["words"] as? [[String: Any]] ?? []).compactMap(WordInfo.init)
            wordTurn = turn
        }
        if message["event"] as? String == "EndOfTurn" {
            completed[turn] = text
            if activeTurn == turn { partial = ""; activeTurn = nil }
        } else if completed[turn] == nil {
            activeTurn = turn
            partial = text // Flux sends a replacement transcript, not a delta.
        }
        return true
    }

    var text: String { completed.keys.sorted().compactMap { completed[$0] }.joined(separator: "\n\n") }
    var wordDetails: String {
        guard let wordTurn else { return "Word confidence and audio timestamps will appear here when you speak." }
        let heading = "Words from turn \(wordTurn + 1) · times are seconds into the audio stream\n"
        guard !words.isEmpty else { return heading + "Word metadata was not supplied for this transcript." }
        return heading + "\nWORD\tCONFIDENCE\tSTART\tEND\n" + words.map(\.row).joined(separator: "\n")
    }
}

func fluxURL() -> URL {
    var components = URLComponents(string: "wss://api.deepgram.com/v2/listen")!
    components.queryItems = [
        URLQueryItem(name: "model", value: "flux-general-en"),
        URLQueryItem(name: "encoding", value: "linear16"),
        URLQueryItem(name: "sample_rate", value: "16000"),
        URLQueryItem(name: "eager_eot_threshold", value: "0.5"),
        URLQueryItem(name: "eot_threshold", value: "0.7")
    ] + ["Notes", "Arc", "Photo Booth"].map { URLQueryItem(name: "keyterm", value: $0) }
    return components.url!
}

struct PCMChunks {
    var pending = Data()
    let size = 2560 // 80 ms × 16,000 samples/sec × 2 bytes, mono.
    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var result: [Data] = []
        while pending.count >= size {
            result.append(Data(pending.prefix(size)))
            pending.removeFirst(size)
        }
        return result
    }
    mutating func finish() -> Data {
        defer { pending.removeAll() }
        return pending
    }
}

final class Microphone {
    private let engine = AVAudioEngine()
    private var tapped = false
    private var chunks = PCMChunks()
    private let lock = NSLock()

    func start(send: @escaping (Data) -> Void, fail: @escaping (String) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: output) else {
            throw NSError(domain: "SpeechTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No usable microphone input was found."])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / format.sampleRate) + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true
                state.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil else { fail("Microphone conversion failed."); return }
            guard converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }
            let data = Data(bytes: samples, count: Int(converted.frameLength) * 2)
            self.lock.lock()
            let packets = self.chunks.append(data)
            self.lock.unlock()
            packets.forEach(send)
        }
        tapped = true
        engine.prepare()
        try engine.start()
    }

    func stop() -> Data {
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        lock.lock(); defer { lock.unlock() }
        return chunks.finish()
    }
}

@MainActor final class SpeechSession {
    var onChange: (() -> Void)?
    var status = "Ready"
    var state = TranscriptState()
    var events: [String] = []
    var connectionMS: Double?
    var firstTextMS: Double?
    var backlogMS: Double?
    var running = false
    private var generation = UUID()
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var mic: Microphone?
    private var continuation: AsyncStream<Data>.Continuation?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var connectionStart = 0.0
    private var micStart: Double?
    private var sentBytes = 0
    private var stopping = false

    func start(key: String) {
        guard !running else { return }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else {
            status = "Enter your Deepgram API key first."; onChange?(); return
        }
        generation = UUID()
        let id = generation
        state = TranscriptState(); events = []; connectionMS = nil; firstTextMS = nil
        backlogMS = nil; sentBytes = 0; micStart = nil; stopping = false
        running = true; status = "Checking microphone…"; onChange?()
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard self.generation == id, self.running else { return }
            guard allowed else { self.finish("Microphone access is needed. Enable Speech Test in System Settings → Privacy & Security → Microphone."); return }
            self.connect(key: key, id: id)
        }
    }

    private func connect(key: String, id: UUID) {
        var request = URLRequest(url: fluxURL())
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 90
        let transport = URLSession(configuration: config)
        session = transport
        let ws = transport.webSocketTask(with: request)
        socket = ws
        connectionStart = ProcessInfo.processInfo.systemUptime
        status = "Connecting to Deepgram…"; onChange?()
        ws.resume()
        timeout = Task {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, self.generation == id, self.mic == nil else { return }
            self.finish("Connection timed out. Check your key and network, then try again.")
        }
        receiver = Task {
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    guard self.generation == id, self.running else { return }
                    let data: Data
                    switch message {
                    case .data(let bytes): data = bytes
                    case .string(let text): data = Data(text.utf8)
                    @unknown default: continue
                    }
                    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    self.receive(value, id: id)
                }
            } catch {
                guard self.generation == id, self.running else { return }
                if self.stopping { self.finish("Stopped. The last live phrase is preserved below.") }
                else if let code = (ws.response as? HTTPURLResponse)?.statusCode, code != 101 {
                    self.finish("Deepgram rejected the connection (HTTP \(code)). Check the API key and project access.")
                } else { self.finish("Connection ended unexpectedly. Your visible transcript is preserved; check your key or network.") }
            }
        }
    }

    private func receive(_ message: [String: Any], id: UUID) {
        let type = message["type"] as? String ?? ""
        if type == "Connected" {
            guard mic == nil, !stopping else { return }
            timeout?.cancel()
            connectionMS = (ProcessInfo.processInfo.systemUptime - connectionStart) * 1000
            beginAudio(id: id)
        } else if type == "Error" {
            // Do not display arbitrary server output; it could contain request data.
            finish("Deepgram reported an error. Check the API key, available credits, and connection.")
        } else if type == "TurnInfo" {
            guard state.apply(message) else { return }
            let event = message["event"] as? String ?? "Update"
            let text = message["transcript"] as? String ?? ""
            let elapsed = micStart.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
            if !text.isEmpty, firstTextMS == nil { firstTextMS = elapsed * 1000 }
            if let end = number(message["audio_window_end"]) {
                backlogMS = max(0, Double(sentBytes) / 32000 - end) * 1000
            }
            if !text.isEmpty {
                let metadata = "turn \((state.turn ?? 0) + 1) · seq \(state.lastSequence) · finished \(percent(state.turnConfidence))"
                let cause = state.trigger.map { " · \($0)" } ?? ""
                events.append(String(format: "%6.2fs  %@ [%@%@]: %@", elapsed, event, metadata, cause, text))
                if events.count > 300 { events.removeFirst(events.count - 300) }
            }
            if !stopping { status = event == "EndOfTurn" ? "Listening · phrase completed" : "Listening · \(event)" }
            onChange?()
        }
    }

    private func beginAudio(id: UUID) {
        var output: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(25)) { output = $0 }
        continuation = output
        let audio = Microphone()
        mic = audio
        micStart = ProcessInfo.processInfo.systemUptime
        do {
            try audio.start(send: { bytes in
                if case .dropped = output.yield(bytes) {
                    Task { @MainActor in
                        guard self.generation == id, self.running else { return }
                        self.finish("Upload fell behind the microphone. Stopped rather than silently dropping speech.")
                    }
                }
            }, fail: { reason in
                Task { @MainActor in
                    guard self.generation == id, self.running else { return }
                    self.finish(reason)
                }
            })
        } catch { finish("Could not start the microphone: \(error.localizedDescription)"); return }
        guard let ws = socket else { return }
        sender = Task {
            do {
                for await bytes in stream {
                    guard self.generation == id, self.running, !Task.isCancelled else { return }
                    try await ws.send(.data(bytes))
                    self.sentBytes += bytes.count
                }
                guard self.generation == id, self.running, !Task.isCancelled else { return }
                // Flux CloseStream drains remaining audio but does not emit EndOfTurn.
                try await ws.send(.string("{\"type\":\"CloseStream\"}"))
            } catch {
                guard self.generation == id, self.running else { return }
                self.finish("Audio upload failed. The transcript received so far is preserved.")
            }
        }
        deadline = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, self.generation == id else { return }
            self.stop()
        }
        status = "Listening · speak now (60-second limit)"; onChange?()
    }

    func stop() {
        guard running, !stopping else { return }
        stopping = true; deadline?.cancel(); timeout?.cancel()
        guard let audio = mic else { finish("Stopped."); return }
        let tail = audio.stop()
        if !tail.isEmpty { continuation?.yield(tail) }
        continuation?.finish()
        status = "Microphone off · receiving remaining text…"; onChange?()
        timeout = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, self.running else { return }
            self.finish("Stopped. The last live phrase is preserved below.")
        }
    }

    func finish(_ message: String) {
        generation = UUID(); running = false
        _ = mic?.stop(); mic = nil
        continuation?.finish(); continuation = nil
        receiver?.cancel(); sender?.cancel(); deadline?.cancel(); timeout?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        status = message; onChange?()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = SpeechSession()
    var window: NSWindow!
    let key = NSSecureTextField()
    let typesafeKey = NSSecureTextField()
    let keyStore = KeyStore()
    let saveKeysButton = NSButton(title: "Save keys", target: nil, action: nil)
    let forgetKeysButton = NSButton(title: "Forget keys", target: nil, action: nil)
    let keyStatus = NSTextField(wrappingLabelWithString: "Keys are saved in macOS Keychain.")
    let startButton = NSButton(title: "Start listening", target: nil, action: nil)
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "Ready")
    let timing = NSTextField(labelWithString: "Connection —     First text —     Audio backlog —")
    let turnInfo = NSTextField(labelWithString: "Finished speaking —")
    let live = NSTextView()
    let completed = NSTextView()
    let events = NSTextView()
    let words = NSTextView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); item.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Speech Test", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, action, shortcut) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: shortcut)
        }
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Speech Test — Deepgram Flux"; window.delegate = self
        window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
            let view = NSTextField(wrappingLabelWithString: text)
            view.font = .systemFont(ofSize: size, weight: weight)
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return view
        }
        _ = label("Speak. See the words arrive.", size: 26, weight: .semibold)
        _ = label("Deepgram Flux · English · app hints: Notes, Arc, Photo Booth", size: 13)
        key.placeholderString = "Deepgram API key"
        key.setAccessibilityLabel("Deepgram API key")
        typesafeKey.placeholderString = "Typesafe API key — optional, for next step"
        typesafeKey.setAccessibilityLabel("Typesafe API key")
        let keyFields = NSStackView(views: [key, typesafeKey]); keyFields.spacing = 10; keyFields.distribution = .fillEqually
        stack.addArrangedSubview(keyFields)
        keyFields.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        keyFields.heightAnchor.constraint(equalToConstant: 28).isActive = true
        startButton.target = self; startButton.action = #selector(start)
        stopButton.target = self; stopButton.action = #selector(stop); stopButton.keyEquivalent = "\u{1b}"
        startButton.bezelStyle = .rounded; stopButton.bezelStyle = .rounded
        saveKeysButton.target = self; saveKeysButton.action = #selector(saveKeys)
        forgetKeysButton.target = self; forgetKeysButton.action = #selector(forgetKeys)
        saveKeysButton.bezelStyle = .rounded; forgetKeysButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [startButton, stopButton, saveKeysButton, forgetKeysButton]); buttons.spacing = 10
        stack.addArrangedSubview(buttons)
        keyStatus.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(keyStatus)
        keyStatus.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        loadKeys()
        status.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(status); status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        timing.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(timing)
        _ = label("Audio goes to Deepgram while listening. Each test stops after 60 seconds.", size: 11)
        func textBox(_ view: NSTextView, title: String, fontSize: CGFloat) -> NSScrollView {
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
            view.isEditable = false; view.isSelectable = true
            view.font = .systemFont(ofSize: fontSize)
            view.textContainerInset = NSSize(width: 10, height: 9)
            view.autoresizingMask = [.width]; view.isVerticallyResizable = true
            view.isHorizontallyResizable = false; view.textContainer?.widthTracksTextView = true
            view.setAccessibilityLabel(title)
            scroll.documentView = view
            return scroll
        }
        _ = label("Live phrase · may change", size: 12, weight: .semibold)
        let liveBox = textBox(live, title: "Live phrase · may change", fontSize: 20)
        stack.addArrangedSubview(liveBox)
        liveBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        liveBox.heightAnchor.constraint(equalToConstant: 70).isActive = true
        live.textColor = .secondaryLabelColor
        turnInfo.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(turnInfo)
        _ = label("Finished speaking is Deepgram’s turn estimate; word confidence measures transcription certainty.", size: 11)
        let tabs = NSTabView()
        for (title, view, size) in [("Word details", words, CGFloat(12)), ("Completed phrases", completed, CGFloat(17)), ("Events", events, CGFloat(11))] {
            let tab = NSTabViewItem(identifier: title); tab.label = title
            tab.view = textBox(view, title: title, fontSize: size)
            tabs.addTabViewItem(tab)
        }
        stack.addArrangedSubview(tabs)
        tabs.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        tabs.heightAnchor.constraint(equalToConstant: 165).isActive = true
        words.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [190, 300, 420].map { NSTextTab(textAlignment: .left, location: CGFloat($0)) }
        words.defaultParagraphStyle = paragraph
        events.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        _ = label("Word times are positions in the audio, not recognition latency. First text includes initial silence; audio backlog estimates unprocessed audio. Missing metadata appears as —.", size: 11)
        model.onChange = { [weak self] in self?.refresh() }
        refresh()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func loadKeys() {
        var loaded: [String] = []
        var failed: [String] = []
        for (name, field, variable) in [("Deepgram", key, "DEEPGRAM_API_KEY"), ("Typesafe", typesafeKey, "TYPESAFE_API_KEY")] {
            do {
                if let value = try keyStore.load(name) { field.stringValue = value; loaded.append(name) }
                else { field.stringValue = ProcessInfo.processInfo.environment[variable] ?? "" }
            } catch { failed.append(name) }
        }
        if !failed.isEmpty { keyStatus.stringValue = "Could not load \(failed.joined(separator: ", ")) from Keychain. You can paste a key for this session." }
        else if !loaded.isEmpty { keyStatus.stringValue = "Loaded \(loaded.joined(separator: " and ")) from macOS Keychain." }
        else { keyStatus.stringValue = "Keys save to macOS Keychain with Save keys or Start listening. Typesafe is not connected yet." }
    }

    @objc func saveKeys() {
        var saved: [String] = []
        var failed: [String] = []
        for (name, field) in [("Deepgram", key), ("Typesafe", typesafeKey)] {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue } // Clearing a field does not delete a saved key.
            guard !value.contains("\n"), !value.contains("\r") else { failed.append(name); continue }
            do { try keyStore.save(value, account: name); field.stringValue = value; saved.append(name) }
            catch { failed.append(name) }
        }
        let success = saved.isEmpty ? "" : "Saved \(saved.joined(separator: " and ")) in Keychain. "
        keyStatus.stringValue = success + (failed.isEmpty ? (saved.isEmpty ? "Enter a key to save. Blank fields leave saved keys unchanged." : "") : "Could not save \(failed.joined(separator: ", ")); those fields remain session-only.")
    }

    @objc func forgetKeys() {
        var failed: [String] = []
        for (name, field) in [("Deepgram", key), ("Typesafe", typesafeKey)] {
            do { try keyStore.forget(name); field.stringValue = "" }
            catch { failed.append(name) }
        }
        keyStatus.stringValue = failed.isEmpty ? "Saved keys removed from this Mac. Provider keys have not been revoked." : "Could not remove \(failed.joined(separator: ", ")) from Keychain. Other keys were removed."
    }

    @objc func start() {
        if !key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { saveKeys() }
        model.start(key: key.stringValue)
    }
    @objc func stop() { model.stop() }
    func refresh() {
        status.stringValue = model.status
        func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
        timing.stringValue = "Connection \(ms(model.connectionMS))     First text \(ms(model.firstTextMS))     Audio backlog \(ms(model.backlogMS))"
        live.string = model.state.partial; completed.string = model.state.text
        let turn = model.state.turn.map { " · turn \($0 + 1) · \(model.state.event)" } ?? ""
        let trigger = model.state.trigger.map { " · \($0)" } ?? ""
        turnInfo.stringValue = "Finished speaking \(percent(model.state.turnConfidence))\(turn)\(trigger)"
        words.string = model.state.wordDetails
        events.string = model.events.joined(separator: "\n")
        events.scrollToEndOfDocument(nil)
        startButton.isEnabled = !model.running; stopButton.isEnabled = model.running; key.isEnabled = !model.running
        typesafeKey.isEnabled = !model.running; saveKeysButton.isEnabled = !model.running; forgetKeysButton.isEnabled = !model.running
    }
    func applicationWillTerminate(_ notification: Notification) { model.finish("Stopped"); key.stringValue = ""; typesafeKey.stringValue = "" }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

func selfTest() {
    func message(_ seq: Int, _ event: String, _ turn: Int, _ text: String) -> [String: Any] {
        ["type": "TurnInfo", "sequence_id": seq, "event": event, "turn_index": turn, "transcript": text]
    }
    var state = TranscriptState()
    state.apply(message(0, "Update", 0, "Open boats"))
    state.apply(message(1, "Update", 0, "Open Notes"))
    precondition(state.partial == "Open Notes" && state.text.isEmpty)
    state.apply(message(2, "EagerEndOfTurn", 0, "Open Notes"))
    precondition(state.text.isEmpty, "Early turn endings must remain provisional")
    state.apply(message(3, "TurnResumed", 0, "Open Notes actually Arc"))
    state.apply(message(4, "EndOfTurn", 0, "Open Notes, actually Arc."))
    state.apply(message(4, "EndOfTurn", 0, "duplicate"))
    state.apply(message(1, "Update", 0, "stale"))
    precondition(state.text == "Open Notes, actually Arc." && state.partial.isEmpty)
    state.apply(message(5, "StartOfTurn", 1, "Hello"))
    precondition(state.partial == "Hello" && state.completed.count == 1)
    // A stream closed without EndOfTurn must retain the unfinalized phrase.
    state.apply(["type": "Connected"])
    precondition(state.partial == "Hello")
    // Decode representative wire JSON, including string-valued numeric metadata.
    let wire = Data(#"{"type":"TurnInfo","sequence_id":6,"event":"Update","turn_index":1,"transcript":"Open Notes","end_of_turn_confidence":"0.42","words":[{"word":"Open","confidence":0.99,"start":1.2,"end":1.45},{"word":"Notes","confidence":"0.87","start":"1.5","end":"1.82"}]}"#.utf8)
    let decoded = try! JSONSerialization.jsonObject(with: wire) as! [String: Any]
    precondition(state.apply(decoded))
    precondition(state.words.count == 2 && state.turnConfidence == 0.42)
    precondition(state.words[1].confidence == 0.87 && state.words[1].end == 1.82)
    precondition(state.wordDetails.contains("Notes\t87.0%\t1.500s\t1.820s"))
    precondition(!state.apply(message(5, "Update", 1, "stale")))
    precondition(state.words.count == 2 && state.turnConfidence == 0.42)
    var revised = message(7, "TurnResumed", 1, "Open Arc")
    revised["words"] = [["word": "Open", "confidence": 0.99], ["word": "Arc", "confidence": "0.93"]]
    state.apply(revised)
    precondition(state.words[1].word == "Arc" && state.words[1].start == nil)
    precondition(state.turnConfidence == nil && !state.wordDetails.contains("Notes"))
    precondition(state.wordDetails.contains("Arc\t93.0%\t—\t—"))
    var final = message(8, "EndOfTurn", 1, "Open Arc")
    final["words"] = revised["words"]; final["end_of_turn_confidence"] = 0.85; final["trigger"] = "timeout"
    state.apply(final)
    precondition(state.trigger == "timeout" && state.words.count == 2)
    state.apply(message(9, "Update", 2, ""))
    precondition(state.wordTurn == 1 && state.turn == 2 && state.trigger == nil)
    precondition(number("nan") == nil && probability(1.5) == nil)
    let invalid = WordInfo(["word": "test", "confidence": -1, "start": 2, "end": 1])!
    precondition(invalid.confidence == nil && invalid.end == nil)
    let hints = URLComponents(url: fluxURL(), resolvingAgainstBaseURL: false)!.queryItems!.filter { $0.name == "keyterm" }.compactMap(\.value)
    precondition(hints == ["Notes", "Arc", "Photo Booth"])
    var chunks = PCMChunks()
    let original = Data((0..<9998).map { UInt8($0 % 251) })
    var packets: [Data] = []
    for offset in stride(from: 0, to: original.count, by: 718) {
        packets += chunks.append(original.subdata(in: offset..<min(offset + 718, original.count)))
    }
    precondition(packets.allSatisfy { $0.count == 2560 })
    let tail = chunks.finish()
    precondition(packets.reduce(Data(), +) + tail == original)
    precondition(chunks.finish().isEmpty)
    print("PASS: transcript lifecycle, wire metadata parsing, missing/invalid fields, revised words, stale events, preserved word details, keyterm encoding, and lossless 80 ms PCM chunking")
}

// Separate-process integration test using an isolated service and dummy data only.
func keychainTest(_ mode: String, identifier: String) throws {
    let store = KeyStore(service: "local.speechtest.self-test." + identifier)
    if mode == "write" {
        let existing = try store.load("fixture")
        precondition(existing == nil)
        try store.save("dummy-original", account: "fixture")
        try store.save("dummy-updated", account: "fixture")
    } else if mode == "read" {
        let loaded = try store.load("fixture")
        precondition(loaded == "dummy-updated")
    } else if mode == "delete" {
        try store.forget("fixture")
        let deleted = try store.load("fixture")
        precondition(deleted == nil)
        try store.forget("fixture")
    }
    print("PASS: Keychain \(mode)")
}

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--keychain-test" {
    do { try keychainTest(CommandLine.arguments[2], identifier: CommandLine.arguments[3]) }
    catch { fputs("Keychain integration test failed.\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--self-test") {
    selfTest()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
