import SwiftUI
import UniformTypeIdentifiers

/// The whole window content: one tree of movable, resizable panes.
struct WorkspaceLayoutView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let id = model.layout.maximizedPane, let pane = model.layout.paneTree.pane(id) {
                PaneView(pane: pane)
            } else {
                PaneTreeView(node: model.layout.paneTree)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.layout.maximizedPane)
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { PaneSizes.shared.root = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in PaneSizes.shared.root = f }
            }
        }
        .overlay { windowEdgeHighlight }
        .task(id: "\(model.workspaceRoot ?? "")#\(model.workspace.settledRevision)") {
            guard let root = model.workspaceRoot else { model.workspace.gitSnapshot = GitSnapshot(); return }
            let revision = model.workspace.settledRevision
            let snapshot = await Git.snapshot(of: root)
            guard !Task.isCancelled, model.workspaceRoot == root, model.workspace.settledRevision == revision else { return }
            model.workspace.gitSnapshot = snapshot
        }
    }
}

extension WorkspaceLayoutView {
    /// Strip along the whole window edge while a pane is dragged there.
    @ViewBuilder
    var windowEdgeHighlight: some View {
        if let zone = model.layout.windowDropZone {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let r: CGRect = switch zone {
                case .windowLeft: CGRect(x: 0, y: 0, width: w * 0.3, height: h)
                case .windowRight: CGRect(x: w * 0.7, y: 0, width: w * 0.3, height: h)
                case .windowTop: CGRect(x: 0, y: 0, width: w, height: h * 0.3)
                default: CGRect(x: 0, y: h * 0.7, width: w, height: h * 0.3)
                }
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2))
                    .overlay {
                        Label(zone == .windowBottom || zone == .windowTop ? "Full width" : "Full height",
                              systemImage: "rectangle.bottomthird.inset.filled")
                            .font(.callout.bold()).foregroundStyle(Color.accentColor)
                    }
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            }
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.1), value: zone)
        }
    }
}

/// Renders the split tree recursively with resizable dividers.
struct PaneTreeView: View {
    let node: PaneNode

    var body: some View {
        switch node {
        case .leaf(let pane):
            PaneView(pane: pane)
        case .split(let id, let axis, let children):
            SplitStack(id: id, axis: axis, count: children.count) { i in
                AnyView(PaneTreeView(node: children[i]))
            }
        }
    }
}

private let paneDragPrefix = "hearth-pane:"

