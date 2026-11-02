import Foundation
import AppKit
import Observation

/// The window's pane layout: which areas are open, how they are split and which have
/// their own window. Persisted in UIStateStore.
@MainActor
@Observable
final class LayoutStore {
    var paneTree: PaneNode = LayoutPreset.standard.build().0 {
        didSet {
            // Drop stored sizes for splits that no longer exist or changed child count.
            let ids = paneTree.splitIDs
            splitWeights = splitWeights.filter { ids.contains($0.key) }
            UIStateStore.save(paneTree, as: .paneTree)
        }
    }
    /// Relative child sizes per split (sums to 1), persisted.
    var splitWeights: [UUID: [Double]] = [:] {
        didSet { UIStateStore.save(splitWeights, as: .splitWeights) }
    }
    /// Pane filling the whole window (double-click on a pane header), nil = normal layout.
    var maximizedPane: UUID?
    /// The one drop preview shown while a pane is dragged: a zone of one pane or a window edge.
    /// Kept in one place so a preview can't linger in a pane SwiftUI forgot to tell about the exit.
    private(set) var dropHover: DropHover?
    @ObservationIgnored private var dropWatch: Task<Void, Never>?

    struct DropHover: Equatable {
        let pane: UUID
        let zone: DropZone
    }

    /// Window-edge drop preview shown over the whole layout while dragging.
    var windowDropZone: DropZone? { dropHover.flatMap { $0.zone.isWindowEdge ? $0.zone : nil } }

