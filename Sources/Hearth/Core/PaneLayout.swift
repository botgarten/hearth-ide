import Foundation

enum SplitAxis: String, Codable, Sendable { case horizontal, vertical }

/// Inspector layout as a tree of splits whose leaves are panes.
indirect enum PaneNode: Identifiable, Sendable {
    case leaf(InspectorPane)
    case split(id: UUID, axis: SplitAxis, children: [PaneNode])

    var id: UUID {
        switch self {
        case .leaf(let p): p.id
        case .split(let id, _, _): id
        }
    }

    var panes: [InspectorPane] {
        switch self {
        case .leaf(let p): [p]
        case .split(_, _, let c): c.flatMap(\.panes)
        }
    }

    /// Places `new` next to the pane `target` along `axis`. Splitting along the
    /// parent's axis adds a sibling instead of nesting another split.
    func splitting(_ target: UUID, axis: SplitAxis, with new: InspectorPane) -> PaneNode {
        switch self {
        case .leaf(let p):
            return p.id == target ? .split(id: UUID(), axis: axis, children: [self, .leaf(new)]) : self
        case .split(let id, let a, let children):
            if a == axis, let i = children.firstIndex(where: { $0.id == target }) {
                var c = children
                c.insert(.leaf(new), at: i + 1)
                return .split(id: id, axis: a, children: c)
            }
            return .split(id: id, axis: a, children: children.map { $0.splitting(target, axis: axis, with: new) })
        }
    }

    /// Removes a pane; splits left with one child collapse into that child.
    func removing(_ target: UUID) -> PaneNode? {
        switch self {
        case .leaf(let p):
            return p.id == target ? nil : self
        case .split(let id, let a, let children):
            let c = children.compactMap { $0.removing(target) }
            if c.isEmpty { return nil }
            if c.count == 1 { return c[0] }
            return .split(id: id, axis: a, children: c)
        }
    }

    func updating(_ target: UUID, tab: InspectorTab) -> PaneNode {
        switch self {
        case .leaf(var p):
            if p.id == target { p.tab = tab }
            return .leaf(p)
        case .split(let id, let a, let children):
            return .split(id: id, axis: a, children: children.map { $0.updating(target, tab: tab) })
        }
    }

    /// Inserts `new` before/after `target` along `axis` (drop to the left/right/top/bottom of a pane).
    func inserting(_ new: InspectorPane, at target: UUID, axis: SplitAxis, before: Bool) -> PaneNode {
        switch self {
        case .leaf(let p):
            guard p.id == target else { return self }
            return .split(id: UUID(), axis: axis, children: before ? [.leaf(new), self] : [self, .leaf(new)])
        case .split(let id, let a, let children):
            if a == axis, let i = children.firstIndex(where: { $0.id == target }) {
                var c = children
                c.insert(.leaf(new), at: before ? i : i + 1)
                return .split(id: id, axis: a, children: c)
            }
            return .split(id: id, axis: a, children: children.map { $0.inserting(new, at: target, axis: axis, before: before) })
        }
    }

    func pane(_ id: UUID) -> InspectorPane? { panes.first { $0.id == id } }

    func contains(tab: InspectorTab) -> Bool { panes.contains { $0.tab == tab } }

    var splitIDs: Set<UUID> {
        switch self {
        case .leaf: []
        case .split(let id, _, let c): c.reduce(into: [id]) { $0.formUnion($1.splitIDs) }
        }
    }
}

// Persisted as a small tagged structure so the layout survives restarts.
extension PaneNode: Codable {
    private enum CodingKeys: String, CodingKey { case pane, id, axis, children }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let pane = try c.decodeIfPresent(InspectorPane.self, forKey: .pane) {
            self = .leaf(pane)
        } else {
            self = .split(id: try c.decode(UUID.self, forKey: .id),
                          axis: try c.decode(SplitAxis.self, forKey: .axis),
                          children: try c.decode([PaneNode].self, forKey: .children))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let p): try c.encode(p, forKey: .pane)
        case .split(let id, let a, let children):
            try c.encode(id, forKey: .id)
            try c.encode(a, forKey: .axis)
            try c.encode(children, forKey: .children)
        }
    }
}

/// Ready-made window layouts.
enum LayoutPreset: String, CaseIterable, Identifiable {
    case standard = "Standard", focusChat = "Fokus Chat", review = "Review", monitoring = "Monitoring"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: String(localized: "Standard")
        case .focusChat: String(localized: "Focus on chat")
        case .review: String(localized: "Review")
        case .monitoring: String(localized: "Monitoring")
        }
    }

    var symbol: String {
        switch self {
        case .standard: "rectangle.split.3x1"
        case .focusChat: "bubble.left.and.bubble.right"
        case .review: "doc.text.magnifyingglass"
        case .monitoring: "gauge.with.dots.needle.67percent"
        }
    }

    /// Tree plus relative sizes for each split.
    func build() -> (PaneNode, [UUID: [Double]]) {
        func leaf(_ t: InspectorTab) -> PaneNode { .leaf(InspectorPane(tab: t)) }
        var weights: [UUID: [Double]] = [:]
        func split(_ axis: SplitAxis, _ children: [PaneNode], _ w: [Double]) -> PaneNode {
            let id = UUID()
            weights[id] = w
            return .split(id: id, axis: axis, children: children)
        }
        let tree: PaneNode
        switch self {
        case .standard:
            tree = split(.horizontal, [leaf(.sessions), leaf(.chat),
                                       split(.vertical, [leaf(.directory), leaf(.git)], [0.5, 0.5])], [0.2, 0.45, 0.35])
        case .focusChat:
            tree = split(.horizontal, [leaf(.sessions), leaf(.chat)], [0.22, 0.78])
        case .review:
            tree = split(.horizontal, [leaf(.chat),
                                       split(.vertical, [leaf(.preview), leaf(.git)], [0.65, 0.35])], [0.38, 0.62])
        case .monitoring:
            tree = split(.horizontal, [leaf(.sessions),
                                       split(.vertical, [leaf(.pipelines), leaf(.tests)], [0.55, 0.45]),
                                       leaf(.chat)], [0.22, 0.43, 0.35])
        }
        return (tree, weights)
    }
}

/// A layout the user saved under a name (Layout menu → “Save current layout…”).
struct SavedLayout: Identifiable, Codable, Sendable {
    var id = UUID()
    var name: String
    var tree: PaneNode
    var weights: [UUID: [Double]]

    /// Tree and sizes with new pane/split IDs, so applying it twice never reuses
    /// IDs that other state (editor tabs per pane, stored sizes) still refers to.
    func build() -> (PaneNode, [UUID: [Double]]) {
        var newWeights: [UUID: [Double]] = [:]
        func copy(_ node: PaneNode) -> PaneNode {
            switch node {
            case .leaf(let p):
                return .leaf(InspectorPane(tab: p.tab))
            case .split(let id, let axis, let children):
                let new = UUID()
                if let w = weights[id], w.count == children.count { newWeights[new] = w }
                return .split(id: new, axis: axis, children: children.map(copy))
            }
        }
        return (copy(tree), newWeights)
    }
}
