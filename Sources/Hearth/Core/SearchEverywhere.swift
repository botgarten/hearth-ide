import Foundation

/// "Search Everywhere" (double Shift, like IntelliJ IDEA): one query across the workspace's
/// files, their text and symbols, the agents' chats, the sessions, the tests and the app's
/// actions. Everything here is plain data and functions, so it runs in tests without UI.
enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case all, files, symbols, text, chat, sessions, tests, actions
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .files: String(localized: "Files")
        case .symbols: String(localized: "Symbols")
        case .text: String(localized: "Text")
        case .chat: String(localized: "Chat")
        case .sessions: String(localized: "Sessions")
        case .tests: String(localized: "Tests")
        case .actions: String(localized: "Actions")
        }
    }

    /// Tab moves to the next category, Shift-Tab to the previous one.
    func next(backwards: Bool = false) -> SearchScope {
        let all = Self.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + (backwards ? all.count - 1 : 1)) % all.count]
    }
}

/// Where a result leads.
enum SearchTarget: Hashable, Sendable {
    case file(path: String, line: Int?)
    case session(runID: String)
    case chat(runID: String, text: String)
    case test(id: String, name: String, className: String)
    case action(id: String)
}

struct SearchItem: Identifiable, Hashable, Sendable {
    var id: String
    var scope: SearchScope
    var title: String
    /// Grey text after the title (folder, line, snippet).
    var subtitle: String = ""
    /// Right-aligned origin (project, session, category).
    var detail: String = ""
    var symbol: String
    var score: Int
    var target: SearchTarget
}

/// A snapshot of what the search can look at, taken on the main actor when it opens.
struct SearchContext: Sendable {
    struct Session: Sendable { var id, title, kind, directory, status: String }
    struct Chat: Sendable { var runID, title, text: String }
    struct Action: Sendable { var id, title, keywords, symbol: String }

    var root: String?
    var sessions: [Session] = []
    var chats: [Chat] = []
    var tests: [TestCase] = []
    var actions: [Action] = []
    /// Recently used files (relative paths), shown for an empty query.
    var recentFiles: [String] = []

    var projectName: String { root.map { ($0 as NSString).lastPathComponent } ?? "" }
}

enum SearchEverywhere {
    static let perScopeInAll = 6
    static let limit = 120

    // MARK: Matching