struct PaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let pane: InspectorPane

    private var zoomArea: TextArea { .pane(pane.id, pane.tab) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zoomableText(zoomArea, model: model)
        }
        .overlay { dropHighlight }
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { PaneSizes.shared[pane.id] = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in PaneSizes.shared[pane.id] = f }
            }
        }
        .onDrop(of: [.plainText], delegate: PaneDropDelegate(target: pane.id, model: model))
    }

    // MARK: Header (drag handle)

    private var header: some View {
        let maximized = model.layout.maximizedPane == pane.id
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                .help("Drag to move the area")
            Menu {
                ForEach(InspectorTab.allCases) { tab in
                    Button { model.layout.setTab(tab, for: pane.id) } label: { Label(tab.title, systemImage: tab.symbol) }
                }
            } label: {
                Label(pane.tab.title, systemImage: pane.tab.symbol).scaledFont(.caption, bold: true)
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Menu {
                Button { model.textZoom.zoom(zoomArea, by: 1.1) } label: { Label("Larger", systemImage: "plus.magnifyingglass") }
                Button { model.textZoom.zoom(zoomArea, by: 1 / 1.1) } label: { Label("Smaller", systemImage: "minus.magnifyingglass") }
                Divider()
                Button("Reset (\(Int((model.textZoom.scale(zoomArea.base) * 100).rounded())) %)") { model.textZoom.reset(zoomArea) }
            } label: {
                let percent = Int((model.textZoom.scale(zoomArea) * 100).rounded())
                if percent == 100 { Image(systemName: "textformat.size") } else { Text("\(percent) %").font(.caption2.monospacedDigit()) }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.secondary)
            .help("Text size of this area (also ⌘-scroll or pinch over the area)")
            // Layout actions only make sense for panes in the main window's tree.
            if model.layout.paneTree.pane(pane.id) != nil {
                Button { model.layout.split(pane.id, axis: .horizontal) } label: { Image(systemName: "rectangle.split.2x1") }
                    .help("Split right")
                Button { model.layout.split(pane.id, axis: .vertical) } label: { Image(systemName: "rectangle.split.1x2") }
                    .help("Split down")
                Button { model.layout.toggleMaximize(pane.id) } label: {
                    Image(systemName: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(maximized ? "Restore (double-click the header)" : "Maximize (double-click the header)")
                Button {
                    if let tab = model.layout.detach(pane.id) { openWindow(value: tab) }
                } label: { Image(systemName: "macwindow.on.rectangle") }
                    .help("Open in its own window")
                if model.layout.paneTree.panes.count > 1 {
                    Button { model.layout.closePane(pane.id) } label: { Image(systemName: "xmark") }
                        .help("Close area")
                }
            }
        }
        .buttonStyle(.borderless)
        .scaledFont(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.layout.toggleMaximize(pane.id) }
        .onDrag {
            model.editor.draggingTab = nil
            return NSItemProvider(object: (paneDragPrefix + pane.id.uuidString) as NSString)
        } preview: {
            Label(pane.tab.title, systemImage: pane.tab.symbol)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
        }
    }

    // MARK: Drop target preview

    @ViewBuilder
    private var dropHighlight: some View {
        if let hover = model.layout.dropHover, hover.pane == pane.id, !hover.zone.isWindowEdge {
            let zone = hover.zone
            GeometryReader { geo in
                let r = Self.rect(for: zone, in: geo.size)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .overlay {
                        if zone == .center {
                            Label("Swap", systemImage: "arrow.left.arrow.right").font(.callout.bold())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
            }
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.1), value: zone)
        }
    }

    static func rect(for zone: LayoutStore.DropZone, in size: CGSize) -> CGRect {
        let w = size.width, h = size.height
        switch zone {
        case .left: return CGRect(x: 0, y: 0, width: w / 2, height: h)
        case .right: return CGRect(x: w / 2, y: 0, width: w / 2, height: h)
        case .top: return CGRect(x: 0, y: 0, width: w, height: h / 2)
        case .bottom: return CGRect(x: 0, y: h / 2, width: w, height: h / 2)
        case .center: return CGRect(x: w * 0.2, y: h * 0.2, width: w * 0.6, height: h * 0.6)
        default: return .zero
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch pane.tab {
        case .sessions: InboxView()
        case .chat: ChatView()
        case .terminal: TerminalPaneView(root: model.workspaceRoot)
        default:
            if let root = model.workspaceRoot {
                workspaceContent(root)
            } else {
                ContentUnavailableView("No workspace", systemImage: "folder",
                                       description: Text("Select an agent session."))
            }
        }
    }

    @ViewBuilder
    private func workspaceContent(_ root: String) -> some View {
        switch pane.tab {
        case .directory: DirectoryView(root: root, markers: model.workspace.gitSnapshot.markers)
        case .git: GitView(root: root, snapshot: model.workspace.gitSnapshot)
        case .preview:
            PreviewView(root: root, paneID: pane.id)
                .simultaneousGesture(TapGesture().onEnded { model.editor.activeEditorID = pane.id })
        case .pipelines: PipelinesView(root: root)
        case .tests: TestsView(root: root)
        case .architecture: ArchitectureView(root: root)
        case .build: BuildDeployView(root: root)
        case .sessions, .chat, .terminal: EmptyView()
        }
    }
}

/// Decides left/right/top/bottom/center from the pointer position (outer 30 % = edge, middle = swap).
private struct PaneDropDelegate: DropDelegate {
    let target: UUID
    let model: AppModel

    /// Outer 30 % of a pane = dock beside it, middle = swap. Within 32 pt of a pane side that is
    /// also the window border, dock along the whole window edge instead.
    private func zoneFor(_ info: DropInfo, frame: CGRect?) -> LayoutStore.DropZone {
        guard let frame, frame.width > 0, frame.height > 0 else { return .center }
        let p = info.location
        let edgeBand: CGFloat = 32
        if let root = PaneSizes.shared.root {
            let touches: [(LayoutStore.DropZone, Bool, CGFloat)] = [
                (.windowLeft, abs(frame.minX - root.minX) < 3, p.x),
                (.windowRight, abs(frame.maxX - root.maxX) < 3, frame.width - p.x),
                (.windowTop, abs(frame.minY - root.minY) < 3, p.y),
                (.windowBottom, abs(frame.maxY - root.maxY) < 3, frame.height - p.y),
            ]
            if let hit = touches.filter({ $0.1 && $0.2 < edgeBand }).min(by: { $0.2 < $1.2 }) { return hit.0 }
        }
        let x = p.x / frame.width, y = p.y / frame.height
        let edges: [(LayoutStore.DropZone, Double)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        let nearest = edges.min { $0.1 < $1.1 }!
        return nearest.1 < 0.3 ? nearest.0 : .center
    }

    func validateDrop(info: DropInfo) -> Bool { model.editor.draggingTab == nil && info.hasItemsConforming(to: [.plainText]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard model.editor.draggingTab == nil else { return DropProposal(operation: .forbidden) }
        model.layout.hoverDrop(zoneFor(info, frame: PaneSizes.shared[target]), over: target)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        model.layout.endDropHover(leaving: target)
    }

    func performDrop(info: DropInfo) -> Bool {
        let z = zoneFor(info, frame: PaneSizes.shared[target])
        model.layout.endDropHover()
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, s.hasPrefix(paneDragPrefix),
                  let source = UUID(uuidString: String(s.dropFirst(paneDragPrefix.count))) else { return }
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.2)) { model.layout.movePane(source, onto: target, zone: z) }
            }
        }
        return true
    }
}

