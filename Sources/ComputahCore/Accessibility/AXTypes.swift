import AppKit
import ApplicationServices
import Foundation

public struct AXNode: Codable, Equatable {
    public let id: Int
    public let parent: Int?
    public let depth: Int
    public let role: String
    public let subrole: String
    public let label: String
    public let value: String
    public let actions: [String]
    public let enabled: Bool
    public let frame: CGRect?
    public let help: String
    public let document: String
    public let identifier: String
    public let focused: Bool
    public let selected: Bool
    public let writableValue: Bool
    public let writableSelection: Bool
    public let minimum: Double?
    public let maximum: Double?
    public let childCount: Int?
    public let orientation: String
    public let visible: Bool

    public init(id: Int, parent: Int?, depth: Int, role: String, subrole: String = "", label: String,
                value: String = "", actions: [String] = [], enabled: Bool = true, frame: CGRect? = nil,
                help: String = "", identifier: String = "", focused: Bool = false, selected: Bool = false,
                writableValue: Bool = false, writableSelection: Bool = false,
                minimum: Double? = nil, maximum: Double? = nil, childCount: Int? = nil, visible: Bool = true, orientation: String = "", document: String = "") {
        self.id = id
        self.parent = parent
        self.depth = depth
        self.role = role
        self.subrole = subrole
        self.label = label
        self.value = value
        self.actions = actions
        self.enabled = enabled
        self.frame = frame
        self.help = help
        self.document = document
        self.identifier = identifier
        self.focused = focused
        self.selected = selected
        self.writableValue = writableValue
        self.writableSelection = writableSelection
        self.minimum = minimum
        self.maximum = maximum
        self.childCount = childCount
        self.orientation = orientation
        self.visible = visible
    }
}

public enum AXCoverageReason: String, Codable { case budget, visibleCollection, clipped, hidden, depth, unreadable, region, unspecified }
public struct AXCoverageGap {
    public let nodeID: Int?
    public let reason: AXCoverageReason
}

public struct AXSnapshot {
    public let pid: pid_t
    public let bundleID: String?
    public let appName: String
    public let windowTitle: String
    public let nodes: [AXNode]
    public let coverage: [AXCoverageGap]
    public let partial: Bool
    public let readSeconds: TimeInterval
    // Handles are deliberately local to this one observation. They are never serialized for Jev.
    let handles: [AXUIElement]
    let windowHandle: AXUIElement?
    let menuBarHandle: AXUIElement?
    let applicationWindows: [AXUIElement]?

    init(pid: pid_t, appName: String, windowTitle: String, nodes: [AXNode], partial: Bool,
         handles: [AXUIElement], readSeconds: TimeInterval = 0, windowHandle: AXUIElement? = nil,
         menuBarHandle: AXUIElement? = nil, bundleID: String? = nil, coverage: [AXCoverageGap] = [],
         applicationWindows: [AXUIElement]? = nil) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.nodes = nodes
        self.coverage = coverage.isEmpty && partial ? [AXCoverageGap(nodeID: nil, reason: .unspecified)] : coverage
        self.partial = partial
        self.readSeconds = readSeconds
        self.handles = handles
        self.windowHandle = windowHandle
        self.menuBarHandle = menuBarHandle
        self.applicationWindows = applicationWindows
    }

    var unfinishedVisibleRead: Bool {
        coverage.contains { [.budget, .depth, .unreadable, .unspecified].contains($0.reason) }
    }

    var isMenuOnly: Bool { windowHandle == nil && (menuBarHandle != nil || nodes.first?.role == "AXMenuBar") }

    func canObserveAfter(_ previous: AXSnapshot, foregroundPID: pid_t?) -> Bool {
        sameWindow(as: previous) ||
            (previous.isMenuOnly && windowHandle != nil && pid == previous.pid && foregroundPID == pid)
    }

    func sameWindow(as other: AXSnapshot) -> Bool {
        guard pid == other.pid else { return false }
        if let left = windowHandle, let right = other.windowHandle { return CFEqual(left, right) }
        if isMenuOnly || other.isMenuOnly {
            guard isMenuOnly && other.isMenuOnly else { return false }
            if let left = menuBarHandle, let right = other.menuBarHandle { return CFEqual(left, right) }
        }
        return false // A title alone cannot establish native identity.
    }

    /// Compare captured facts and native identity, never clipped display text or capture time.
    func hasObservedChange(from other: AXSnapshot) -> Bool {
        if !sameWindow(as: other) || nodes != other.nodes || handles.count != other.handles.count { return true }
        return zip(handles, other.handles).contains { !CFEqual($0, $1) }
    }
}

public enum AXFailure: LocalizedError {
    case permission
    case noWindow
    case changed
    case pointerTargetUnknown
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .permission: "Enable Accessibility for Computah in System Settings."
        case .noWindow: "The target application has no accessible window or menu."
        case .pointerTargetUnknown: "The pointer hit could not be bound to the selected control."
        case .changed: "The target app or control changed."
        case .unavailable(let detail): detail
        }
    }
}

public enum AXOperation: String {
    case pressClick, showMenu, increment, decrement, typeText, replaceText, scrollUp, scrollDown, setNumber, select, pressReturn
}

public struct AXCandidate {
    public let id: String
    public let nodeID: Int
    public let operation: AXOperation
    public let description: String
    public let groupID: Int
    var bindingNodeIDs: [Int] = []
}

public struct AXGroup {
    public let id: Int
    public let title: String
    public let members: [AXCandidate]
}