    /// How well `text` matches `query`, or nil. Substrings rank highest (earlier and at word
    /// starts better), then IntelliJ-style word initials ("mlv" → MainLayoutView,
    /// "app_mod" → app_model), then all space-separated terms in any order.
    static func score(_ text: String, _ query: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return 0 }
        let t = text.lowercased()
        if t == q { return 1000 }
        if let r = t.range(of: q) {
            let offset = t.distance(from: t.startIndex, to: r.lowerBound)
            var s = 700 - min(offset, 200)
            if offset == 0 { s += 150 } else if isWordStart(Array(text), offset) { s += 80 }
            return s - min(t.count - q.count, 100) / 4
        }
        if !q.contains(" "), initialsMatch(Array(text), Array(q)) { return 400 - min(text.count, 100) }
        let terms = q.split(separator: " ")
        if terms.count > 1, terms.allSatisfy({ t.contains($0) }) { return 300 - min(t.count, 100) }
        return nil
    }

    static func isWordStart(_ chars: [Character], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let c = chars[i], p = chars[i - 1]
        if !p.isLetter && !p.isNumber { return true }
        if c.isUppercase && p.isLowercase { return true }
        if c.isNumber && !p.isNumber { return true }
        return false
    }

    /// Each query character matches the next word start or continues the current word.
    static func initialsMatch(_ text: [Character], _ query: [Character]) -> Bool {
        func match(_ ti: Int, _ qi: Int, _ inWord: Bool) -> Bool {
            if qi == query.count { return true }
            if ti >= text.count { return false }
            let same = text[ti].lowercased() == String(query[qi])
            // Continue the current word…
            if inWord, same, match(ti + 1, qi + 1, true) { return true }
            // …or jump to a later word start.
            var j = ti
            while j < text.count {
                if isWordStart(text, j), text[j].lowercased() == String(query[qi]), match(j + 1, qi + 1, true) { return true }
                j += 1
            }
            return false
        }
        return query.count <= 12 && match(0, 0, false)
    }

    // MARK: Workspace index

    /// Relative paths of the workspace's files (skips dependency and build folders).
    static func indexFiles(root: String, limit: Int = 50_000) -> [String] {
        // Resolve first: the enumerator reports real paths (/private/var for /var, a symlinked
        // Documents folder), and relative paths are cut off by the root's length.
        // (`resolvingSymlinksInPath` strips "/private" again, so it can't be used here.)
        let rootURL = URL(fileURLWithPath: realPath(root))
        guard let it = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var files: [String] = []
        while let url = it.nextObject() as? URL, files.count < limit {
            if Task.isCancelled { break }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if FileSearch.skipped.contains(url.lastPathComponent) || url.lastPathComponent == "node_modules" {
                if isDir { it.skipDescendants() }
                continue
            }
            if !isDir { files.append(String(url.path.dropFirst(rootURL.path.count + 1))) }
        }
        return files
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func files(_ query: String, in index: [String], context: SearchContext) -> [SearchItem] {
        let paths = query.isEmpty ? context.recentFiles : index
        var items: [SearchItem] = []
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let folder = (path as NSString).deletingLastPathComponent
            let s: Int?
            if query.isEmpty { s = 500 - items.count }
            else if let n = score(name, query) { s = n + 200 }
            else { s = score(path, query) }
            guard let s else { continue }
            items.append(SearchItem(id: "file:" + path, scope: .files, title: name, subtitle: folder.isEmpty ? "." : folder,
                                    detail: context.projectName, symbol: fileSymbol(name), score: s, target: .file(path: path, line: nil)))
        }
        return top(items)
    }

    static func fileSymbol(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift", "java", "kt", "kts", "go", "rs", "c", "h", "cpp", "cs", "rb", "py", "js", "ts", "tsx", "jsx": "chevron.left.forwardslash.chevron.right"
        case "md", "markdown", "txt": "doc.text"
        case "json", "yml", "yaml", "toml", "xml", "properties", "plist": "gearshape"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico": "photo"
        default: "doc"
        }
    }

    // MARK: Text and symbols

    static let textExtensions: Set<String> = [
        "swift", "java", "kt", "kts", "go", "rs", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "rb", "py", "js", "mjs", "cjs",
        "ts", "tsx", "jsx", "vue", "html", "htm", "css", "scss", "less", "md", "markdown", "txt", "json", "yml", "yaml", "toml",
        "xml", "properties", "gradle", "sh", "bash", "zsh", "sql", "env", "ini", "cfg", "conf", "groovy", "scala", "php", "dart",
        "mmd", "dockerfile", "makefile",
    ]

    static func isTextFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return textExtensions.contains((name as NSString).pathExtension) || ["dockerfile", "makefile", "readme", "license"].contains(name)
    }

    static func read(_ root: String, _ path: String) -> String? {
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
              let data = try? Data(contentsOf: url), !data.prefix(1024).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Lines containing the query (case-insensitive), in index order.
    static func text(_ query: String, root: String, index: [String], limit: Int = 150) -> [SearchItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        var items: [SearchItem] = []
        for path in index where isTextFile(path) {
            if Task.isCancelled || items.count >= limit { break }
            guard let content = read(root, path), content.range(of: q, options: .caseInsensitive) != nil else { continue }
            var line = 0
            content.enumerateLines { text, stop in
                line += 1
                guard text.range(of: q, options: .caseInsensitive) != nil else { return }
                let snippet = text.trimmingCharacters(in: .whitespaces)
                items.append(SearchItem(id: "text:\(path):\(line)", scope: .text, title: String(snippet.prefix(160)),
                                        subtitle: "\((path as NSString).lastPathComponent):\(line)", detail: (path as NSString).deletingLastPathComponent,
                                        symbol: "text.alignleft", score: 100, target: .file(path: path, line: line)))
                if items.count >= limit { stop = true }
            }
        }
        return items
    }

    /// Definitions (types, functions) by keyword; language-agnostic on purpose.
    static let definition = try! NSRegularExpression(pattern:
        #"\b(class|interface|enum|record|struct|protocol|extension|object|trait|actor|typealias|func|fun|def|function|fn|type)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#)

    struct Symbol: Hashable, Sendable { var name, kind, path: String; var line: Int }

    static func indexSymbols(root: String, index: [String], limit: Int = 30_000) -> [Symbol] {
        var symbols: [Symbol] = []
        for path in index where isTextFile(path) && !["md", "markdown", "txt", "json", "yml", "yaml", "xml"].contains((path as NSString).pathExtension.lowercased()) {
            if Task.isCancelled || symbols.count >= limit { break }
            guard let content = read(root, path) else { continue }
            let ns = content as NSString
            for m in definition.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 2))
                let kind = ns.substring(with: m.range(at: 1))
                symbols.append(Symbol(name: name, kind: kind, path: path, line: SymbolFinder.lineNumber(of: m.range.location, in: ns)))
            }
        }
        return symbols
    }

    static func symbols(_ query: String, in symbols: [Symbol]) -> [SearchItem] {
        guard !query.isEmpty else { return [] }
        let items = symbols.compactMap { s -> SearchItem? in
            guard let score = score(s.name, query) else { return nil }
            let isType = ["class", "interface", "enum", "record", "struct", "protocol", "object", "trait", "actor", "type"].contains(s.kind)
            return SearchItem(id: "symbol:\(s.path):\(s.line):\(s.name)", scope: .symbols, title: s.name,
                              subtitle: "\(s.kind) · \((s.path as NSString).lastPathComponent):\(s.line)",
                              detail: (s.path as NSString).deletingLastPathComponent,
                              symbol: isType ? "cube" : "function", score: score + (isType ? 20 : 0), target: .file(path: s.path, line: s.line))
        }
        return top(items)
    }

    // MARK: Chat, sessions, tests, actions

    static func chat(_ query: String, in chats: [SearchContext.Chat], perSession: Int = 40) -> [SearchItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        var items: [SearchItem] = []
        for chat in chats {
            var found = 0
            for line in chat.text.split(separator: "\n", omittingEmptySubsequences: true).reversed() where found < perSession {
                guard line.range(of: q, options: .caseInsensitive) != nil else { continue }
                found += 1
                let snippet = line.trimmingCharacters(in: .whitespaces)
                items.append(SearchItem(id: "chat:\(chat.runID):\(items.count)", scope: .chat, title: String(snippet.prefix(160)),
                                        detail: chat.title, symbol: "bubble.left", score: 200 - found,
                                        target: .chat(runID: chat.runID, text: q)))
            }
        }
        return items
    }

    static func sessions(_ query: String, in sessions: [SearchContext.Session]) -> [SearchItem] {
        top(sessions.enumerated().compactMap { i, s in
            let haystack = "\(s.title) \(s.kind) \((s.directory as NSString).lastPathComponent)"
            guard let score = query.isEmpty ? 300 - i : (score(s.title, query).map { $0 + 50 } ?? score(haystack, query)) else { return nil }
            return SearchItem(id: "session:" + s.id, scope: .sessions, title: s.title, subtitle: "\(s.kind) · \(s.status)",
                              detail: (s.directory as NSString).lastPathComponent, symbol: "bubble.left.and.bubble.right",
                              score: score, target: .session(runID: s.id))
        })
    }

    static func tests(_ query: String, in tests: [TestCase]) -> [SearchItem] {
        top(tests.compactMap { t in
            let failed = t.outcome == .failed || t.outcome == .error
            let s: Int? = query.isEmpty ? (failed ? 300 : nil) : (score(t.name, query).map { $0 + 50 } ?? score("\(t.className) \(t.name)", query))
            guard let s else { return nil }
            let short = t.className.split(separator: ".").last.map(String.init) ?? t.className
            return SearchItem(id: "test:" + t.id, scope: .tests, title: t.name, subtitle: short, detail: t.outcome.rawValue,
                              symbol: failed ? "xmark.circle" : t.outcome == .skipped ? "minus.circle" : "checkmark.circle",
                              score: s + (failed ? 30 : 0), target: .test(id: t.id, name: t.name, className: t.className))
        })
    }

    static func actions(_ query: String, in actions: [SearchContext.Action]) -> [SearchItem] {
        top(actions.enumerated().compactMap { i, a in
            guard let s = query.isEmpty ? 500 - i : (score(a.title, query).map { $0 + 50 } ?? score("\(a.title) \(a.keywords)", query)) else { return nil }
            return SearchItem(id: "action:" + a.id, scope: .actions, title: a.title, detail: String(localized: "Action"),
                              symbol: a.symbol, score: s, target: .action(id: a.id))
        }, limit: 200)
    }

    static func top(_ items: [SearchItem], limit: Int = SearchEverywhere.limit) -> [SearchItem] {
        Array(items.sorted { $0.score != $1.score ? $0.score > $1.score : $0.title.count < $1.title.count }.prefix(limit))
    }

    /// "All": the best few of every category, in a fixed order (IntelliJ groups them too).
    static func combine(_ byScope: [SearchScope: [SearchItem]]) -> [SearchItem] {
        [SearchScope.actions, .files, .symbols, .sessions, .chat, .tests].flatMap { (byScope[$0] ?? []).prefix(perScopeInAll) }
    }
}

/// Recognises a double tap of Shift (no other key or modifier in between, within 0.4 s).
struct DoubleShiftDetector {
    var interval: TimeInterval = 0.4
    private var lastTap: TimeInterval?
    private var downAt: TimeInterval?

    /// A modifier change. Returns true when this completes a double Shift.
    mutating func flagsChanged(shift: Bool, otherModifiers: Bool, at time: TimeInterval) -> Bool {
        if otherModifiers { lastTap = nil; downAt = nil; return false }
        if shift { downAt = time; return false }
        guard let down = downAt else { return false }
        downAt = nil
        guard time - down < interval else { lastTap = nil; return false }   // held, not tapped
        if let last = lastTap, time - last < interval {
            lastTap = nil
            return true
        }
        lastTap = time
        return false
    }

    /// Any other key breaks the sequence (typing capitals is not a double Shift).
    mutating func keyDown() { lastTap = nil; downAt = nil }
}