/// Last known frame of each pane in global coordinates (DropInfo only carries a location).
@MainActor
final class PaneSizes {
    static let shared = PaneSizes()
    private var frames: [UUID: CGRect] = [:]
    /// Frame of the whole layout (window content) in global coordinates.
    var root: CGRect?
    subscript(id: UUID) -> CGRect? {
        get { frames[id] }
        set { frames[id] = newValue }
    }
}

// MARK: Directory

struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }

    static let hidden: Set<String> = [".git", ".DS_Store", ".build", "node_modules", ".idea", ".swiftpm"]

    func children(revealing file: URL? = nil) -> [FileNode] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        return urls
            .filter { !Self.hidden.contains($0.lastPathComponent) || file?.path.hasPrefix($0.path + "/") == true || file?.path == $0.path }
            .map { FileNode(url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }
}

struct DirectoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var scale
    let root: String
    let markers: [String: String]
    private let query = State(initialValue: "")
    private let results = State(initialValue: [FileSearch.Match]())
    private let searching = State(initialValue: false)

    var body: some View {
        let _ = model.workspace.revision
        VStack(spacing: 0) {
            HStack {
                Text(URL(fileURLWithPath: root).lastPathComponent).scaledFont(.caption, bold: true).lineLimit(1)
                Spacer()
                Button { model.revealEditorFile(in: root) } label: { Image(systemName: "scope") }
                    .buttonStyle(.borderless).help("Reveal the active editor file in the directory")
                    .disabled(model.editor.file == nil)
                Menu {
                    DirectoryCreateMenu(directory: URL(fileURLWithPath: root), root: root)
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Create a file or folder in the workspace")
                Button { model.workspace.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh directory")
            }
            .padding(.horizontal, 8).padding(.top, 6)
            .modifier(WorkspaceFileDrop(directory: URL(fileURLWithPath: root), root: root, model: model))
            SearchField(text: query.projectedValue, prompt: String(localized: "Search files…"))
            Divider()
            if query.wrappedValue.count >= 2 {
                tree(matches: results.wrappedValue)
                .overlay(alignment: .topLeading) {
                    if results.wrappedValue.isEmpty && !searching.wrappedValue {
                        Text("No matches").foregroundStyle(.secondary).padding(8).allowsHitTesting(false)
                    }
                }
                .busyOverlay(searching.wrappedValue && results.wrappedValue.isEmpty, label: String(localized: "Searching…"))
                .task(id: "\(root)#\(query.wrappedValue)#\(model.workspace.settledRevision)") {
                    try? await Task.sleep(for: .milliseconds(150))
                    if Task.isCancelled { return }
                    searching.wrappedValue = true
                    let found = await FileSearch.find(query.wrappedValue, in: root)
                    guard !Task.isCancelled else { return }
                    results.wrappedValue = found
                    searching.wrappedValue = false
                }
            } else {
                tree()
            }
        }
        .onChange(of: model.workspace.revealID) { query.wrappedValue = "" }
    }

    private func tree(matches: [FileSearch.Match]? = nil) -> some View {
        NativeDirectoryTree(root: root, markers: markers, expandedPaths: model.workspace.expandedPaths,
            selectedFile: model.workspace.selectedFile ?? model.editor.file, revealID: model.workspace.revealID,
            revision: model.workspace.revision, scale: scale, dragToken: model.workspace.dragToken, matches: matches,
            select: { file in
                model.workspace.selectedFile = file.url
                if !file.isDirectory { model.editor.open(file.url) }
                else if matches != nil {
                    model.workspace.expandedPaths.insert(file.url.path)
                    model.revealEditorFile(file.url, in: root)
                }
            }, expand: { url, expanded in
                if expanded { model.workspace.expandedPaths.insert(url.path) }
                else { model.workspace.expandedPaths.remove(url.path) }
            }, move: { source, destination in
                let oldSelection = model.workspace.selectedFile
                model.workspace.selectedFile = source
                let moved = model.moveWorkspaceItem(source, into: destination, root: root)
                if !moved { model.workspace.selectedFile = oldSelection }
                return moved
            }, menu: { file in model.directoryMenu(for: file, root: root, markers: markers) })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .padding(6)
    }
}

enum FileIcon {
    static func symbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift", "go", "java", "kt", "js", "ts", "tsx", "jsx", "py", "rb", "rs", "c", "h", "cpp", "sh":
            "chevron.left.forwardslash.chevron.right"
        case "md", "markdown", "txt": "doc.text"
        case "json", "yaml", "yml", "toml", "xml", "plist": "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic": "photo"
        case "pdf": "doc.richtext"
        default: "doc"
        }
    }
}

