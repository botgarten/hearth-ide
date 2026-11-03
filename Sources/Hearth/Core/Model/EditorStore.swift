import Foundation
import Observation

enum PreviewMode: String, CaseIterable {
    case file, diff

    /// Also accepts the values saved by earlier versions ("Datei", "Diff").
    init?(saved: String) {
        switch saved {
        case "file", "Datei": self = .file
        case "diff", "Diff": self = .diff
        default: return nil
        }
    }

    var title: String { self == .file ? String(localized: "File") : String(localized: "Diff") }
}

struct PreviewLocation: Equatable {
    let url: URL
    let line: Int?
}

/// Tabs and navigation state of one editor (Preview pane).
@MainActor
@Observable
final class EditorGroup {
    var tabs: [URL] = [] { didSet { UIStateStore.save(tabs.map(\.path), as: .openTabs) } }
    var file: URL? { didSet { UIStateStore.save(file?.path, as: .previewFile) } }
    var mode: PreviewMode = .file { didSet { UIStateStore.save(mode.rawValue, as: .previewMode) } }
    var line: Int?
    /// Search term to mark in the shown file (from Search Everywhere); nil for a normal open.
    var highlight: String?
    var back: [PreviewLocation] = []
    var forward: [PreviewLocation] = []

    func remove(_ url: URL) {
        guard let i = tabs.firstIndex(of: url) else { return }
        tabs.remove(at: i)
        if file == url {
            file = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)]
            line = nil
        }
    }
}

/// Every editor (one per Preview pane): open files, unsaved documents, navigation,
/// "go to definition" and the per-session tab sets.
@MainActor
@Observable
final class EditorStore {
    let layout: LayoutStore
    /// Folder of the selected session (relative paths, definition search).
    @ObservationIgnored var workspaceRoot: () -> String? = { nil }
    @ObservationIgnored var notify: (String) -> Void = { _ in }

    init(layout: LayoutStore) {
        self.layout = layout
    }

    // MARK: Editor groups

    var groups: [UUID: EditorGroup] = [:]
    /// Preview pane that receives openPreview() and the editor shortcuts.
    var activeEditorID: UUID? { didSet { if oldValue != activeEditorID { invalidateDefinition() } } }
    /// Holds tabs while no Preview pane exists (e.g. restored state before layout).
    private let looseEditor = EditorGroup()

    /// Moves a tab from one editor to another.
    struct TabDrag: Equatable { let pane: UUID; let url: URL }
    /// Tab currently being dragged (in-process); pane drop zones ignore such drags.
    var draggingTab: TabDrag?

    func group(_ paneID: UUID) -> EditorGroup {
        if let g = groups[paneID] { return g }
        // The first pane adopts the tabs opened while no pane existed.
        let g = groups.isEmpty ? looseEditor : EditorGroup()
        groups[paneID] = g
        return g
    }

    var active: EditorGroup {
        let ids = layout.editorPaneIDs
        if let id = activeEditorID, ids.contains(id), let g = groups[id] { return g }
        if let id = ids.first(where: { groups[$0] != nil }) { return groups[id]! }
        return groups.isEmpty ? looseEditor : (ids.first.map { groups[$0] } ?? nil) ?? looseEditor
    }

    /// Editors in layout order (at least one).
    var orderedGroups: [EditorGroup] {
        let ordered = layout.editorPaneIDs.compactMap { groups[$0] }
        return ordered.isEmpty ? [active] : ordered
    }

    /// A pane was closed: forget its editor, keep unsaved documents reachable in another one.
    func paneClosed(_ id: UUID) {
        guard let g = groups[id], groups.count > 1 else { return }
        groups[id] = nil
        if let other = layout.editorPaneIDs.first.flatMap({ groups[$0] }) {
            for t in g.tabs where documents[t]?.isDirty == true && !other.tabs.contains(t) { other.tabs.append(t) }
        }
    }

    /// Opens a second editor next to `paneID`, showing `url` (or the same file).
    func splitEditor(_ paneID: UUID, axis: SplitAxis = .horizontal, url: URL? = nil) {
        let source = group(paneID)
        let pane = InspectorPane(tab: .preview)
        layout.paneTree = layout.paneTree.splitting(paneID, axis: axis, with: pane)
        let g = EditorGroup()
        groups[pane.id] = g
        if let u = url ?? source.file {
            g.tabs = [u]
            g.file = u
            g.mode = source.mode
        }
        activeEditorID = pane.id
    }

