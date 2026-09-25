import Foundation

extension AXSnapshot {
    /// Document and selected-object metadata are evidence, never title/content hashes.
    var bindingEvidence: [[String: String]] {
        nodes.filter { !$0.document.isEmpty || $0.role == "AXWebArea" || $0.selected || $0.focused }.map {
            ["role": $0.role, "identifier": $0.identifier, "document": $0.document,
             "label": $0.label, "value": AXReader.clipped($0.value, 500),
             "parent": $0.parent.map { nodes[$0].label } ?? "",
             "selected": String($0.selected), "focused": String($0.focused)]
        }
    }

    private func stateLine(_ node: AXNode, valueLimit: Int = 2_000) -> String {
        var regions: [String] = []
        var parent = node.parent
        while let id = parent, nodes.indices.contains(id), regions.count < 4 {
            if !nodes[id].label.isEmpty && nodes[id].depth > 2 && nodes[id].role != "AXWebArea" { regions.append(nodes[id].label) }
            if ["AXTable", "AXList", "AXOutline", "AXGrid"].contains(nodes[id].role) { break }
            parent = nodes[id].parent
        }
        return "region=\(regions.reversed().joined(separator: " / ")) | \(node.role) | available label=\(node.label) | value=\(AXReader.clipped(node.value, valueLimit)) | enabled=\(node.enabled) focused=\(node.focused) selected=\(node.selected)" +
            (node.childCount.map { " | children=\($0)" } ?? "") +
            (node.value.count > valueLimit ? " | value truncated; remaining text unknown" : "") +
            (node.document.isEmpty ? "" : " | document=\(AXReader.clipped(node.document, 500))")
    }