/// Case-insensitive search over file paths below a root; skips heavy folders.
enum FileSearch {
    struct Match: Identifiable, Hashable, Sendable {
        let relativePath: String
        let isDirectory: Bool
        var id: String { relativePath }
        var name: String { (relativePath as NSString).lastPathComponent }
    }

    static let limit = 300
    static let skipped: Set<String> = FileNode.hidden.union(["target", "dist", "build", "vendor", ".gradle", ".venv"])

    static func find(_ query: String, in root: String) async -> [Match] {
        await Task.detached(priority: .userInitiated) {
            let terms = query.lowercased().split(separator: " ").map(String.init)
            let rootURL = URL(fileURLWithPath: root)
            guard let it = FileManager.default.enumerator(
                at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
            var nameHits: [Match] = []
            var pathHits: [Match] = []
            while let url = it.nextObject() as? URL {
                if Task.isCancelled || nameHits.count >= limit { break }
                let name = url.lastPathComponent
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if skipped.contains(name) {
                    if isDir { it.skipDescendants() }
                    continue
                }
                let rel = String(url.path.dropFirst(rootURL.path.count + 1))
                let lowerRel = rel.lowercased()
                guard terms.allSatisfy(lowerRel.contains) else { continue }
                let match = Match(relativePath: rel, isDirectory: isDir)
                // Rank hits in the file name above hits only in the path.
                if terms.allSatisfy(name.lowercased().contains) { nameHits.append(match) } else { pathHits.append(match) }
            }
            return Array((nameHits + pathHits).prefix(limit))
        }.value
    }
}

// MARK: Git

struct GitView: View {
    @Environment(AppModel.self) private var model
    let root: String
    let snapshot: GitSnapshot