    /// Reorders a tab within an editor, or moves it into another editor, before `target`
    /// (nil = at the end). The moved tab becomes the visible one.
    func placeTab(_ url: URL, from: UUID, to: UUID, before target: URL?) {
        let src = group(from), dst = group(to)
        guard src.tabs.contains(url) else { return }
        dst.tabs = TabOrdering.place(url, in: dst.tabs, before: target)
        if src !== dst { src.remove(url) }
        dst.file = url
        activeEditorID = to
    }

    func moveTab(_ url: URL, from: UUID, to: UUID) {
        let src = group(from), dst = group(to)
        if !dst.tabs.contains(url) { dst.tabs.append(url) }
        dst.file = url
        src.remove(url)
        activeEditorID = to
    }

    // MARK: Active editor shortcuts

    /// File shown in the active editor.
    var file: URL? {
        get { active.file }
        set { active.file = newValue }
    }
    var mode: PreviewMode {
        get { active.mode }
        set { active.mode = newValue }
    }
    /// Line to highlight and scroll to in the file preview.
    var line: Int? {
        get { active.line }
        set { active.line = newValue }
    }
    /// Term marked in the active editor's file.
    var highlight: String? {
        get { active.highlight }
        set { active.highlight = newValue }
    }
    var tabs: [URL] {
        get { active.tabs }
        set { active.tabs = newValue }
    }

    func open(_ url: URL, mode: PreviewMode = .file, line: Int? = nil, highlight: String? = nil, recordHistory: Bool = true) {
        if file != url {
            invalidateDefinition()
        }
        if recordHistory, let current = file, current != url || self.line != line {
            active.back.append(PreviewLocation(url: current, line: self.line))
            if active.back.count > 50 { active.back.removeFirst() }
            active.forward.removeAll()
        }
        if !tabs.contains(url) {
            // Open next to the current tab, like IDEs do.
            let at = file.flatMap { tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? tabs.count
            tabs.insert(url, at: at)
        }
        file = url
        self.mode = mode
        self.line = line
        self.highlight = highlight
        if layout.editorPaneIDs.isEmpty, let last = layout.paneTree.panes.last {
            layout.split(last.id, axis: .vertical, tab: .preview)
        }
    }

    /// Restores the last session's tabs (before any per-session state exists).
    func restore() {
        if let raw: String = UIStateStore.load(.previewMode), let mode = PreviewMode(saved: raw) { self.mode = mode }
        if let paths: [String] = UIStateStore.load(.openTabs) {
            tabs = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        }
        if let path: String = UIStateStore.load(.previewFile), FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            file = url
            if !tabs.contains(url) { tabs.append(url) }
        }
    }

    // MARK: Documents

    /// Open documents keep unsaved edits while switching tabs.
    var documents: [URL: PreviewDocument] = [:]
    /// Last known unstaged hunks per "root#path" so revisiting a tab shows them instantly.
    @ObservationIgnored var fileDiffCache: [String: FileDiff] = [:]
    /// workspaceRevision at which each cached diff was loaded.
    @ObservationIgnored var fileDiffRevision: [String: Int] = [:]

    func document(for url: URL) -> PreviewDocument {
        if let d = documents[url] { return d }
        let d = PreviewDocument(url: url)
        documents[url] = d
        return d
    }

    var unsavedDocuments: [PreviewDocument] { documents.values.filter(\.isDirty) }

    /// Closes a tab without asking (callers confirm unsaved changes first).
    func closeTab(_ url: URL) { closeTab(url, in: active) }

    func closeTab(_ url: URL, in group: EditorGroup) {
        group.remove(url)
        // Documents are shared between editors; drop it once no editor (and no stashed session) shows it.
        let shown = groups.values.contains { $0.tabs.contains(url) } || looseEditor.tabs.contains(url)
        let stashed = workspaces.values.contains { $0.groups.contains { $0.tabs.contains(url) } }
        if !shown && !(stashed && documents[url]?.isDirty == true) {
            documents[url] = nil
        }
    }

    func closeOtherTabs(keeping url: URL) { closeOtherTabs(in: active, keeping: url) }

    func closeOtherTabs(in group: EditorGroup, keeping url: URL) {
        for t in group.tabs where t != url && documents[t]?.isDirty != true { closeTab(t, in: group) }
    }

    // MARK: Code navigation

    /// Set when a ⌘-click matched several declarations; the preview shows a chooser.
    var definitionChoices: (symbol: String, locations: [SymbolLocation])?
    var searchingDefinition: String?
    private var definitionGeneration = UUID()

    func invalidateDefinition() {
        definitionGeneration = UUID(); searchingDefinition = nil; definitionChoices = nil
    }

