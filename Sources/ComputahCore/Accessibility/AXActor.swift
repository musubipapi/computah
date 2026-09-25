import AppKit
import ApplicationServices
import Foundation

public enum AXActor {
    public static func inspectFocus(in snapshot: AXSnapshot, targetID: Int? = nil) -> String {
        let app = AXUIElementCreateApplication(snapshot.pid)
        var current = AXReader.attributeElement(app, "AXFocusedUIElement")
        var lines: [String] = []
        for _ in 0..<12 {
            guard let element = current else { break }
            let id = snapshot.handles.firstIndex(where: { CFEqual($0, element) })
            lines.append("focus ancestor node=\(id.map(String.init) ?? "uncaptured") role=\(AXReader.string(element, "AXRole")) label=\(AXReader.string(element, "AXDescription"))")
            current = AXReader.attributeElement(element, "AXParent")
        }
        for node in snapshot.nodes where (targetID == nil || node.id == targetID) &&
            AXGrouping.editable.contains(node.role) && snapshot.handles.indices.contains(node.id) {
            let element = snapshot.handles[node.id]
            lines.append("editor node=\(node.id) label=\(node.label) live AXFocused=\(AXReader.string(element, "AXFocused")) bound focus=\(isFocused(element, app: app))")
        }
        return lines.joined(separator: "\n")
    }

    public static func inspectClick(_ candidate: AXCandidate, in snapshot: AXSnapshot, hover: Bool = false) -> String {
        guard snapshot.nodes.indices.contains(candidate.nodeID), let point = snapshot.nodes[candidate.nodeID].frame?.center else { return "No point" }
        if hover, NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
        let firstID = hit.flatMap { first in snapshot.handles.firstIndex(where: { CFEqual($0, first) }) }
        Thread.sleep(forTimeInterval: 0.05)
        _ = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
        var path: [String] = []
        for _ in 0..<40 {
            guard let element = hit else { break }
            let id = snapshot.handles.firstIndex(where: { CFEqual($0, element) })
            path.append("node=\(id.map(String.init) ?? "outside snapshot") \(AXReader.string(element, "AXRole")) \(AXReader.string(element, "AXDescription")) frame=\(String(describing: AXReader.frame(element)))")
            hit = AXReader.attributeElement(element, "AXParent")
        }
        let parent = snapshot.nodes[candidate.nodeID].parent
        let siblings = snapshot.nodes.filter { $0.parent == parent }.map { "\($0.id):\($0.role):\($0.label)" }.joined(separator: ", ")
        return "target=\(candidate.nodeID) parent=\(parent.map(String.init) ?? "none") siblings=[\(siblings)] point=\(point) result=\(result.rawValue) initial=\(firstID.map(String.init) ?? "outside snapshot") after50ms=" + path.joined(separator: " → ")
    }

