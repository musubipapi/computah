import AppKit
import ApplicationServices
import Foundation

public enum AXGrouping {
    // Structural roles are shared AX vocabulary, not app-specific selectors.
    private static let regions: Set<String> = [
        "AXToolbar", "AXMenu", "AXMenuBar", "AXTabGroup", "AXList", "AXTable",
        "AXOutline", "AXScrollArea", "AXSplitGroup", "AXSheet", "AXDialog", "AXPopover",
        "AXWebArea", "AXWindow", "AXGroup", "AXLandmark", "AXNavigation",
    ]
    static let editable: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
    static let clipAncestors: Set<String> = ["AXWindow", "AXScrollArea", "AXTable", "AXList", "AXOutline", "AXGrid"]

    public static func candidates(in snapshot: AXSnapshot, includeSecondary: Bool = false) -> [AXCandidate] {
        func enclosingRow(_ node: AXNode) -> Int? {
            var parent = node.parent
            while let id = parent, snapshot.nodes.indices.contains(id) {
                let ancestor = snapshot.nodes[id]
                if ancestor.role == "AXRow" { return id }
                if ["AXTable", "AXList", "AXOutline"].contains(ancestor.role) { return nil }
                parent = ancestor.parent
            }
            return nil
        }
        var rowText: [Int: [String]] = [:]
        var rowTextIDs: [Int: [Int]] = [:]
        for node in snapshot.nodes where node.visible && ["AXStaticText", "AXHeading", "AXLink"].contains(node.role) {
            guard let row = enclosingRow(node) else { continue }
            let text = AXReader.firstNonempty([node.label, node.value])
            if !text.isEmpty && rowText[row, default: []].count < 6 && !rowText[row, default: []].contains(text) {
                rowText[row, default: []].append(text)
                rowTextIDs[row, default: []].append(node.id)
            }
        }
        return snapshot.nodes.flatMap { node -> [AXCandidate] in
            guard node.enabled, node.visible else { return [] }
            let hasPointerArea = node.frame.map { $0.width >= 2 && $0.height >= 2 } ?? false
            var actions: [AXOperation] = []
            if editable.contains(node.role) {
                actions.append(.typeText)
                if !node.value.isEmpty { actions.append(.replaceText) }
                if node.focused && node.subrole != "AXSecureTextField" { actions.append(.pressReturn) }
            }
            if includeSecondary && (node.role == "AXScrollArea" || node.role == "AXWebArea") {
                actions.append(contentsOf: [.scrollUp, .scrollDown])
            }
            if node.actions.contains("AXPress"), hasPointerArea {
                // One semantic activation; delivery is selected from freshly observed capabilities.
                actions.append(.pressClick)
            }
            if ["AXSlider", "AXIncrementor"].contains(node.role),
               node.writableValue || (node.actions.contains("AXIncrement") && node.actions.contains("AXDecrement")) {
                actions.append(.setNumber)
            }
            if node.writableSelection, !node.actions.isEmpty {
                if includeSecondary { actions.append(.select) }
                else if hasPointerArea, !actions.contains(.pressClick) { actions.append(.pressClick) }
            }
            if node.actions.contains("AXShowMenu"), (includeSecondary && !["AXToolbar", "AXWindow", "AXGroup", "AXStaticText", "AXImage"].contains(node.role)) ||
                actions.isEmpty && ["AXMenuButton", "AXPopUpButton"].contains(node.role) {
                actions.append(.showMenu)
            }
            if includeSecondary, node.actions.contains("AXIncrement") { actions.append(.increment) }
            if includeSecondary, node.actions.contains("AXDecrement") { actions.append(.decrement) }
            if actions.isEmpty, hasPointerArea, node.role == "AXLink" || node.role == "AXButton" {
                actions.append(.pressClick)
            }
            guard !actions.isEmpty else { return [] }
            var descendants = Set([node.id])
            var parts: [String] = []
            var bindingIDs = [node.id]
            // Providers often attach document identity to a window or web area,
            // rather than to each editor. Retain that observed identity for input checks.
            var ancestor = node.parent
            while let id = ancestor, snapshot.nodes.indices.contains(id) {
                if !snapshot.nodes[id].document.isEmpty { bindingIDs.append(id) }
                ancestor = snapshot.nodes[id].parent
            }
            for child in snapshot.nodes where child.depth > node.depth && child.depth <= node.depth + 3 {
                guard let parent = child.parent, descendants.contains(parent) else { continue }
                descendants.insert(child.id)
                let text = child.label.isEmpty ? child.value : child.label
                if !text.isEmpty { parts.append(text); bindingIDs.append(child.id) }
                if parts.count == 6 { break }
            }
            let childText = parts.joined(separator: "; ")
            let label = AXReader.firstNonempty([node.label, node.value, childText])
            let name = label.isEmpty ? node.role : "\(node.role): \(label)"
            let owner = regionOwner(of: node, nodes: snapshot.nodes)
            let region = snapshot.nodes[owner]
            var context = ["region=\(region.role) \(region.label)"]
            if !node.subrole.isEmpty { context.append("subrole=\(node.subrole)") }
            if !node.help.isEmpty && node.help != node.label { context.append("purpose=\(node.help)") }
            if !node.value.isEmpty && node.value != label { context.append("value=\(AXReader.clipped(node.value, 160))") }
            let nearbyNodes = snapshot.nodes.filter { $0.parent == node.parent && $0.id != node.id &&
                ["AXStaticText", "AXHeading"].contains($0.role) }.prefix(4)
            let nearby = nearbyNodes.map { AXReader.firstNonempty([$0.label, $0.value]) }.filter { !$0.isEmpty }
            bindingIDs += nearbyNodes.map(\.id)
            if !nearby.isEmpty { context.append("nearby text=" + AXReader.clipped(nearby.joined(separator: "; "), 240)) }
            if let row = enclosingRow(node), let text = rowText[row], !text.isEmpty {
                context.append("item text=" + AXReader.clipped(text.joined(separator: "; "), 240))
                bindingIDs.append(row)
                bindingIDs += rowTextIDs[row, default: []]
            }
            if node.focused { context.append("focused") }
            if node.selected { context.append("selected") }
            if let minimum = node.minimum, let maximum = node.maximum, maximum > minimum { context.append("range=\(minimum)...\(maximum)") }
            return actions.map { action in
                AXCandidate(id: "n\(node.id)_\(action.rawValue)", nodeID: node.id, operation: action,
                            description: "\(AXReader.clipped(name, 260)) [\(action.rawValue)]; \(context.joined(separator: "; "))", groupID: owner, bindingNodeIDs: Array(Set(bindingIDs)).sorted())
            }
        }
    }

    public static func groups(in snapshot: AXSnapshot, candidates: [AXCandidate]) -> [AXGroup] {
        let byOwner = Dictionary(grouping: candidates, by: \.groupID)
        return byOwner.keys.sorted().map { owner in
            let node = snapshot.nodes[owner]
            let members = byOwner[owner] ?? []
            let name = node.label.isEmpty ? node.role : "\(node.role): \(node.label)"
            var seen = Set<String>()
            var examples: [String] = []
            for item in members {
                if seen.insert(item.id).inserted { examples.append(item.description) }
                if examples.count == 3 { break }
            }
            let title = "\(name) — \(members.count) controls: \(examples.joined(separator: "; "))"
            return AXGroup(id: owner, title: AXReader.clipped(title, 300), members: members)
        }
    }

    private static func regionOwner(of node: AXNode, nodes: [AXNode]) -> Int {
        var cursor = node.parent
        while let id = cursor {
            let parent = nodes[id]
            if regions.contains(parent.role), parent.role != "AXGroup" ||
                parent.role == "AXGroup" && !parent.label.isEmpty {
                return id
            }
            cursor = parent.parent
        }
        return 0
    }
}
