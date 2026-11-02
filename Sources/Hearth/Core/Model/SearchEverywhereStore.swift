import AppKit
import SwiftUI
import Observation
import SwiftTerm

/// State of the Search Everywhere popup: what is searched, the results, the keyboard
/// selection, and what opening a result does. Matching lives in `SearchEverywhere`.
@MainActor
@Observable
final class SearchEverywhereStore {
    private(set) var isOpen = false
    var scope: SearchScope = .all { didSet { if oldValue != scope { search() } } }
    var query = "" { didSet { if oldValue != query { search() } } }
    private(set) var results: [SearchItem] = []
    var selection = 0
    private(set) var searching = false

    @ObservationIgnored weak var model: AppModel?
    /// Developer aid (snapshots): a folder to search when no session is selected.
    @ObservationIgnored var rootOverride: String?
    @ObservationIgnored private var context = SearchContext()
    @ObservationIgnored private var fileIndex: (key: String, files: [String])?
    @ObservationIgnored private var symbolIndex: (key: String, symbols: [SearchEverywhere.Symbol])?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var actionHandlers: [String: @MainActor () -> Void] = [:]
    @ObservationIgnored private var detector = DoubleShiftDetector()
    @ObservationIgnored private var monitor: Any?

    // MARK: Open / close

    /// Opens the popup on `scope`. Double Shift while it is open closes it again.
    func open(_ scope: SearchScope = .all) {
        guard let model else { return }
        context = snapshot(model)
        self.scope = scope
        selection = 0
        isOpen = true
        search()
        if let root = context.root {
            Task {
                let report = await TestReports.load(root: root)
                guard self.isOpen, self.context.root == root else { return }
                self.context.tests = report.cases
                if [.tests, .all].contains(self.scope) { self.search() }
            }
        }
    }

    func toggle(_ scope: SearchScope = .all) {
        if isOpen { close() } else { open(scope) }
    }

    func close() {
        isOpen = false
        task?.cancel()
        searching = false
    }