    /// Shows the preview for `zone` of `pane`. While one is shown, a watcher clears it once the
    /// mouse button is up: SwiftUI doesn't always report the end of a drag (quick moves between
    /// panes, a drop outside any pane, Escape).
    func hoverDrop(_ zone: DropZone, over pane: UUID, buttonDown: @escaping @MainActor () -> Bool = LayoutStore.mouseButtonDown) {
        let hover = DropHover(pane: pane, zone: zone)
        if dropHover != hover { dropHover = hover }
        guard dropWatch == nil else { return }
        dropWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                if !buttonDown() { self.endDropHover(); return }
            }
        }
    }

    /// The drag left `pane` (ignored if it is already over another one) or ended (`pane` nil).
    func endDropHover(leaving pane: UUID? = nil) {
        if let pane, dropHover?.pane != pane { return }
        dropHover = nil
        dropWatch?.cancel()
        dropWatch = nil
    }

    static func mouseButtonDown() -> Bool { NSEvent.pressedMouseButtons & 1 != 0 }
    /// Tabs currently shown in their own window (opened via openWindow(value:)).
    var detachedTabs: Set<InspectorTab> = [] {
        didSet { if !quitting { UIStateStore.save(detachedTabs.map(\.rawValue).sorted(), as: .detachedTabs) } }
    }
    /// Set while the app terminates so closing windows don't forget they were open.
    var quitting = false

    /// Called when a pane is removed (the editor moves unsaved tabs elsewhere).
    @ObservationIgnored var onPaneClosed: ((UUID) -> Void)?
    /// Short user feedback ("already open").
    @ObservationIgnored var notify: ((String) -> Void)?

    enum DropZone: Equatable {
        case left, right, top, bottom, center
        /// Along the whole window edge (full width/height).
        case windowLeft, windowRight, windowTop, windowBottom

        var isWindowEdge: Bool { [.windowLeft, .windowRight, .windowTop, .windowBottom].contains(self) }
    }

    /// Restores the saved layout (or the standard one).
    func restore() {
        // Read the weights first: assigning paneTree prunes (and re-saves) splitWeights.
        let saved: [UUID: [Double]] = UIStateStore.load(.splitWeights) ?? [:]
        if let tree: PaneNode = UIStateStore.load(.paneTree), !tree.panes.isEmpty {
            if tree.contains(tab: .sessions) || tree.contains(tab: .chat) {
                paneTree = tree
                splitWeights = saved
            } else {
                // Layout from before sessions/chat became panes: keep the inspector arrangement on the right.
                let id = UUID()
                paneTree = .split(id: id, axis: .horizontal, children: [
                    .leaf(InspectorPane(tab: .sessions)), .leaf(InspectorPane(tab: .chat)), tree,
                ])
                splitWeights = saved.merging([id: [0.2, 0.45, 0.35]]) { $1 }
            }
        } else {
            apply(.standard)
        }
    }

    /// IDs of all editor panes, including a detached editor window.
    var editorPaneIDs: [UUID] {
        let main = paneTree.panes.filter { $0.tab == .preview }.map(\.id)
        return detachedTabs.contains(.preview) ? main + [DetachedPaneView.id(for: .preview)] : main
    }

    func weights(for id: UUID, count: Int) -> [Double] {
        if let w = splitWeights[id], w.count == count { return w }
        return Array(repeating: 1 / Double(count), count: count)
    }

    func split(_ paneID: UUID, axis: SplitAxis, tab: InspectorTab? = nil) {
        let used = Set(paneTree.panes.map(\.tab))
        let next = tab ?? InspectorTab.allCases.first { !used.contains($0) && $0.needsWorkspace } ?? .preview
        paneTree = paneTree.splitting(paneID, axis: axis, with: InspectorPane(tab: next))
    }

    func closePane(_ id: UUID) {
        guard paneTree.panes.count > 1, let tree = paneTree.removing(id) else { return }
        if maximizedPane == id { maximizedPane = nil }
        paneTree = tree
        onPaneClosed?(id)
    }

    func toggleMaximize(_ id: UUID) {
        maximizedPane = maximizedPane == id ? nil : id
    }

    /// Drag & drop: move `source` next to `target` (or swap contents on center).
    func movePane(_ source: UUID, onto target: UUID, zone: DropZone) {
        guard source != target, let moving = paneTree.pane(source), let other = paneTree.pane(target) else { return }
        if zone == .center {
            paneTree = paneTree.updating(source, tab: other.tab).updating(target, tab: moving.tab)
            return
        }
        guard let without = paneTree.removing(source) else { return }
        if zone.isWindowEdge {
            paneTree = without
            dock(moving, atWindowEdge: zone)
            return
        }
        let axis: SplitAxis = zone == .left || zone == .right ? .horizontal : .vertical
        paneTree = without.inserting(moving, at: target, axis: axis, before: zone == .left || zone == .top)
    }

    /// Puts a pane along a whole window edge, e.g. a terminal across the full width at the bottom.
    func dock(_ pane: InspectorPane, atWindowEdge zone: DropZone) {
        let axis: SplitAxis = zone == .windowLeft || zone == .windowRight ? .horizontal : .vertical
        let before = zone == .windowLeft || zone == .windowTop
        let share = 0.3   // new pane's share of the window
        if case .split(let id, let a, var children) = paneTree, a == axis {
            // Root already splits along this axis: add another column/row at the edge.
            let old = weights(for: id, count: children.count).map { $0 * (1 - share) }
            if before { children.insert(.leaf(pane), at: 0) } else { children.append(.leaf(pane)) }
            paneTree = .split(id: id, axis: a, children: children)
            splitWeights[id] = before ? [share] + old : old + [share]
        } else {
            let id = UUID()
            paneTree = .split(id: id, axis: axis, children: before ? [.leaf(pane), paneTree] : [paneTree, .leaf(pane)])
            splitWeights[id] = before ? [share, 1 - share] : [1 - share, share]
        }
    }

    func addPane(_ tab: InspectorTab, atWindowEdge zone: DropZone) {
        maximizedPane = nil
        if let existing = paneTree.panes.first(where: { $0.tab == tab }), let without = paneTree.removing(existing.id) {
            paneTree = without   // move it instead of duplicating
        }
        dock(InspectorPane(tab: tab), atWindowEdge: zone)
    }

    /// Adds an area at the right edge of the window (unless it is already open).
    func addPane(_ tab: InspectorTab) {
        maximizedPane = nil
        if paneTree.contains(tab: tab) {
            notify?(String(localized: "“\(tab.title)” is already open"))
            return
        }
        let new = InspectorPane(tab: tab)
        switch paneTree {
        case .split(let id, .horizontal, var children):
            children.append(.leaf(new))
            paneTree = .split(id: id, axis: .horizontal, children: children)
        default:
            paneTree = .split(id: UUID(), axis: .horizontal, children: [paneTree, .leaf(new)])
        }
    }

    func apply(_ preset: LayoutPreset) {
        let (tree, weights) = preset.build()
        maximizedPane = nil
        paneTree = tree
        splitWeights = weights
    }

    func resetLayout() { apply(.standard) }

    // MARK: Detached pane windows

    /// Tabs that had their own window when the app was last quit.
    var savedDetachedTabs: [InspectorTab] {
        (UIStateStore.load(.detachedTabs) as [String]?)?.compactMap(InspectorTab.init(rawValue:)) ?? []
    }

    /// Removes the pane from the main layout; the caller opens the window.
    func detach(_ id: UUID) -> InspectorTab? {
        guard let pane = paneTree.pane(id) else { return nil }
        if paneTree.panes.count > 1 { closePane(id) }
        detachedTabs.insert(pane.tab)
        return pane.tab
    }

    func dock(_ tab: InspectorTab) {
        detachedTabs.remove(tab)
        if !paneTree.contains(tab: tab) { addPane(tab) }
    }

    /// Makes an area visible: leaves it where it is if open (or in its own window), adds it otherwise.
    func show(_ tab: InspectorTab) {
        if let maximized = maximizedPane, paneTree.pane(maximized)?.tab != tab { maximizedPane = nil }
        guard !paneTree.contains(tab: tab), !detachedTabs.contains(tab) else { return }
        addPane(tab)
    }

    func setTab(_ tab: InspectorTab, for id: UUID) {
        paneTree = paneTree.updating(id, tab: tab)
    }
}