    @discardableResult public static func perform(_ candidate: AXCandidate, in snapshot: AXSnapshot, text: String?,
                               permit: InputPermit = .standalone(), physicalActivation: Bool = true) throws -> String {
        try permit.check()
        let foreground = NSWorkspace.shared.frontmostApplication
        guard foreground?.processIdentifier == snapshot.pid else {
            throw AXFailure.unavailable(
                "\(snapshot.appName) was no longer frontmost (now \(foreground?.localizedName ?? "unknown")).")
        }
        guard snapshot.handles.indices.contains(candidate.nodeID), snapshot.nodes.indices.contains(candidate.nodeID) else { throw AXFailure.changed }
        if let expectedWindow = snapshot.windowHandle {
            let app = AXUIElementCreateApplication(snapshot.pid)
            guard let focused = (AXReader.attributeElement(app, "AXFocusedWindow") ?? AXReader.attributeElement(app, "AXMainWindow")),
                  CFEqual(focused, expectedWindow) else { throw AXFailure.changed }
        }
        let element = snapshot.handles[candidate.nodeID]
        if snapshot.isMenuOnly { try validateMenuOnlySurface(element, snapshot: snapshot) }
        let original = snapshot.nodes[candidate.nodeID]
        let currentLabel = AXReader.firstNonempty([
            AXReader.string(element, kAXTitleAttribute as String),
            AXReader.string(element, kAXDescriptionAttribute as String),
            AXReader.string(element, kAXHelpAttribute as String),
        ])
        guard AXReader.string(element, kAXRoleAttribute as String) == original.role,
              AXReader.clipped(currentLabel, 180) == original.label,
              (AXReader.attribute(element, kAXEnabledAttribute as String) as? Bool) != false else {
            throw AXFailure.changed
        }
        // Every transport must retain the same observed object, not just its label.
        try validateBinding(candidate, snapshot: snapshot)
        try validateNativeSurface(element, snapshot: snapshot)
        switch candidate.operation {
        case .pressReturn:
            let app = AXUIElementCreateApplication(snapshot.pid)
            guard isFocused(element, app: app),
                  AXGrouping.editable.contains(original.role),
                  original.subrole != "AXSecureTextField" else {
                throw AXFailure.unavailable("The observed editor is no longer focused; no Return key sent.\n" +
                    inspectFocus(in: snapshot, targetID: candidate.nodeID))
            }
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else {
                throw AXFailure.unavailable("Could not create Return key events.")
            }
            down.flags = []
            up.flags = []
            try permit.pair(down: { down.post(tap: .cghidEventTap) }, up: { up.post(tap: .cghidEventTap) })
        case .select:
            guard AXReader.settable(element, "AXSelected"),
                  try permit.perform({ AXUIElementSetAttributeValue(element, "AXSelected" as CFString, true as CFTypeRef) }) == .success else {
                throw AXFailure.unavailable("Row selection was not accepted; outcome unknown.")
            }
        case .setNumber:
            guard let text, let requested = Double(text.replacingOccurrences(of: "%", with: "")),
                  requested.isFinite,
                  let minimum = original.minimum, let maximum = original.maximum, maximum > minimum else {
                throw AXFailure.unavailable("The control needs an observed numeric range and a requested value.")
            }
            guard AXReader.attribute(element, "AXMinValue") as? Double == minimum,
                  AXReader.attribute(element, "AXMaxValue") as? Double == maximum else { throw AXFailure.changed }
            let value = text.contains("%") ? minimum + (maximum - minimum) * requested / 100 : requested
            guard (minimum...maximum).contains(value) else { throw AXFailure.unavailable("Requested value is outside the control's range.") }
            if ["AXSlider", "AXIncrementor"].contains(original.role), original.actions.contains("AXIncrement"), original.actions.contains("AXDecrement") {
                try adjustSlider(element, target: value, minimum: minimum, maximum: maximum, snapshot: snapshot, permit: permit)
                break
            }
            guard AXReader.settable(element, "AXValue"),
                  try permit.perform({ AXUIElementSetAttributeValue(element, "AXValue" as CFString, NSNumber(value: value)) }) == .success else {
                throw AXFailure.unavailable("Numeric input was not accepted; outcome unknown.")
            }
        case .showMenu, .increment, .decrement:
            let action = candidate.operation == .showMenu ? "AXShowMenu" :
                candidate.operation == .increment ? "AXIncrement" : "AXDecrement"
            guard try permit.perform({ AXUIElementPerformAction(element, action as CFString) }) == .success else {
                throw AXFailure.unavailable("\(action) failed; the action outcome is unknown.")
            }
        case .pressClick:
            var advertised: CFArray?
            let canActivate = AXUIElementCopyActionNames(element, &advertised) == .success &&
                (advertised as? [String] ?? []).contains("AXPress")
            func nativeActivation() throws -> String {
                _ = try visiblePoint(element, snapshot: snapshot)
                try validateNativeSurface(element, snapshot: snapshot)
                try validateBinding(candidate, snapshot: snapshot)
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid,
                      (AXReader.attribute(element, "AXEnabled") as? Bool) != false else { throw AXFailure.changed }
                let status = try permit.perform { AXUIElementPerformAction(element, "AXPress" as CFString) }
                return "AXPress dispatched; native status=\(status.rawValue); effect awaits observation."
            }
            if !physicalActivation, canActivate { return try nativeActivation() }
            let dispatched = permit.dispatchCount
            do {
                try checkedClick(element, original: original, snapshot: snapshot, permit: permit, candidate: candidate)
                return "Physical click dispatched; effect awaits observation."
            } catch AXFailure.pointerTargetUnknown {
                // No click occurred. A validated native capability can address the
                // object directly; never infer that its wrapper forwards pointer input.
                guard canActivate, permit.dispatchCount == dispatched else { throw AXFailure.pointerTargetUnknown }
                try permit.check()
                return try nativeActivation()
            }
        case .typeText, .replaceText:
            guard let text, !text.isEmpty else { throw AXFailure.unavailable("No literal text was provided.") }
            let app = AXUIElementCreateApplication(snapshot.pid)
            if !isFocused(element, app: app) {
                var canFocus = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &canFocus) == .success,
                   canFocus.boolValue {
                    _ = try permit.perform { AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef) }
                }
                if !isFocused(element, app: app) {
                    try checkedClick(element, original: original, snapshot: snapshot, permit: permit, candidate: candidate)
                    _ = try poll(15, permit: permit) {
                        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { throw AXFailure.changed }
                        return isFocused(element, app: app)
                    }
                }
                guard isFocused(element, app: app) else {
                    throw AXFailure.unavailable("The editor could not be focused; no text was sent.")
                }
            }
            // Focusing may reveal a different bound object before the first text event.
            try validateBinding(candidate, snapshot: snapshot)
            try validateNativeSurface(element, snapshot: snapshot)
            if candidate.operation == .replaceText {
                guard AXReader.string(element, "AXValue") == original.value else { throw AXFailure.changed }
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { throw AXFailure.changed }
                down.flags = .maskCommand; up.flags = .maskCommand
                try permit.pair(down: { down.post(tap: .cghidEventTap) }, up: { up.post(tap: .cghidEventTap) })
                let selected = try poll(10, permit: permit) {
                    guard isFocused(element, app: app) else { throw AXFailure.changed }
                    let focused = AXReader.attributeElement(app, kAXFocusedUIElementAttribute as String)
                    guard let rangeValue = AXReader.axValue(AXReader.attribute(focused ?? element, "AXSelectedTextRange")) else { return false }
                    var range = CFRange()
                    return AXValueGetValue(rangeValue, .cfRange, &range) && range.location == 0
                        && range.length == (original.value as NSString).length
                }
                guard selected else { throw AXFailure.unavailable("Could not verify selection of the existing field text; replacement was not typed.") }
            }
            for chunk in textChunks(text) {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid,
                      isFocused(element, app: app) else { throw AXFailure.changed }
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                    throw AXFailure.unavailable("Text event creation failed; earlier chunks may have been sent.")
                }
                down.flags = []; up.flags = []
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                try permit.pair(down: { down.post(tap: .cghidEventTap) }, up: { up.post(tap: .cghidEventTap) })
            }
            if candidate.operation == .replaceText {
                // Input has finished. A suggestion popup can take focus while
                // this same bound editor already contains the exact value.
                // Readback sends no input and must not require keyboard focus.
                let verified = try poll(15, permit: permit) { AXReader.string(element, "AXValue") == text }
                guard verified else { throw AXFailure.unavailable("Replacement text was dispatched but exact field readback did not match; no further input sent.") }
            }
        case .scrollUp, .scrollDown:
            let point = try visiblePoint(element, snapshot: snapshot)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
                  let hit, matchesClickTarget(element, hit: hit),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { throw AXFailure.changed }
            try validateBinding(candidate, snapshot: snapshot)
            let amount: Int32 = candidate.operation == .scrollDown ? -550 : 550
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: amount, wheel2: 0, wheel3: 0) else {
                throw AXFailure.unavailable("Could not create a scroll event.")
            }
            event.location = point
            try permit.perform { event.post(tap: .cghidEventTap) }
        }
        return "\(candidate.operation.rawValue) dispatched; effect awaits observation."
    }

    /// Each increment must produce an observed value before another is sent.
    /// This works with custom sliders whose advertised AXValue setter is inert.
    private static func adjustSlider(_ element: AXUIElement, target: Double, minimum: Double,
                                     maximum: Double, snapshot: AXSnapshot, permit: InputPermit) throws {
        let tolerance = max(0.00001, (maximum - minimum) * 0.001)
        for _ in 0..<100 {
            try permit.check()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid,
                  let current = Double(AXReader.string(element, "AXValue")), current.isFinite else { throw AXFailure.changed }
            if abs(current - target) <= tolerance { return }
            let direction = target > current ? 1.0 : -1.0
            let action = direction > 0 ? "AXIncrement" : "AXDecrement"
            guard try permit.perform({ AXUIElementPerformAction(element, action as CFString) }) == .success else {
                throw AXFailure.unavailable("Slider adjustment was not accepted; stopped without retrying.")
            }
            var observed = current
            for _ in 0..<10 {
                try permit.check()
                Thread.sleep(forTimeInterval: 0.02)
                guard let value = Double(AXReader.string(element, "AXValue")), value.isFinite else { throw AXFailure.changed }
                observed = value
                if abs(value - current) > tolerance { break }
            }
            guard (observed - current) * direction > tolerance else {
                throw AXFailure.unavailable("Slider adjustment had no observed effect; stopped without repeating it.")
            }
            if abs(observed - target) <= tolerance { return }
            guard (target - observed) * direction > 0 else {
                throw AXFailure.unavailable("The slider's observed step passed the requested value; exact result is unconfirmed.")
            }
        }
        throw AXFailure.unavailable("Stopped at the bounded slider adjustment limit; exact value is unconfirmed.")
    }

    /// Each keyboard event must contain complete UTF-16 scalars within its size budget.
    static func textChunks(_ text: String) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var chunk: [UInt16] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > 20 {
                chunks.append(chunk)
                chunk = []
            }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    private static func poll(_ times: Int, permit: InputPermit, until ready: () throws -> Bool) throws -> Bool {
        for _ in 0..<times {
            try permit.check()
            if try ready() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private static func isFocused(_ element: AXUIElement, app: AXUIElement) -> Bool {
        guard let focused = AXReader.attributeElement(app, kAXFocusedUIElementAttribute as String) else {
            return false
        }
        return isAncestor(element, of: focused)
    }

    static func bindingMatches(_ old: AXNode, role: String, label: String, value: String, identifier: String, document: String = "") -> Bool {
        old.role == role && old.label == AXReader.clipped(label, 180) &&
            (old.identifier.isEmpty || old.identifier == identifier) && old.document == document && old.value == String(value.prefix(2_000))
    }

    private static func validateBinding(_ candidate: AXCandidate, snapshot: AXSnapshot) throws {
        for id in Set(candidate.bindingNodeIDs + [candidate.nodeID]) {
            guard snapshot.handles.indices.contains(id) else { throw AXFailure.changed }
            let old = snapshot.nodes[id], handle = snapshot.handles[id]
            let attrs = AXReader.attributes(handle, ["AXRole", "AXTitle", "AXDescription", "AXHelp", "AXValue", "AXURL", "AXIdentifier", "AXHidden", "AXDocument"])
            func text(_ name: String) -> String { AXReader.rendered(attrs[name]) }
            guard attrs["AXHidden"] as? Bool != true,
                  bindingMatches(old, role: text("AXRole"), label: AXReader.firstNonempty([text("AXTitle"), text("AXDescription"), text("AXHelp")]),
                    value: AXReader.firstNonempty([text("AXValue"), text("AXURL")]), identifier: text("AXIdentifier"), document: text("AXDocument")) else {
                throw AXFailure.unavailable("Item binding changed before dispatch: node=\(id), old role=\(old.role), live role=\(text("AXRole")), old label=\(old.label), live label=\(text("AXDescription")), old value=\(AXReader.clipped(old.value, 160)), live value=\(AXReader.clipped(text("AXValue"), 160)).")
            }
            if let parent = old.parent, snapshot.handles.indices.contains(parent),
               !isAncestor(snapshot.handles[parent], of: handle) { throw AXFailure.unavailable("Item binding hierarchy changed before dispatch: node=\(id), parent=\(parent).") }
        }
    }

    private static func visiblePoint(_ element: AXUIElement, snapshot: AXSnapshot) throws -> CGPoint {
        guard var visible = AXReader.frame(element) else { throw AXFailure.changed }
        var parent = AXReader.attributeElement(element, "AXParent")
        for _ in 0..<40 {
            guard let current = parent else { break }
            let role = AXReader.string(current, "AXRole")
            if AXGrouping.clipAncestors.contains(role), let bounds = AXReader.frame(current) {
                visible = visible.intersection(bounds)
            }
            parent = AXReader.attributeElement(current, "AXParent")
        }
        guard !visible.isNull, visible.width >= 2, visible.height >= 2 else { throw AXFailure.unavailable("Activation target has no usable visible interior.") }
        return visible.center
    }

    private static func validateNativeSurface(_ target: AXUIElement, snapshot: AXSnapshot) throws {
        if snapshot.isMenuOnly { try validateMenuOnlySurface(target, snapshot: snapshot); return }
        let app = AXUIElementCreateApplication(snapshot.pid)
        if let menu = AXReader.attributeElement(app, "AXMenuBar"), isAncestor(menu, of: target) {
            guard let expected = snapshot.menuBarHandle, CFEqual(expected, menu) else { throw AXFailure.changed }
            return // Application menus are not descendants of the focused window.
        }
        guard let window = (AXReader.attributeElement(app, "AXFocusedWindow") ?? AXReader.attributeElement(app, "AXMainWindow")),
              snapshot.windowHandle.map({ CFEqual($0, window) }) ?? true,
              isAncestor(window, of: target) else { throw AXFailure.changed }
        for sheet in (AXReader.attribute(window, "AXSheets") as? [AXUIElement] ?? []) {
            guard isAncestor(sheet, of: target) else { throw AXFailure.unavailable("A sheet is active over the selected target.") }
        }
        var focused = AXReader.attributeElement(app, "AXFocusedUIElement")
        for _ in 0..<40 {
            guard let element = focused else { break }
            let role = AXReader.string(element, "AXRole"), subrole = AXReader.string(element, "AXSubrole")
            if ["AXSheet", "AXDialog", "AXPopover", "AXMenu"].contains(role) || ["AXDialog", "AXSystemDialog"].contains(subrole) ||
                AXReader.attribute(element, "AXModal") as? Bool == true {
                guard isAncestor(element, of: target) else { throw AXFailure.unavailable("Another modal surface owns focus.") }
            }
            if CFEqual(element, window) { break }
            focused = AXReader.attributeElement(element, "AXParent")
        }
    }

    private static func validateMenuOnlySurface(_ target: AXUIElement, snapshot: AXSnapshot) throws {
        let app = AXUIElementCreateApplication(snapshot.pid)
        guard AXReader.applicationWindow(app) == nil,
              let expected = snapshot.menuBarHandle,
              let live = AXReader.attributeElement(app, "AXMenuBar"),
              CFEqual(expected, live), isAncestor(live, of: target),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { throw AXFailure.changed }
    }

    private static func checkedClick(_ element: AXUIElement, original: AXNode,
                                     snapshot: AXSnapshot, permit: InputPermit, candidate: AXCandidate) throws {
        try permit.check()
        var cursor: Int? = original.id
        var menuTarget = false
        while let id = cursor, snapshot.nodes.indices.contains(id) {
            if ["AXMenuBar", "AXMenu"].contains(snapshot.nodes[id].role) { menuTarget = true; break }
            cursor = snapshot.nodes[id].parent
        }
        guard let before = original.frame, let now = AXReader.frame(element),
              before.insetBy(dx: -3, dy: -3).intersects(now),
              menuTarget || snapshot.nodes.first?.frame?.contains(now.center) == true else {
            throw AXFailure.unavailable("Press-click target bounds changed or are outside the observed window.")
        }
        let point = try visiblePoint(element, snapshot: snapshot)
        try permit.perform(effect: false) {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.025)
        var hit: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let initialHit = hit else { throw AXFailure.unavailable("Press-click hit test did not return a control.") }
        var initialPID: pid_t = 0
        guard AXUIElementGetPid(initialHit, &initialPID) == .success, initialPID == snapshot.pid else {
            let covering = NSRunningApplication(processIdentifier: initialPID)?.localizedName ?? "Unknown application"
            throw AXFailure.unavailable("\(covering) covers the press-click point for \(snapshot.appName).")
        }
        if !isAncestor(element, of: initialHit) {
            // Web/Electron hit tests can initially return a cached container, and
            // hover can reveal the actual button. No click is sent until it matches.
            try permit.perform(effect: false) {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            for delay in [0.05, 0.08, 0.12] {
                try permit.check()
                Thread.sleep(forTimeInterval: delay)
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { throw AXFailure.changed }
                _ = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
                if let hit, matchesClickTarget(element, hit: hit) { break }
            }
        }
        guard let hit, matchesClickTarget(element, hit: hit) else {
            throw AXFailure.pointerTargetUnknown
        }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == snapshot.pid,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid,
              let finalBounds = AXReader.frame(element), finalBounds.contains(point),
              (AXReader.attribute(element, "AXEnabled") as? Bool) != false else { throw AXFailure.changed }
        try validateBinding(candidate, snapshot: snapshot)
        if snapshot.isMenuOnly { try validateMenuOnlySurface(element, snapshot: snapshot) }
        let events = try pressClickEvents(at: point)
        try permit.pair(down: { events.down.post(tap: .cghidEventTap) },
                        up: { events.up.post(tap: .cghidEventTap) },
                        hold: { Thread.sleep(forTimeInterval: 0.025) })
    }

    static func pressClickEvents(at point: CGPoint) throws -> (down: CGEvent, up: CGEvent) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else {
            throw AXFailure.unavailable("Could not create a click event.")
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.flags = []
        up.flags = []
        return (down, up)
    }

    static func matchesClickTarget(_ target: AXUIElement, hit: AXUIElement,
                                   parentOf: (AXUIElement) -> AXUIElement? = { AXReader.attributeElement($0, "AXParent") }) -> Bool {
        isAncestor(target, of: hit, parentOf: parentOf)
    }

    private static func isAncestor(_ ancestor: AXUIElement, of descendant: AXUIElement,
                                   parentOf: (AXUIElement) -> AXUIElement? = { AXReader.attributeElement($0, "AXParent") }) -> Bool {
        var current: AXUIElement? = descendant
        for _ in 0..<40 {
            guard let element = current else { break }
            if CFEqual(element, ancestor) { return true }
            current = parentOf(element)
        }
        return false
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