    private let branches = State(initialValue: [Git.Branch]())
    private let branchFilter = State(initialValue: "")
    private let showRemote = State(initialValue: false)
    private let busy = State(initialValue: String?.none)
    private let pendingCheckout = State(initialValue: Git.Branch?.none)
    private let pendingDelete = State(initialValue: Git.Branch?.none)
    private let pendingDiscard = State(initialValue: GitFileChange?.none)
    private let newBranchBase = State(initialValue: String?.none)
    private let newBranchName = State(initialValue: "")
    private let shownCommit = State(initialValue: String?.none)
    private let collapsed = State(initialValue: Set<String>())

    static func color(for marker: String) -> Color {
        switch marker {
        case "M": .orange
        case "A", "U": .green
        case "D": .red
        case "R": .blue
        default: .secondary
        }
    }

    var body: some View {
        if !snapshot.isRepo {
            ContentUnavailableView("No Git repository", systemImage: "arrow.triangle.branch")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    headerCard
                    section(String(localized: "Changes"), count: snapshot.changes.count) { changesList }
                    section("Branches", count: visibleBranches.count) { branchList }
                    section(String(localized: "Recent commits"), count: snapshot.recentCommits.count) { commitList }
                }
                .padding(8)
            }
            .busyOverlay(busy.wrappedValue != nil, label: busy.wrappedValue)
            .task(id: "\(root)#\(model.workspace.settledRevision)") { await reloadBranches() }
            .confirmationDialog(checkoutTitle, isPresented: isPresent(pendingCheckout), presenting: pendingCheckout.wrappedValue) { b in
                Button("Switch") { Task { await run(String(localized: "Switching to \(b.localName)…")) { await Git.checkout(b, in: root) } } }
            } message: { _ in
                Text(snapshot.changes.isEmpty
                     ? "The agent then works on this branch."
                     : "There are \(snapshot.changes.count) uncommitted changes. Git carries them over unless they conflict – otherwise the switch is cancelled.")
            }
            .confirmationDialog(String(localized: "Delete branch “\(pendingDelete.wrappedValue?.name ?? "")”?"),
                                isPresented: isPresent(pendingDelete), presenting: pendingDelete.wrappedValue) { b in
                Button("Delete", role: .destructive) {
                    Task { await run(String(localized: "Deleting \(b.name)…")) { await Git.mutate(["branch", "-d", b.name], in: root) } }
                }
            } message: { _ in Text("Only possible once the branch is merged (git branch -d).") }
            .confirmationDialog(String(localized: "Discard the changes to “\(pendingDiscard.wrappedValue?.path ?? "")”?"),
                                isPresented: isPresent(pendingDiscard), presenting: pendingDiscard.wrappedValue) { c in
                Button("Discard", role: .destructive) { Task { await discard(c) } }
            } message: { _ in Text("This cannot be undone.") }
            .alert("New branch", isPresented: Binding(get: { newBranchBase.wrappedValue != nil },
                                                        set: { if !$0 { newBranchBase.wrappedValue = nil } })) {
                TextField("feature/…", text: newBranchName.projectedValue)
                Button("Create & switch") {
                    let base = newBranchBase.wrappedValue ?? "HEAD"
                    let name = newBranchName.wrappedValue.trimmingCharacters(in: .whitespaces)
                    Task { await run("Lege \(name) an …") { await Git.mutate(["switch", "-c", name, base], in: root) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Base: \(newBranchBase.wrappedValue ?? "")")
            }
        }
    }

    // MARK: Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.accentColor)
                Text(snapshot.branch).scaledFont(.body, bold: true, mono: true).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { startNewBranch(from: snapshot.branch) } label: { Image(systemName: "plus") }
                    .help("New branch from the current state")
            }
            if let up = snapshot.upstream {
                HStack(spacing: 8) {
                    Label("\(snapshot.ahead)", systemImage: "arrow.up").foregroundStyle(snapshot.ahead > 0 ? .primary : .secondary)
                    Label("\(snapshot.behind)", systemImage: "arrow.down").foregroundStyle(snapshot.behind > 0 ? .orange : .secondary)
                    Text(up).foregroundStyle(.secondary).lineLimit(1)
                }
                .scaledFont(.caption)
            } else {
                Text("No upstream").scaledFont(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button { Task { await run("Fetch in Sandbox …") { await model.networkGit(.fetch, in: root) } } } label: {
                    Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
                }
                Button { Task { await run("Pull in Sandbox …") { await model.pull(in: root) } } } label: {
                    Label("Pull", systemImage: "arrow.down.circle")
                }
                .disabled(snapshot.upstream == nil)
            }
            .controlSize(.small)
        }
        .buttonStyle(.bordered)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Sections

    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        let isCollapsed = collapsed.wrappedValue.contains(title)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text(title).scaledFont(.caption, bold: true)
                Text("\(count)").scaledFont(.caption2, digits: true)
                    .padding(.horizontal, 5).background(Color.primary.opacity(0.08), in: Capsule())
                Spacer()
            }
            .foregroundStyle(.secondary)
            .interactiveRow {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isCollapsed { collapsed.wrappedValue.remove(title) } else { collapsed.wrappedValue.insert(title) }
                }
            }
            if !isCollapsed { content() }
        }
    }

    @ViewBuilder
    private var changesList: some View {
        if snapshot.changes.isEmpty {
            Label("Working tree clean", systemImage: "checkmark.circle").scaledFont(.callout).foregroundStyle(.secondary)
                .padding(.leading, 6)
        }
        ForEach(snapshot.changes) { change in
            let url = URL(fileURLWithPath: root).appendingPathComponent(change.path)
            HStack(spacing: 6) {
                Text(change.marker).scaledFont(.callout, bold: true, mono: true)
                    .foregroundStyle(Self.color(for: change.marker)).frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(url.lastPathComponent).lineLimit(1)
                    Text((change.path as NSString).deletingLastPathComponent).scaledFont(.caption2)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                if change.added + change.removed > 0 {
                    Text("+\(change.added)").foregroundStyle(.green).scaledFont(.caption, digits: true)
                    Text("-\(change.removed)").foregroundStyle(.red).scaledFont(.caption, digits: true)
                }
            }
            .interactiveRow(selected: model.editor.file == url && model.editor.mode == .diff) {
                model.editor.open(url, mode: .diff)
            }
            .help("Click for diff")
            .contextMenu {
                FileContextMenu(url: url, changed: true)
                Divider()
                Button(role: .destructive) { pendingDiscard.wrappedValue = change } label: {
                    Label("Discard changes…", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    private var visibleBranches: [Git.Branch] {
        let filter = branchFilter.wrappedValue.lowercased()
        return branches.wrappedValue.filter {
            $0.isRemote == showRemote.wrappedValue && (filter.isEmpty || $0.name.lowercased().contains(filter))
        }
    }

    @ViewBuilder
    private var branchList: some View {
        HStack(spacing: 4) {
            Picker("", selection: showRemote.projectedValue) {
                Text("Local").tag(false)
                Text("Remote").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            SearchField(text: branchFilter.projectedValue, prompt: "Filter")
        }
        ForEach(visibleBranches) { b in
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: b.isCurrent ? "checkmark.circle.fill" : (b.isRemote ? "cloud" : "arrow.triangle.branch"))
                    .foregroundStyle(b.isCurrent ? Color.green : .secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(b.name).scaledFont(.callout, mono: true).fontWeight(b.isCurrent ? .bold : .regular).lineLimit(1)
                        if let track = b.track {
                            Text(track).scaledFont(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Text("\(b.date) · \(b.subject)").scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .interactiveRow(selected: b.isCurrent) {
                if !b.isCurrent { pendingCheckout.wrappedValue = b }
            }
            .help(b.isCurrent ? "Current branch" : "Click to check out")
            .contextMenu {
                if !b.isCurrent {
                    Button { pendingCheckout.wrappedValue = b } label: { Label("Check out", systemImage: "arrow.right.circle") }
                }
                Button { startNewBranch(from: b.name) } label: { Label("New branch from here…", systemImage: "plus") }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(b.name, forType: .string)
                    model.toast(String(localized: "Branch name copied"))
                } label: { Label("Copy name", systemImage: "doc.on.doc") }
                if !b.isRemote && !b.isCurrent {
                    Divider()
                    Button(role: .destructive) { pendingDelete.wrappedValue = b } label: { Label("Delete…", systemImage: "trash") }
                }
            }
        }
    }

    @ViewBuilder
    private var commitList: some View {
        ForEach(snapshot.recentCommits, id: \.self) { line in
            let hash = String(line.prefix { $0 != " " })
            HStack(spacing: 6) {
                Text(hash).scaledFont(.caption, mono: true).foregroundStyle(Color.accentColor)
                Text(line.dropFirst(hash.count + 1)).scaledFont(.caption).lineLimit(1)
                Spacer()
            }
            .interactiveRow(selected: shownCommit.wrappedValue == hash) { shownCommit.wrappedValue = hash }
            .popover(isPresented: Binding(get: { shownCommit.wrappedValue == hash },
                                          set: { if !$0 { shownCommit.wrappedValue = nil } }), arrowEdge: .leading) {
                CommitDetail(hash: hash, root: root).frame(width: 560, height: 420)
            }
        }
    }

    // MARK: Actions

    private var checkoutTitle: String {
        String(localized: "Switch to “\(pendingCheckout.wrappedValue?.localName ?? "")”?")
    }

    private func isPresent<T>(_ state: State<T?>) -> Binding<Bool> {
        Binding(get: { state.wrappedValue != nil }, set: { if !$0 { state.wrappedValue = nil } })
    }

    private func startNewBranch(from base: String) {
        newBranchName.wrappedValue = ""
        newBranchBase.wrappedValue = base
    }

    private func reloadBranches() async {
        branches.wrappedValue = await Git.branches(in: root)
    }

    private func run(_ label: String, _ op: () async -> Git.OpResult) async {
        busy.wrappedValue = label
        let result = await op()
        busy.wrappedValue = nil
        if result.ok {
            model.toast(result.output.lastNonEmptyLines(1).isEmpty ? String(localized: "Done") : result.output.lastNonEmptyLines(1))
        } else {
            model.banner = "Git: " + result.output.lastNonEmptyLines(4)
        }
        model.workspace.refreshNow()
        await reloadBranches()
    }

    private func discard(_ change: GitFileChange) async {
        await run(String(localized: "Discarding \(change.path)…")) {
            if change.code == "??" { return await Git.mutate(["clean", "-f", "--", change.path], in: root) }
            return await Git.mutate(["restore", "--staged", "--worktree", "--source=HEAD", "--", change.path], in: root)
        }
    }
}

struct CommitDetail: View {
    let hash: String
    let root: String
    private let text = State(initialValue: String?.none)

    var body: some View {
        Group {
            if let t = text.wrappedValue {
                CodeText(text: t, diff: true)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { text.wrappedValue = await Git.show(commit: hash, in: root) }
    }
}

/// A pane shown in its own window (e.g. on a second screen).
struct DetachedPaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    let tab: InspectorTab

    var body: some View {
        // Reuse the normal pane (header, zoom, content) with a stable id per tab.
        PaneView(pane: InspectorPane(id: Self.id(for: tab), tab: tab))
            .navigationTitle("Hearth IDE – \(tab.title)")
            .toolbar {
                ToolbarItem {
                    Button {
                        model.layout.dock(tab)
                        dismissWindow(value: tab)
                    } label: { Label("Dock again", systemImage: "rectangle.portrait.and.arrow.forward") }
                        .help("Back to the main window")
                }
            }
            .background(WindowAutosave(name: "HearthPane-\(tab.rawValue)"))
            .onAppear { model.layout.detachedTabs.insert(tab) }
            .onDisappear {
                // Closing during quit keeps the window in the list so it reopens next launch.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !model.layout.quitting { model.layout.detachedTabs.remove(tab) }
                }
            }
    }

    /// Deterministic id so the pane keeps its state while the window is open.
    static func id(for tab: InspectorTab) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in tab.rawValue.utf8.enumerated() { bytes[i % 16] ^= b }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