    func navigateBack() {
        guard let target = active.back.popLast() else { return }
        if let current = file { active.forward.append(PreviewLocation(url: current, line: line)) }
        open(target.url, mode: .file, line: target.line, recordHistory: false)
    }

    func navigateForward() {
        guard let target = active.forward.popLast() else { return }
        if let current = file { active.back.append(PreviewLocation(url: current, line: line)) }
        open(target.url, mode: .file, line: target.line, recordHistory: false)
    }

    func goToDefinition(symbol: String, qualifier: String?) async {
        guard let root = workspaceRoot() else { return }
        let editor = active
        let shown = editor.file
        let generation = UUID()
        definitionGeneration = generation
        let current = file.flatMap { EditorPresentation.relativePath($0, root: root) }
        searchingDefinition = symbol
        let results = await SymbolFinder.find(symbol: symbol, qualifier: qualifier, root: root, currentFile: current)
        guard definitionGeneration == generation else { return }
        guard !Task.isCancelled, workspaceRoot() == root, active === editor, editor.file == shown else {
            invalidateDefinition()
            return
        }
        searchingDefinition = nil
        definitionChoices = nil
        // Ignore the declaration the user is already looking at (⌘-click on the definition itself).
        let others = results.filter { !($0.path == current && $0.line == line) }
        switch others.count {
        case 0:
            notify(results.isEmpty ? String(localized: "No definition found for “\(symbol)”") : String(localized: "This already is the definition of “\(symbol)”"))
        case 1:
            open(others[0], root: root)
        default:
            definitionChoices = (symbol, others)
        }
    }

    // MARK: Find usages

    /// The last "Find Usages" and where it is shown (the list sits below that editor).
    struct UsageSearch: Equatable {
        var query: UsageQuery
        var pane: UUID
        var result: UsageResult?
        var searching = true
        /// The kinds listed (the search itself is complete; this only filters the list).
        var shownKinds: Set<Usage.Kind> = Set(Usage.Kind.allCases)

        static func == (a: UsageSearch, b: UsageSearch) -> Bool {
            a.query == b.query && a.pane == b.pane && a.searching == b.searching && a.shownKinds == b.shownKinds
                && a.result?.usages.count == b.result?.usages.count
        }
    }

    var usages: UsageSearch?
    private var usageGeneration = UUID()

    /// The editor pane that shows the usages; creates one when only other panes exist.
    private func usagesPane() -> UUID? {
        if layout.editorPaneIDs.isEmpty, let last = layout.paneTree.panes.last {
            layout.split(last.id, axis: .vertical, tab: .preview)
        }
        if let id = activeEditorID, layout.editorPaneIDs.contains(id) { return id }
        return layout.editorPaneIDs.first
    }

    /// ⌥F7 / right-click ▸ Find Usages in the editor: the name under the cursor.
    func findUsages(symbol: String, pane: UUID? = nil) {
        guard let root = workspaceRoot(), SymbolFinder.isIdentifier(symbol) else { return }
        let group = pane.map(self.group) ?? active
        let source = group.file.flatMap { EditorPresentation.relativePath($0, root: root) }
        let restrict = source.map { SymbolFinder.sourceExtensions.contains(($0 as NSString).pathExtension.lowercased()) } ?? false
        runUsages(UsageQuery(text: symbol, scope: restrict ? .sameLanguage : .allFiles, sourcePath: source), root: root, pane: pane)
    }

    /// Right-click ▸ Find Usages on a file or folder in the directory: who uses this class/module/folder.
    func findUsages(of url: URL) {
        guard let root = workspaceRoot(), let query = UsageQuery.forFile(url, root: root) else {
            notify(String(localized: "Nothing to look for here"))
            return
        }
        runUsages(query, root: root, pane: nil)
    }

    func runUsages(_ query: UsageQuery, root: String, pane: UUID?) {
        guard let paneID = pane.flatMap({ layout.editorPaneIDs.contains($0) ? $0 : nil }) ?? usagesPane() else { return }
        let generation = UUID()
        usageGeneration = generation
        usages = UsageSearch(query: query, pane: paneID, result: nil, searching: true, shownKinds: usages?.shownKinds ?? Set(Usage.Kind.allCases))
        // Unsaved edits count: search what the editor shows, not only the disk.
        var unsaved: [String: String] = [:]
        for doc in unsavedDocuments {
            if let relative = EditorPresentation.relativePath(doc.url, root: root) { unsaved[relative] = doc.text }
        }
        Task {
            let result = await UsageFinder.find(query, root: root, overrides: unsaved)
            guard usageGeneration == generation, workspaceRoot() == root else { return }
            usages?.result = result
            usages?.searching = false
        }
    }

