import AppKit
import ApplicationServices
import Foundation

public enum AXReader {
    private static let enablement = AXEnablement()

    static func invalidateEnablement(pid: pid_t) { enablement.invalidate(pid: pid) }

    public static func captureReady(pid: pid_t? = nil, maxNodes: Int = 1_500,
                                    seconds: TimeInterval = 1.5, promptForPermission: Bool = true) async throws -> AXSnapshot {
        try await whenSurfaceReady {
            try await cancellableNative {
                try capture(maxNodes: maxNodes, seconds: seconds, pid: pid, promptForPermission: promptForPermission)
            }
        }
    }

    /// A foreground PID can precede its accessible surface during startup or a transition.
    /// Retry observation only; an input action is never part of this wait.
    static func whenSurfaceReady<T>(read: () async throws -> T,
                                   wait: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) async throws -> T {
        for attempt in 0..<12 {
            try Task.checkCancellation()
            do { return try await read() }
            catch AXFailure.noWindow {
                if attempt == 11 { throw AXFailure.noWindow }
                try await wait(UInt64(min(200, 50 * (attempt + 1))) * 1_000_000)
            }
        }
        throw AXFailure.noWindow
    }

    public static func capture(maxNodes: Int = 1_500, seconds: TimeInterval = 1.5,
                               allChildren: Bool = false, pid requestedPID: pid_t? = nil,
                               promptForPermission: Bool = true, subtree: AXUIElement? = nil) throws -> AXSnapshot {
        let started = Date()
        guard AXIsProcessTrusted() else {
            if promptForPermission {
                _ = AXIsProcessTrustedWithOptions(
                    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            throw AXFailure.permission
        }
        let application = requestedPID.map { NSRunningApplication(processIdentifier: $0) } ?? NSWorkspace.shared.frontmostApplication
        guard let app = application else { throw AXFailure.noWindow }
        let pid = app.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.2)
        // These are alternate setup capabilities. Cache only accepted setup, with
        // a known process lifetime; failed and unreadable lifetimes retry normally.
        enablement.ensure(pid: pid, launchedAt: app.launchDate) {
            let manual = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, true as CFTypeRef)
            let enhanced = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
            return manual == .success || enhanced == .success
        }
        let window = applicationWindow(root)
        let applicationWindows = attribute(root, "AXWindows") as? [AXUIElement]
        let menu = element(attribute(root, "AXMenuBar"))
        guard let surface = subtree ?? window ?? menu else {
            enablement.invalidate(pid: pid)
            throw AXFailure.noWindow
        }
        let title = window.map { string($0, kAXTitleAttribute as String) } ?? "\(app.localizedName ?? "App") menu bar"
        var nodes: [AXNode] = []
        var handles: [AXUIElement] = []
        var queue: [(AXUIElement, Int?, Int, CGRect?)] = [(surface, nil, 0, nil)]
        if subtree == nil, window != nil, let menu {
            queue.append((menu, nil, 0, nil))
        }
        var seen: [CFHashCode: [AXUIElement]] = [:]
        var partial = subtree != nil
        var coverage: [AXCoverageGap] = subtree == nil ? [] : [AXCoverageGap(nodeID: 0, reason: .region)]
        var next = 0
        let deadline = Date().addingTimeInterval(seconds)
        while next < queue.count, nodes.count < maxNodes, Date() < deadline {
            try Task.checkCancellation()
            let (element, parent, depth, clip) = queue[next]
            next += 1
            let hash = CFHash(element)
            if seen[hash, default: []].contains(where: { CFEqual($0, element) }) { continue }
            seen[hash, default: []].append(element)
            AXUIElementSetMessagingTimeout(element, 0.2)
            let id = nodes.count
            let attrs = attributes(element, ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXHelp",
                                             "AXValue", "AXEnabled", "AXHidden", "AXPosition", "AXSize",
                                             "AXFocused", "AXSelected", "AXIdentifier", "AXMinValue", "AXMaxValue", "AXURL", "AXOrientation", "AXDocument"])
            func text(_ key: String) -> String { AXReader.rendered(attrs[key]) }
            let role = text("AXRole")
            if role.isEmpty { partial = true; coverage.append(AXCoverageGap(nodeID: parent, reason: .unreadable)) }
            let subrole = text("AXSubrole")
            let help = text("AXHelp")
            let label = firstNonempty([text("AXTitle"), text("AXDescription"), help])
            let sensitiveEditor = subrole == "AXSecureTextField" ||
                (["AXTextArea", "AXTextField"].contains(role) && title.range(of: #"(?:^|[\s/])\.env(?:\b|$)"#, options: .regularExpression) != nil)
            let value = sensitiveEditor ? "[REDACTED SENSITIVE EDITOR]" : firstNonempty([text("AXValue"), text("AXURL")])
            let bounds = frame(position: attrs["AXPosition"], dimension: attrs["AXSize"])
            if attrs["AXHidden"] as? Bool == true { coverage.append(AXCoverageGap(nodeID: parent, reason: .hidden)); continue }
            let visible = isVisible(bounds: bounds, clip: clip)
            if !allChildren, !visible { partial = true; coverage.append(AXCoverageGap(nodeID: parent, reason: .clipped)); continue }
            var actionNames: CFArray?
            AXUIElementCopyActionNames(element, &actionNames)
            let actions = (actionNames as? [String]) ?? []
            let enabled = attrs["AXEnabled"] as? Bool ?? true
            let canSetValue = ["AXSlider", "AXIncrementor"].contains(role) && settable(element, "AXValue")
            var childCount: CFIndex = 0
            let isCollection = ["AXTable", "AXOutline", "AXList", "AXGrid"].contains(role)
            let counted = isCollection && AXUIElementGetAttributeValueCount(element, "AXChildren" as CFString, &childCount) == .success
            nodes.append(AXNode(id: id, parent: parent, depth: depth, role: role, subrole: subrole,
                                label: clipped(label, 180), value: String(value.prefix(2_000)),
                                actions: actions, enabled: enabled, frame: bounds,
                                help: clipped(help, 200), identifier: text("AXIdentifier"),
                                focused: attrs["AXFocused"] as? Bool ?? false,
                                selected: attrs["AXSelected"] as? Bool ?? false,
                                writableValue: canSetValue,
                                writableSelection: role == "AXRow" && settable(element, "AXSelected"),
                                minimum: attrs["AXMinValue"] as? Double, maximum: attrs["AXMaxValue"] as? Double,
                                childCount: counted ? childCount : nil, visible: visible, orientation: text("AXOrientation"), document: text("AXDocument")))
            handles.append(element)
            // Closed menu contents are discovered after opening the menu.
            if role == "AXMenu", bounds == nil { continue }
            var children: [AXUIElement]?
            if !allChildren, isCollection {
                let selection = collectionChildren { attribute(element, $0) as? [AXUIElement] }
                children = selection.children
                if selection.visibleOnly { partial = true; coverage.append(AXCoverageGap(nodeID: id, reason: .visibleCollection)) }
            } else {
                children = attribute(element, "AXChildren") as? [AXUIElement]
            }
            let childClip: CGRect?
            if !visible { childClip = .null }
            else if AXGrouping.clipAncestors.contains(role), let bounds {
                childClip = clip.map { $0.intersection(bounds) } ?? bounds
            } else { childClip = clip }
            if depth < 35, let children {
                for child in children { queue.append((child, id, depth + 1, childClip)) }
            } else if !(children ?? []).isEmpty {
                partial = true
                coverage.append(AXCoverageGap(nodeID: id, reason: .depth))
            }
        }
        if next < queue.count { coverage.append(AXCoverageGap(nodeID: nil, reason: .budget)) }
        return AXSnapshot(pid: pid, appName: app.localizedName ?? app.bundleIdentifier ?? "App",
                          windowTitle: title, nodes: nodes, partial: partial || next < queue.count, handles: handles,
                          readSeconds: Date().timeIntervalSince(started), windowHandle: window, menuBarHandle: menu,
                          bundleID: app.bundleIdentifier, coverage: coverage, applicationWindows: applicationWindows)
    }

    static func isVisible(bounds: CGRect?, clip: CGRect?) -> Bool {
        guard clip?.isNull != true else { return false }
        return clip == nil || bounds == nil || clip!.intersects(bounds!)
    }

    /// Some providers expose an empty row list for a populated non-row collection.
    /// Try both visibility attributes before ordinary children; normal geometry,
    /// hidden-state and traversal-budget checks still apply to every returned child.
    static func collectionChildren<Element>(read: (String) -> [Element]?) -> (children: [Element]?, visibleOnly: Bool) {
        for name in ["AXVisibleRows", "AXVisibleChildren"] {
            if let children = read(name), !children.isEmpty { return (children, true) }
        }
        return (read("AXChildren"), false)
    }

    static func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var value = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &value) == .success && value.boolValue
    }

    static func attributes(_ element: AXUIElement, _ names: [String]) -> [String: Any] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
              let values = values as? [Any], values.count == names.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(names, values).map { ($0, $1) })
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    /// Accessibility providers are other processes. Validate their CF types before use.
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // Swift cannot conditionally downcast CF types; the type ID guard makes this bridge safe.
        return (value as! AXUIElement)
    }

    static func attributeElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        self.element(attribute(element, name))
    }

    static func axValue(_ value: Any?) -> AXValue? {
        guard let value else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
        // Swift cannot conditionally downcast CF types; the type ID guard makes this bridge safe.
        return (cfValue as! AXValue)
    }

    static func applicationWindow(_ app: AXUIElement) -> AXUIElement? {
        element(attribute(app, "AXFocusedWindow")) ?? element(attribute(app, "AXMainWindow")) ??
            (attribute(app, "AXWindows") as? [AXUIElement])?.first
    }

    static func rendered(_ value: Any?) -> String {
        if let text = value as? String { return SensitiveText.redact(text) }
        if let number = value as? NSNumber { return number.stringValue }
        if let url = value as? URL { return url.absoluteString }
        return ""
    }

    static func string(_ element: AXUIElement, _ name: String) -> String {
        guard let value = attribute(element, name) else { return "" }
        if value is URL { return "" }
        return rendered(value)
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        frame(position: attribute(element, kAXPositionAttribute as String),
              dimension: attribute(element, kAXSizeAttribute as String))
    }

    static func frame(position: Any?, dimension: Any?) -> CGRect? {
        guard let p = axValue(position), let s = axValue(dimension) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func firstNonempty(_ values: [String]) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    static func clipped(_ text: String, _ maximum: Int) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > maximum ? String(clean.prefix(maximum)) + "…" : clean
    }
}