    /// Double Shift anywhere in the app (like IntelliJ IDEA).
    func installShortcut() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                self.detector.keyDown()
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let others = !flags.intersection([.command, .option, .control, .function]).isEmpty
            if self.detector.flagsChanged(shift: flags.contains(.shift), otherModifiers: others, at: event.timestamp) {
                self.toggle()
            }
            return event
        }
    }

    // MARK: Searching

    func search() {
        task?.cancel()
        guard isOpen else { return }
        let query = query.trimmingCharacters(in: .whitespaces)
        let scope = scope
        let context = context
        searching = true
        task = Task {
            // Typing fast: only the last keystroke searches the text.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(scope == .text ? 180 : 60)) }
            guard !Task.isCancelled else { return }
            let found = await self.results(for: query, scope: scope, context: context)
            guard !Task.isCancelled else { return }
            self.results = found
            self.selection = 0
            self.searching = false
        }
    }

    private func results(for query: String, scope: SearchScope, context: SearchContext) async -> [SearchItem] {
        let root = context.root
        func files() async -> [SearchItem] {
            let index = await self.files(root)
            return await Task.detached { SearchEverywhere.files(query, in: index, context: context) }.value
        }
        func symbols() async -> [SearchItem] {
            guard !query.isEmpty, let root else { return [] }
            let index = await self.symbols(root)
            return await Task.detached { SearchEverywhere.symbols(query, in: index) }.value
        }
        switch scope {
        case .files: return await files()
        case .symbols: return await symbols()
        case .text:
            guard let root else { return [] }
            let index = await self.files(root)
            return await Task.detached { SearchEverywhere.text(query, root: root, index: index) }.value
        case .chat: return SearchEverywhere.chat(query, in: context.chats)
        case .sessions: return SearchEverywhere.sessions(query, in: context.sessions)
        case .tests: return SearchEverywhere.tests(query, in: context.tests)
        case .actions: return SearchEverywhere.actions(query, in: context.actions)
        case .all:
            var byScope: [SearchScope: [SearchItem]] = [:]
            byScope[.files] = await files()
            byScope[.symbols] = await symbols()
            byScope[.sessions] = SearchEverywhere.sessions(query, in: context.sessions)
            byScope[.chat] = SearchEverywhere.chat(query, in: context.chats)
            byScope[.tests] = SearchEverywhere.tests(query, in: context.tests)
            // Without a query, "All" shows recent files and sessions, not every action.
            byScope[.actions] = query.isEmpty ? [] : SearchEverywhere.actions(query, in: context.actions)
            return SearchEverywhere.combine(byScope)
        }
    }

    /// File list of the folder, rebuilt after files settled (an agent at work).
    private func files(_ root: String?) async -> [String] {
        guard let root, let model else { return [] }
        let key = "\(root)#\(model.workspace.settledRevision)"
        if let cached = fileIndex, cached.key == key { return cached.files }
        let files = await Task.detached(priority: .userInitiated) { SearchEverywhere.indexFiles(root: root) }.value
        fileIndex = (key, files)
        return files
    }

    private func symbols(_ root: String) async -> [SearchEverywhere.Symbol] {
        guard let model else { return [] }
        let key = "\(root)#\(model.workspace.settledRevision)"
        if let cached = symbolIndex, cached.key == key { return cached.symbols }
        let files = await self.files(root)
        let symbols = await Task.detached(priority: .userInitiated) { SearchEverywhere.indexSymbols(root: root, index: files) }.value
        symbolIndex = (key, symbols)
        return symbols
    }

    // MARK: Keyboard

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    func nextScope(backwards: Bool = false) { scope = scope.next(backwards: backwards) }

    func activateSelection() {
        guard results.indices.contains(selection) else { return }
        activate(results[selection])
    }

    // MARK: Opening a result

    func activate(_ item: SearchItem) {
        guard let model else { return }
        let query = query.trimmingCharacters(in: .whitespaces)
        close()
        switch item.target {
        case .file(let path, let line):
            guard let root = context.root else { return }
            // Text and symbol hits mark the term in the editor; a file name hit just opens it.
            let term: String? = switch item.scope {
            case .text: query
            case .symbols: item.title
            default: nil
            }
            model.editor.open(URL(fileURLWithPath: root).appendingPathComponent(path), line: line, highlight: term)
        case .session(let id):
            model.selectRun(id)
            model.layout.show(.chat)
        case .chat(let id, let text):
            model.selectRun(id)
            model.layout.show(.chat)
            // Let the terminal move into the chat pane first, then find and reveal the line.
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard let terminal = model.agents.run(id)?.terminal else { return }
                _ = terminal.findNext(text)
            }
        case .test(let id, let name, _):
            model.layout.show(.tests)
            model.workspace.testFocus = WorkspaceState.TestFocus(id: id, name: name)
        case .action(let id):
            actionHandlers[id]?()
        }
    }

    // MARK: Snapshot

    private func snapshot(_ model: AppModel) -> SearchContext {
        var ctx = SearchContext()
        ctx.root = model.workspaceRoot ?? rootOverride
        let runs = model.agents.runs.filter { $0.purpose == .session }
        ctx.sessions = runs.map {
            .init(id: $0.id, title: $0.title, kind: $0.kind.displayName, directory: $0.directory, status: $0.status.rawValue.lowercased())
        }
        ctx.chats = runs.compactMap { run -> SearchContext.Chat? in
            guard let terminal = run.terminal else { return nil }
            // SwiftTerm exposes the scrollback only through its selection: select all, read,
            // clear (within one main-actor turn, so nothing is drawn in between).
            terminal.selectAll()
            let all = terminal.getSelection() ?? ""
            terminal.selectNone()
            let text = String(all.suffix(600_000))
            return .init(runID: run.id, title: run.title, text: text)
        }
        if let root = ctx.root {
            let prefix = root + "/"
            var seen = Set<String>()
            ctx.recentFiles = ([model.editor.file].compactMap { $0 } + model.editor.groups.values.flatMap(\.tabs))
                .map(\.path).filter { $0.hasPrefix(prefix) && seen.insert($0).inserted }
                .map { String($0.dropFirst(prefix.count)) }
        }
        let (actions, handlers) = Self.actions(model)
        ctx.actions = actions
        actionHandlers = handlers
        return ctx
    }

    private static func actions(_ model: AppModel) -> ([SearchContext.Action], [String: @MainActor () -> Void]) {
        var list: [SearchContext.Action] = []
        var handlers: [String: @MainActor () -> Void] = [:]
        func add(_ id: String, _ title: String, _ keywords: String = "", _ symbol: String, _ run: @escaping @MainActor () -> Void) {
            list.append(.init(id: id, title: title, keywords: keywords, symbol: symbol))
            handlers[id] = run
        }
        add("agent.start", String(localized: "Start agent…"), "new session sandbox claude codex", "plus") { model.agents.startSheet = .init() }
        for tab in InspectorTab.allCases {
            add("show." + tab.rawValue, String(localized: "Show \(tab.title)"), "area pane panel open", tab.symbol) { model.layout.show(tab) }
        }
        add("settings", String(localized: "Settings…"), "preferences options", "gearshape") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        for theme in AppAppearance.allCases {
            add("theme." + theme.rawValue, String(localized: "Theme: \(theme.title)"), "appearance color dark light", "paintpalette") {
                AppAppearance.current = theme
            }
        }
        add("zoom.in", String(localized: "Larger text"), "zoom font size", "plus.magnifyingglass") { model.textZoom.zoomAll(by: 1.1) }
        add("zoom.out", String(localized: "Smaller text"), "zoom font size", "minus.magnifyingglass") { model.textZoom.zoomAll(by: 1 / 1.1) }
        add("zoom.reset", String(localized: "Actual size"), "zoom font size reset", "textformat.size") { model.textZoom.reset() }
        for preset in LayoutPreset.allCases {
            add("layout." + preset.rawValue, String(localized: "Layout: \(preset.title)"), "arrange panes", preset.symbol) {
                withAnimation(.easeOut(duration: 0.2)) { model.layout.apply(preset) }
            }
        }
        add("workspace.refresh", String(localized: "Refresh workspace"), "reload files git status", "arrow.clockwise") { model.workspace.refreshNow() }
        if let root = model.workspaceRoot {
            add("git.pull", String(localized: "Git: Pull"), "update fetch merge", "arrow.down.circle") {
                Task {
                    let result = await model.pull(in: root)
                    if result.ok { model.toast(String(localized: "Pull finished")) } else { model.banner = "Git: " + result.output.lastNonEmptyLines(4) }
                    model.workspace.refreshNow()
                }
            }
        }
        add("updates.check", String(localized: "Check for updates"), "version release", "arrow.down.app") {
            Task { await model.updates.check() }
        }
        return (list, handlers)
    }
}