    func changeUsageScope(_ scope: UsageQuery.Scope) {
        guard var current = usages, let root = workspaceRoot() else { return }
        current.query.scope = scope
        runUsages(current.query, root: root, pane: current.pane)
    }

    func closeUsages() {
        usageGeneration = UUID()
        usages = nil
    }

    /// Opens a usage in the editor that shows the list.
    func open(_ usage: Usage, in pane: UUID, root: String) {
        activeEditorID = pane
        let term = usages?.query.text
        open(URL(fileURLWithPath: root).appendingPathComponent(usage.path), mode: .file, line: usage.line,
             highlight: term.flatMap { SymbolFinder.isIdentifier($0) ? $0 : nil })
    }

    func open(_ location: SymbolLocation, root: String) {
        definitionChoices = nil
        open(URL(fileURLWithPath: root).appendingPathComponent(location.path), mode: .file, line: location.line)
    }

    /// Opens `fileName:line` from a stack trace if the file exists in the workspace.
    func reveal(fileName: String, line: Int?) async {
        guard let root = workspaceRoot() else { return }
        let hits = await FileSearch.find(fileName, in: root).filter { !$0.isDirectory && $0.name == fileName }
        guard !Task.isCancelled, workspaceRoot() == root else { return }
        if let hit = hits.first {
            open(URL(fileURLWithPath: root).appendingPathComponent(hit.relativePath), mode: .file, line: line)
        } else {
            notify(String(localized: "\(fileName) not found in the workspace"))
        }
    }

    // MARK: Tabs per session

    /// Editor tabs of the sessions not shown right now, by session key.
    var workspaces: [String: EditorWorkspace] = UIStateStore.load(.editorWorkspaces) ?? [:] {
        didSet { UIStateStore.save(workspaces, as: .editorWorkspaces) }
    }
    /// Session whose tabs the editors show (nil = not yet assigned, e.g. right after launch).
    var shownWorkspace: String? = UIStateStore.load(.shownEditorWorkspace) {
        didSet { UIStateStore.save(shownWorkspace, as: .shownEditorWorkspace) }
    }

    /// Stashes the shown tabs under their session and shows the tabs of `key`.
    /// `selectedFile` is the directory tree's selection, kept per session too.
    /// `keep` lists the session keys that still exist; stashes of others are dropped.
    func switchWorkspace(to key: String, selectedFile: inout URL?, keep: (String) -> Bool) {
        let oldKey = shownWorkspace
        guard oldKey != key else { return }
        var stash = workspaces
        let ordered = orderedGroups
        let current = EditorWorkspace(groups: ordered.map(EditorSnapshot.init), selectedFile: selectedFile)
        if let oldKey { stash[oldKey] = current }
        // Tabs not assigned to any session yet (first launch with this feature) go to the new one.
        let target = stash[key] ?? (oldKey == nil ? current : EditorWorkspace())
        for (i, group) in ordered.enumerated() {
            var snapshot = i < target.groups.count ? target.groups[i] : EditorSnapshot()
            // More editors were open there than now: keep the extra tabs in the last one.
            if i == ordered.count - 1 {
                for extra in target.groups.dropFirst(ordered.count) {
                    snapshot.tabs += extra.tabs.filter { !snapshot.tabs.contains($0) }
                }
            }
            snapshot.restore(into: group)
        }
        selectedFile = target.selectedFile
        invalidateDefinition()
        closeUsages()
        shownWorkspace = key
        workspaces = stash.filter { keep($0.key) }
    }
}

struct EditorWorkspace: Codable, Equatable {
    var groups: [EditorSnapshot] = []
    var selectedFile: URL?
}

struct EditorSnapshot: Codable, Equatable {
    var tabs: [URL] = []
    var file: URL?
    var mode: String = PreviewMode.file.rawValue
    var line: Int?
    /// History stays in memory only.
    var back: [PreviewLocation] = []
    var forward: [PreviewLocation] = []

    enum CodingKeys: String, CodingKey { case tabs, file, mode, line }

    init() {}

    @MainActor init(_ group: EditorGroup) {
        tabs = group.tabs
        file = group.file
        mode = group.mode.rawValue
        line = group.line
        back = group.back
        forward = group.forward
    }

    @MainActor func restore(into group: EditorGroup) {
        let existing = tabs.filter { FileManager.default.fileExists(atPath: $0.path) }
        group.tabs = existing
        group.file = file.flatMap { existing.contains($0) ? $0 : nil } ?? existing.first
        group.mode = PreviewMode(saved: mode) ?? .file
        group.line = group.file == file ? line : nil
        group.back = back
        group.forward = forward
    }
}