    /// Bounded model evidence. Full snapshots remain in the local event record.
    func verificationEvidence(from before: AXSnapshot? = nil, target: AXCandidate? = nil,
                              limit: Int = 12_000) -> String {
        let valueLimit = limit >= 8_000 ? 2_000 : max(40, limit / 8)
        var rows = ["AFTER app=\(appName); window=\(windowTitle); partial=\(partial)"]
        var repeats: [String: Int] = [:]
        func append(_ row: String) {
            repeats[row, default: 0] += 1
            if repeats[row] == 1 { rows.append(row) }
        }
        var included = Set<Int>()
        var paired = Set<Int>()
        func add(_ id: Int, prefix: String) {
            guard nodes.indices.contains(id), included.insert(id).inserted else { return }
            append(prefix + stateLine(nodes[id], valueLimit: valueLimit))
        }
        func addTargetContext(_ id: Int, prefix: String, before: AXSnapshot) {
            guard nodes.indices.contains(id), !included.contains(id) else { return }
            if handles.indices.contains(id),
               let oldID = before.handles.firstIndex(where: { CFEqual($0, handles[id]) }) {
                // Unchanged neighboring identity still matters: AFTER identity
                // alone cannot establish which item an existing activity held.
                // Keep both times in one budget unit, including changed identity.
                append(prefix + " BEFORE: " + before.stateLine(before.nodes[oldID], valueLimit: valueLimit) +
                    "\n" + prefix + " AFTER: " + stateLine(nodes[id], valueLimit: valueLimit))
                included.insert(id)
                paired.insert(id)
            } else { add(id, prefix: prefix + " AFTER (prior identity unknown): ") }
        }
        if let before {
            rows.append("BEFORE app=\(before.appName); window=\(before.windowTitle); partial=\(before.partial)")
            rows.append("Same native window before and after: \(sameWindow(as: before)).")
            if let windowHandle, let priorWindows = before.applicationWindows {
                let existed = priorWindows.contains { CFEqual($0, windowHandle) }
                rows.append("Current native window existed in the app's BEFORE window inventory: \(existed). This comparison uses native window identities, independently of tree coverage. Judge whether the resulting window contains the requested object.")
            }
            if let target, before.nodes.indices.contains(target.nodeID) {
                let targetBefore = "ACTION CONTROL BEFORE: " + before.stateLine(before.nodes[target.nodeID], valueLimit: valueLimit)
                if before.handles.indices.contains(target.nodeID),
                   let id = handles.firstIndex(where: { CFEqual($0, before.handles[target.nodeID]) }) {
                    append(targetBefore + "\nSAME ACTION CONTROL AFTER: " + stateLine(nodes[id], valueLimit: valueLimit))
                    included.insert(id)
                    paired.insert(id)
                    for evidenceID in target.bindingNodeIDs where evidenceID != target.nodeID && before.handles.indices.contains(evidenceID) {
                        if let currentID = handles.firstIndex(where: { CFEqual($0, before.handles[evidenceID]) }) {
                            addTargetContext(currentID, prefix: "ACTION CONTROL CONTEXT", before: before)
                        }
                    }
                    let parent = nodes[id].parent
                    if let parent { addTargetContext(parent, prefix: "ACTION CONTROL PARENT", before: before) }
                } else { append(targetBefore + "\nDispatched control is absent from this observation. Identify the resulting object separately from the control that produced it.") }
            }
        }
        if let before {
            // Counts are paired facts, not proof of creation. Target identity comes first.
            for node in nodes where node.visible && ["AXTable", "AXList", "AXOutline", "AXGrid"].contains(node.role) {
                guard handles.indices.contains(node.id),
                      let oldID = before.handles.firstIndex(where: { CFEqual($0, handles[node.id]) }),
                      let oldCount = before.nodes[oldID].childCount, let newCount = node.childCount,
                      oldCount != newCount else { continue }
                append("SAME NATIVE COLLECTION BEFORE: " + before.stateLine(before.nodes[oldID], valueLimit: valueLimit) +
                    "\nSAME NATIVE COLLECTION AFTER: " + stateLine(node, valueLimit: valueLimit))
                included.insert(node.id)
                paired.insert(node.id)
            }
        }
        if let window = nodes.first(where: { $0.role == "AXWindow" }) { add(window.id, prefix: "CURRENT WINDOW: ") }
        if let before, let target, before.handles.indices.contains(target.nodeID),
           let id = handles.firstIndex(where: { CFEqual($0, before.handles[target.nodeID]) }) {
            let parent = nodes[id].parent
            for neighbor in nodes.filter({ $0.parent == parent || $0.parent == id }).prefix(12) {
                addTargetContext(neighbor.id, prefix: "ACTION CONTROL NEIGHBOR", before: before)
            }
        }
        for node in nodes where node.focused || node.selected { add(node.id, prefix: "CURRENT FOCUSED/SELECTED: ") }
        // Preserve a sample of each observed collection before unrelated controls
        // consume the evidence budget. This is structural evidence, not goal matching.
        for node in nodes where node.visible && ["AXTable", "AXList", "AXOutline", "AXGrid"].contains(node.role) {
            add(node.id, prefix: "CURRENT COLLECTION: ")
            for child in nodes.filter({ $0.visible && $0.parent == node.id }).prefix(4) {
                add(child.id, prefix: "CURRENT COLLECTION ITEM: ")
            }
        }
        if let before {
            append("Unpaired controls below are newly observed; their individual creation is unknown. Native window inventory comparisons are independent of this tree coverage limit.")
            for node in nodes where node.visible && !paired.contains(node.id) {
                if handles.indices.contains(node.id),
                   let oldID = before.handles.firstIndex(where: { CFEqual($0, handles[node.id]) }) {
                    let old = before.nodes[oldID]
                    if stateLine(node, valueLimit: valueLimit) != before.stateLine(old, valueLimit: valueLimit) {
                        // Keep the delta together. A previously included current
                        // node must not leave only its obsolete BEFORE row here;
                        // the evidence budget must also retain or omit both halves.
                        append("SAME NATIVE CONTROL BEFORE: " + before.stateLine(old, valueLimit: valueLimit) +
                            "\nSAME NATIVE CONTROL AFTER: " + stateLine(node, valueLimit: valueLimit))
                        included.insert(node.id)
                    }
                } else if !node.label.isEmpty || !node.value.isEmpty {
                    add(node.id, prefix: "CURRENT UNPAIRED CONTROL: ")
                }
            }
        }
        // Retain current actionable/status context even if the requested state was already true.
        let actionable = Set(AXGrouping.candidates(in: self).map(\.nodeID))
        for node in nodes where node.visible && actionable.contains(node.id) {
            add(node.id, prefix: "CURRENT CONTROL: ")
        }
        var result = ""
        var omitted = 0
        let budget = max(0, limit - 100) // Reserve space for explicit coverage loss.
        for originalRow in rows {
            let count = repeats[originalRow, default: 1]
            let row = originalRow + (count > 1 ? " | equivalent evidence rows=\(count)" : "")
            if result.count + row.count + 1 > budget {
                omitted += 1
                continue // A large row must not hide smaller evidence that follows it.
            }
            result += row + "\n"
        }
        if omitted > 0 { result += "Evidence budget reached; \(omitted) rows omitted. Missing evidence is unknown.\n" }
        return String(result.prefix(max(0, limit)))
    }

}

