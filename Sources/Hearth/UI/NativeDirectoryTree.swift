import SwiftUI
import AppKit

/// NSOutlineView handles the click-vs-drag threshold and drop negotiation itself.
/// Cells deliberately contain no Buttons/SwiftUI gestures that consume mouseDown.
struct NativeDirectoryTree: NSViewRepresentable {
    let root: String
    let markers: [String: String]
    let expandedPaths: Set<String>
    let selectedFile: URL?
    let revealID: UUID
    let revision: Int
    let scale: Double
    let dragToken: UUID
    var matches: [FileSearch.Match]? = nil
    let select: (FileNode) -> Void
    let expand: (URL, Bool) -> Void
    let move: (URL, URL) -> Bool
    let menu: (FileNode?) -> NSMenu
    /// ⌘C/⌘X act on the selected row; ⌘V receives the selected row (or nil for the root).
    var clipboard: ((FileNode?, ClipboardAction) -> Void)? = nil

    enum ClipboardAction { case copy, cut, paste }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let outline = DirectoryOutline()
        outline.autoresizingMask = [.width]
        context.coordinator.install(outline)
        scroll.documentView = outline
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.synchronize()
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.outline?.dataSource = nil
        coordinator.outline?.delegate = nil
        coordinator.outline?.contextMenu = nil
        coordinator.outline?.clipboard = nil
    }

    final class Node: NSObject {
        let file: FileNode
        private let reveal: URL?
        private var cachedChildren: [Node]?
        init(_ file: FileNode, reveal: URL?) { self.file = file; self.reveal = reveal }
        var children: [Node] {
            if let cachedChildren { return cachedChildren }
            let children = file.children(revealing: reveal).map { Node($0, reveal: reveal) }
            cachedChildren = children
            return children
        }
    }

    final class DirectoryOutline: NSOutlineView, NSMenuItemValidation {
        var contextMenu: ((FileNode?) -> NSMenu)?
        override func menu(for event: NSEvent) -> NSMenu? {
            let row = row(at: convert(event.locationInWindow, from: nil))
            return contextMenu?((item(atRow: row) as? Node)?.file)
        }

        /// Reached through the responder chain from the standard Edit menu (⌘C/⌘X/⌘V).
        var clipboard: ((FileNode?, ClipboardAction) -> Void)?
        private var selectedFile: FileNode? { selectedRow >= 0 ? (item(atRow: selectedRow) as? Node)?.file : nil }
        @objc func copy(_ sender: Any?) { if let file = selectedFile { clipboard?(file, .copy) } }
        @objc func cut(_ sender: Any?) { if let file = selectedFile { clipboard?(file, .cut) } }
        @objc func paste(_ sender: Any?) { clipboard?(selectedFile, .paste) }
        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            switch item.action {
            case #selector(copy(_:)), #selector(cut(_:)): clipboard != nil && selectedFile != nil
            case #selector(paste(_:)): clipboard != nil && WorkspaceClipboard.hasFiles(.general)
            default: responds(to: item.action)
            }
        }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: NativeDirectoryTree
        weak var outline: DirectoryOutline?
        private var roots: [Node] = []
        private var appliedRoot: String?
        private var appliedRevision: Int?
        private var appliedMarkers: [String: String] = [:]
        private var appliedMatches: [FileSearch.Match]?
        private var appliedScale: Double?
        private var appliedReveal: UUID?
        private var synchronizing = false
        private var dragging = false

        init(_ parent: NativeDirectoryTree) { self.parent = parent }

        func install(_ view: DirectoryOutline) {
            outline = view
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            column.resizingMask = .autoresizingMask
            column.minWidth = 80
            view.addTableColumn(column)
            view.outlineTableColumn = column
            view.headerView = nil
            view.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            view.backgroundColor = .clear
            view.autoresizingMask = [.width]
            view.intercellSpacing = NSSize(width: 0, height: 1)
            view.allowsMultipleSelection = false
            view.allowsEmptySelection = true
            view.focusRingType = .none
            view.dataSource = self
            view.delegate = self
            view.target = self
            view.action = #selector(clicked)
            view.doubleAction = #selector(doubleClicked)
            view.registerForDraggedTypes([WorkspaceFileDrag.pasteboardType])
            view.setDraggingSourceOperationMask(.move, forLocal: true)
            view.setDraggingSourceOperationMask([], forLocal: false)
            view.contextMenu = { [weak self] file in self?.parent.menu(file) ?? NSMenu() }
            view.clipboard = { [weak self] file, action in self?.parent.clipboard?(file, action) }
            synchronize()
        }

        func synchronize() {
            guard let outline, !dragging else { return }
            synchronizing = true
            defer { synchronizing = false }
            let revealChanged = appliedReveal != parent.revealID
            if appliedRoot != parent.root || appliedRevision != parent.revision ||
                appliedMarkers != parent.markers || appliedMatches != parent.matches ||
                appliedScale != parent.scale || revealChanged {
                if let matches = parent.matches {
                    roots = matches.map { Node(FileNode(url: URL(fileURLWithPath: parent.root).appendingPathComponent($0.relativePath), isDirectory: $0.isDirectory), reveal: parent.selectedFile) }
                } else {
                    roots = FileNode(url: URL(fileURLWithPath: parent.root), isDirectory: true)
                        .children(revealing: parent.selectedFile).map { Node($0, reveal: parent.selectedFile) }
                }
                appliedRoot = parent.root
                appliedRevision = parent.revision
                appliedMarkers = parent.markers
                appliedMatches = parent.matches
                appliedScale = parent.scale
                outline.rowHeight = (parent.matches == nil ? 24 : 38) * parent.scale
                outline.indentationPerLevel = 14 * parent.scale
                outline.reloadData()
            }
            if parent.matches == nil {
                func applyExpansion(_ nodes: [Node], depth: Int) {
                    guard depth < 100 else { return }
                    for node in nodes where node.file.isDirectory {
                        if parent.expandedPaths.contains(node.file.url.path) {
                            outline.expandItem(node)
                            applyExpansion(node.children, depth: depth + 1)
                        } else { outline.collapseItem(node) }
                    }
                }
                applyExpansion(roots, depth: 0)
            }
            if let selected = parent.selectedFile,
               let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? Node)?.file.url.path == selected.path }) {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if revealChanged {
                    outline.scrollRowToVisible(row)
                    let requestedReveal = parent.revealID
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.parent.revealID == requestedReveal,
                              let outline = self.outline, outline.selectedRow >= 0 else { return }
                        // A newly created pane may not have its viewport size until layout.
                        outline.enclosingScrollView?.layoutSubtreeIfNeeded()
                        outline.scrollRowToVisible(outline.selectedRow)
                    }
                }
            } else { outline.deselectAll(nil) }
            appliedReveal = parent.revealID
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Node)?.children.count ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? Node)?.children ?? roots)[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            parent.matches == nil && (item as? Node)?.file.isDirectory == true
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            let id = NSUserInterfaceItemIdentifier("directory-cell")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? Cell ?? Cell()
            cell.identifier = id
            let file = node.file
            let relative = String(file.url.path.dropFirst(parent.root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let marker = parent.markers[relative]
            cell.name.stringValue = file.name
            cell.name.font = .systemFont(ofSize: 13 * parent.scale)
            cell.name.textColor = marker.map(Self.markerColor) ?? .labelColor
            cell.detail.stringValue = parent.matches == nil ? "" : relative
            cell.detail.isHidden = parent.matches == nil
            cell.detail.font = .systemFont(ofSize: 10 * parent.scale)
            cell.marker.stringValue = marker ?? ""
            cell.marker.font = .monospacedSystemFont(ofSize: 10 * parent.scale, weight: .semibold)
            cell.marker.textColor = marker.map(Self.markerColor) ?? .secondaryLabelColor
            cell.icon.image = NSImage(systemSymbolName: file.isDirectory ? "folder" : FileIcon.symbol(for: file.url), accessibilityDescription: nil)
            cell.icon.contentTintColor = file.isDirectory ? .controlAccentColor : .secondaryLabelColor
            cell.toolTip = file.url.path
            return cell
        }

        @objc private func clicked() {
            guard !synchronizing, !dragging, let outline, outline.clickedRow >= 0,
                  let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
            parent.select(node.file)
        }
        @objc private func doubleClicked() {
            guard let outline, let node = outline.item(atRow: outline.clickedRow) as? Node, node.file.isDirectory,
                  parent.matches == nil else { return }
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            // Mouse selection happens on mouseDown, before the drag threshold.
            // Opening an editor here could split/rebuild the pane tree mid-drag.
            // Mouse clicks use the table action on mouseUp; keyboard selection opens directly.
            guard !synchronizing, !dragging, NSApp.currentEvent?.type == .keyDown,
                  let outline, outline.selectedRow >= 0,
                  let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
            parent.select(node.file)
        }
        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !synchronizing, let node = notification.userInfo?["NSObject"] as? Node else { return }
            parent.expand(node.file.url, true)
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !synchronizing, let node = notification.userInfo?["NSObject"] as? Node else { return }
            parent.expand(node.file.url, false)
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? Node else { return nil }
            return WorkspaceFileDrag(source: node.file.url, root: parent.root, token: parent.dragToken).pasteboardItem
        }
        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
            dragging = true
        }
        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false
            synchronize()
        }

        /// Shared by AppKit validation/acceptance and regression tests.
        func validatedDrop(_ data: Data?, onto item: Node?) -> (source: URL, directory: URL)? {
            guard let data, let drag = WorkspaceFileDrag.decode(data, root: parent.root, token: parent.dragToken),
                  item == nil || item?.file.isDirectory == true else { return nil }
            let directory = item?.file.url ?? URL(fileURLWithPath: parent.root)
            guard (try? WorkspaceFiles.moveDestination(source: drag.source, directory: directory, root: URL(fileURLWithPath: parent.root))) != nil else { return nil }
            return (drag.source, directory)
        }
        func accept(_ data: Data?, onto item: Node?) -> Bool {
            guard let drop = validatedDrop(data, onto: item) else { return false }
            return parent.move(drop.source, drop.directory)
        }
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard info.draggingSourceOperationMask.contains(.move),
                  validatedDrop(info.draggingPasteboard.data(forType: WorkspaceFileDrag.pasteboardType), onto: item as? Node) != nil else { return [] }
            outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex: Int) -> Bool {
            accept(info.draggingPasteboard.data(forType: WorkspaceFileDrag.pasteboardType), onto: item as? Node)
        }

        private static func markerColor(_ marker: String) -> NSColor {
            switch marker { case "A", "U", "?": .systemGreen; case "D": .systemRed; case "M": .systemOrange; case "R": .systemBlue; default: .secondaryLabelColor }
        }
    }

    final class Cell: NSTableCellView {
        let icon = NSImageView()
        let name = NSTextField(labelWithString: "")
        let detail = NSTextField(labelWithString: "")
        let marker = NSTextField(labelWithString: "")
        override init(frame: NSRect) {
            super.init(frame: frame)
            let labels = NSStackView(views: [name, detail])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 0
            detail.textColor = .secondaryLabelColor
            name.lineBreakMode = .byTruncatingMiddle
            detail.lineBreakMode = .byTruncatingHead
            name.maximumNumberOfLines = 1
            detail.maximumNumberOfLines = 1
            marker.setContentHuggingPriority(.required, for: .horizontal)
            for view in [icon, labels, marker] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3), icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5), labels.centerYAnchor.constraint(equalTo: centerYAnchor),
                labels.trailingAnchor.constraint(lessThanOrEqualTo: marker.leadingAnchor, constant: -5),
                marker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), marker.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
        convenience init() { self.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
    }
}