extension AXSnapshot {
    var selectionEvidence: String {
        let state = nodes.filter { !$0.enabled || $0.focused || $0.selected }.map {
            "\($0.role): \($0.label); value=\(AXReader.clipped($0.value, 160)); enabled=\($0.enabled); focused=\($0.focused); selected=\($0.selected)"
        }.joined(separator: "\n")
        let collections = nodes.filter { $0.visible && ["AXTable", "AXList", "AXOutline", "AXGrid"].contains($0.role) }.map { collection in
            ["role": collection.role, "label": collection.label,
             "total_children": collection.childCount.map(String.init) ?? "unknown",
             "observed_items": nodes.filter { $0.visible && $0.parent == collection.id }.prefix(4).map { $0.label.isEmpty ? $0.value : $0.label }.joined(separator: "; ")]
        }
        // Dictionary descriptions randomize field order between processes.
        let collectionData = try? JSONSerialization.data(withJSONObject: collections, options: [.sortedKeys])
        let collectionEvidence = collectionData.map { String(decoding: $0, as: UTF8.self) } ?? "Unknown"
        return "app=\(appName); window=\(windowTitle); partial=\(partial); coverage=\(Set(coverage.map { $0.reason.rawValue }).sorted().joined(separator: ","))\n" + state + "\nCurrent collections: \(collectionEvidence)"
    }
    public var evidence: String {
        let entries = nodes.filter {
            !$0.label.isEmpty || !$0.value.isEmpty || $0.focused || $0.selected || $0.role == "AXTextArea"
        }.map { node in
            "\(node.role) | \(node.label) | help=\(node.help) | value=\(AXReader.clipped(node.value, 400))\(node.selected ? " | selected" : "")\(node.focused ? " | focused" : "")\(node.enabled ? "" : " | disabled")\(node.childCount.map { " | total children=\($0)" } ?? "")"
        }
        return "app=\(appName); window=\(windowTitle); nodes=\(nodes.count); partial=\(partial)\n" + entries.joined(separator: "\n")
    }

    var destinationEvidence: String {
        nodes.filter {
            $0.role == "AXWebArea" && ["https", "http"].contains(URL(string: $0.value)?.scheme ?? "")
        }.map { "Loaded document: \($0.value); title: \($0.label)" }.joined(separator: "\n")
    }

    /// Exact endpoint matching. A different host is not evidence of this destination.
    func observesDestination(_ url: URL) -> Bool {
        func port(_ url: URL) -> Int? {
            url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
        }
        func path(_ url: URL) -> String { url.path.isEmpty ? "/" : url.path }
        return nodes.contains { node in
            guard node.role == "AXWebArea", let observed = URL(string: node.value),
                  let expectedHost = url.host?.lowercased(), let observedHost = observed.host?.lowercased() else { return false }
            return url.scheme?.lowercased() == observed.scheme?.lowercased() && port(url) == port(observed) &&
                observedHost == expectedHost &&
                path(url) == path(observed) && url.query == observed.query && url.fragment == observed.fragment
        }
    }

    func valueForSameControl(_ candidate: AXCandidate, from old: AXSnapshot) -> String? {
        guard old.handles.indices.contains(candidate.nodeID) else { return nil }
        let handle = old.handles[candidate.nodeID]
        guard let index = handles.firstIndex(where: { CFEqual($0, handle) }) else { return nil }
        return nodes[index].value
    }
}
