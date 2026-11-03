import Foundation

/// One place that uses a symbol (IntelliJ's "Find Usages"): where it is (file, line) and
/// who uses it (the class/function around it).
struct Usage: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case definition, code, importLine, comment
    }

    let path: String          // relative to the workspace root
    let line: Int
    /// 0-based UTF-16 offset of the match inside `preview`.
    let column: Int
    let length: Int
    let preview: String
    let kind: Kind
    /// "UserController.createUser": the enclosing declarations, outermost first.
    let container: String?
    var id: String { "\(path):\(line):\(column)" }
}

struct UsageResult: Sendable {
    var usages: [Usage] = []
    var scannedFiles = 0
    /// More usages exist than are listed.
    var truncated = false

    var fileCount: Int { Set(usages.map(\.path)).count }
}

/// What to look for: a name (whole word) and where.
struct UsageQuery: Hashable, Sendable {
    /// Same language family as the file the search started in, or every text file.
    enum Scope: String, Sendable { case sameLanguage, allFiles }

    var text: String
    var scope: Scope = .sameLanguage
    /// Only import-like lines (a folder name is used by its imports).
    var importsOnly = false
    /// Workspace-relative path the search started in (language family, ranking).
    var sourcePath: String?

    /// A plain identifier gets word boundaries on identifier characters; a file name like
    /// `user-service` or `user.service` also treats `-` as part of the name.
    var isIdentifier: Bool { SymbolFinder.isIdentifier(text) }

    /// The name a file or folder is known by: its name without extension(s).
    static func forFile(_ url: URL, root: String) -> UsageQuery? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        let relative = EditorPresentation.relativePath(url, root: root)
        if isDir.boolValue {
            let name = url.lastPathComponent
            guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
            return UsageQuery(text: name, scope: .allFiles, importsOnly: true, sourcePath: relative)
        }
        var name = url.deletingPathExtension().lastPathComponent
        // Foo.test.ts, Foo.spec.js, Foo.d.ts, Foo.g.dart: the thing is still "Foo" unless it is a dotted module.
        if ["test", "spec", "d", "stories", "module", "component"].contains((name as NSString).pathExtension),
           !(name as NSString).deletingPathExtension.isEmpty {
            name = (name as NSString).deletingPathExtension
        }
        guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
        let ext = url.pathExtension.lowercased()
        let source = SymbolFinder.sourceExtensions.contains(ext)
        return UsageQuery(text: name, scope: source ? .sameLanguage : .allFiles, sourcePath: relative)
    }
}

enum UsageFinder {
    static let maxResults = 2000
    static let maxFiles = 20_000
    static let maxBytes = 1_000_000

    /// Text files worth searching when the scope is "all files" (configuration names classes too).
    static let textExtensions: Set<String> = SymbolFinder.sourceExtensions.union([
        "kts", "gradle", "xml", "yml", "yaml", "json", "properties", "toml", "md", "html", "htm", "css", "scss", "less",
        "sql", "sh", "vue", "svelte", "php", "lua", "proto", "tf", "txt", "ini", "cfg", "conf", "mdx", "dart", "ex", "exs",
    ])

    /// Workspace-wide search. `overrides` holds the unsaved text of open documents by workspace-relative path.
    static func find(_ query: UsageQuery, root: String, overrides: [String: String] = [:]) async -> UsageResult {
        guard !query.text.isEmpty else { return UsageResult() }
        return await Task.detached(priority: .userInitiated) { search(query, root: root, overrides: overrides) }.value
    }

    static func search(_ query: UsageQuery, root: String, overrides: [String: String] = [:]) -> UsageResult {
        let rootURL = URL(fileURLWithPath: root)
        let escaped = NSRegularExpression.escapedPattern(for: query.text)
        let nameChars = query.isIdentifier ? "A-Za-z0-9_$" : "A-Za-z0-9_$\\-"
        guard let word = try? NSRegularExpression(pattern: "(?<![\(nameChars)])\(escaped)(?![\(nameChars)])") else { return UsageResult() }
        let family = query.sourcePath.map { SymbolFinder.family(($0 as NSString).pathExtension.lowercased()) }
        let sourceExt = query.sourcePath.map { ($0 as NSString).pathExtension.lowercased() }
        let restrict = query.scope == .sameLanguage && sourceExt.map { SymbolFinder.sourceExtensions.contains($0) } == true

        // Files first (sorted), so the result order doesn't depend on the filesystem.
        var files: [(relative: String, url: URL, ext: String)] = []
        guard let it = FileManager.default.enumerator(atPath: root) else { return UsageResult() }
        while let relative = it.nextObject() as? String, files.count < maxFiles {
            if Task.isCancelled { return UsageResult() }
            let attributes = it.fileAttributes
            if attributes?[.type] as? FileAttributeType == .typeDirectory {
                if SymbolFinder.skipped.contains((relative as NSString).lastPathComponent) { it.skipDescendants() }
                continue
            }
            guard attributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            let ext = (relative as NSString).pathExtension.lowercased()
            if restrict {
                guard SymbolFinder.sourceExtensions.contains(ext), SymbolFinder.family(ext) == family else { continue }
            } else {
                guard textExtensions.contains(ext) else { continue }
            }
            guard ((attributes?[.size] as? NSNumber)?.intValue ?? 0) < maxBytes else { continue }
            files.append((relative, rootURL.appendingPathComponent(relative), ext))
        }
        files.sort { $0.relative < $1.relative }

        var result = UsageResult()
        var declarations: [String: [NSRegularExpression]] = [:]
        for (relative, url, ext) in files {
            if Task.isCancelled { return UsageResult() }
            result.scannedFiles += 1
            guard let text = overrides[relative] ?? (try? String(contentsOf: url, encoding: .utf8)) else { continue }
            let ns = text as NSString
            guard ns.range(of: query.text).location != NSNotFound else { continue }
            let found = usages(in: text, path: relative, ext: ext, query: query, word: word, declarations: &declarations)
            for u in found {
                if result.usages.count >= maxResults { result.truncated = true; return result }
                result.usages.append(u)
            }
        }
        return result
    }

    /// Usages inside one file's text.
    static func usages(in text: String, path: String, ext: String, query: UsageQuery, word: NSRegularExpression,
                       declarations: inout [String: [NSRegularExpression]]) -> [Usage] {
        let ns = text as NSString
        let matches = word.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }
        let decl: [NSRegularExpression]
        if let cached = declarations[ext] { decl = cached } else {
            let escaped = NSRegularExpression.escapedPattern(for: query.text)
            decl = SymbolFinder.patterns(for: ext).compactMap {
                try? NSRegularExpression(pattern: $0.replacingOccurrences(of: "S", with: escaped), options: [])
            }
            declarations[ext] = decl
        }
        var lines: [String]?
        var out: [Usage] = []
        var lineNumber = 1
        var scanned = 0
        var seen = Set<Int>()
        for m in matches {
            // Count line breaks between the previous match and this one.
            var i = scanned
            while i < m.range.location { if ns.character(at: i) == 10 { lineNumber += 1 }; i += 1 }
            scanned = m.range.location
            let lineRange = ns.lineRange(for: NSRange(location: m.range.location, length: 0))
            var lineText = ns.substring(with: lineRange)
            while lineText.hasSuffix("\n") || lineText.hasSuffix("\r") { lineText.removeLast() }
            let offsetInLine = m.range.location - lineRange.location
            let kind = classify(line: lineText, matchOffset: offsetInLine, ext: ext, declarations: decl)
            if query.importsOnly && kind != .importLine { continue }
            // One entry per match position; the same line twice shows both.
            guard seen.insert(m.range.location).inserted else { continue }
            // Trim the indentation for display and keep the highlight aligned.
            let lead = lineText.prefix { $0 == " " || $0 == "\t" }.utf16.count
            var preview = String(lineText.dropFirst(lead))
            var column = offsetInLine - lead
            if (preview as NSString).length > 220 {
                // Long (minified) lines: a window around the match.
                let start = max(0, column - 80)
                let end = min((preview as NSString).length, column + m.range.length + 120)
                preview = (start > 0 ? "…" : "") + (preview as NSString).substring(with: NSRange(location: start, length: end - start)) + (end < (lineText as NSString).length - lead ? "…" : "")
                column = column - start + (start > 0 ? 1 : 0)
            }
            var container: String?
            if kind == .code || kind == .definition {
                if lines == nil { lines = text.components(separatedBy: "\n") }
                container = ScopeFinder.container(lines: lines!, index: lineNumber - 1, ext: ext)
                if container == query.text { container = nil }
            }
            out.append(Usage(path: path, line: lineNumber, column: max(0, column), length: m.range.length,
                             preview: preview, kind: kind, container: container))
        }
        return out
    }

    private static let hashCommentExtensions: Set<String> = ["py", "rb", "sh", "yml", "yaml", "toml", "properties", "ini", "cfg",
                                                             "conf", "tf", "ex", "exs", "gradle"]
    private static let slashCommentExtensions: Set<String> = ["java", "kt", "kts", "scala", "groovy", "go", "swift", "ts", "tsx",
                                                              "js", "jsx", "mjs", "rs", "cs", "c", "h", "cpp", "hpp", "m", "dart",
                                                              "php", "gradle", "scss", "less", "css", "proto", "vue", "svelte"]
    private static let importPattern = try! NSRegularExpression(pattern:
        #"^(?:import\b|from\s+\S+\s+import\b|using\b|use\s|require\b|#\s*(?:include|import)\b|@import\b|extern\s+crate\b|export\s+(?:\*|\{[^}]*\})\s+from\b|(?:const|let|var)\s+[\w${},\s:]+=\s*(?:await\s+)?require\()"#)
    private static let quotedImportLine = try! NSRegularExpression(pattern: #"^(?:[\w.]+\s+)?"[^"]+"\s*$"#)

    static func classify(line: String, matchOffset: Int, ext: String, declarations: [NSRegularExpression]) -> Usage.Kind {
        let ns = line as NSString
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let full = NSRange(location: 0, length: ns.length)
        if isComment(trimmed: trimmed, before: ns.substring(to: min(matchOffset, ns.length)), ext: ext) { return .comment }
        if importPattern.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil
            || (ext == "go" && quotedImportLine.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil) {
            return .importLine
        }
        for r in declarations where r.firstMatch(in: line, range: full) != nil { return .definition }
        return .code
    }

    static func isComment(trimmed: String, before: String, ext: String) -> Bool {
        let slash = slashCommentExtensions.contains(ext)
        if slash, trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("* ") || trimmed == "*" || trimmed.hasPrefix("*/") { return true }
        if hashCommentExtensions.contains(ext), trimmed.hasPrefix("#") { return true }
        if ext == "sql" || ext == "lua", trimmed.hasPrefix("--") { return true }
        if ["html", "htm", "xml", "vue", "md", "svelte"].contains(ext), trimmed.hasPrefix("<!--") { return true }
        if ext == "py", trimmed.hasPrefix("\"\"\"") || trimmed.hasPrefix("'''") { return true }
        // A trailing comment before the match (outside of a string).
        if slash, let r = before.range(of: "//"), !before[..<r.lowerBound].hasSuffix(":"),
           before[..<r.lowerBound].filter({ $0 == "\"" }).count % 2 == 0, before[..<r.lowerBound].filter({ $0 == "'" }).count % 2 == 0 {
            return true
        }
        if hashCommentExtensions.contains(ext), let r = before.range(of: " #"),
           before[..<r.lowerBound].filter({ $0 == "\"" }).count % 2 == 0, before[..<r.lowerBound].filter({ $0 == "'" }).count % 2 == 0 {
            return true
        }
        return false
    }
}

/// "Who" uses something: the classes and functions around a line, found from indentation and
/// declaration patterns (no parser, no language server).
enum ScopeFinder {
    private static let control: Set<String> = ["if", "for", "while", "switch", "catch", "synchronized", "return", "else", "try",
                                               "foreach", "using", "lock", "when", "with", "elif", "match", "guard", "do",
                                               "defer", "throw", "new", "await", "assert", "function", "fn", "func", "super", "this"]

    private static let classLike = try! NSRegularExpression(pattern:
        #"\b(?:class|interface|enum|record|struct|protocol|extension|object|trait|actor|namespace|module|mod|type)\s+([A-Za-z_$][\w$]*)"#)
    private static let rustImpl = try! NSRegularExpression(pattern: #"^\s*impl(?:<[^>]*>)?\s+(?:[\w:<>,\s&']+?\s+for\s+)?([A-Za-z_]\w*)"#)
    private static let goMethod = try! NSRegularExpression(pattern: #"^\s*func\s+\(\s*\w*\s*\*?\s*(\w+)[^)]*\)\s*(\w+)"#)
    private static let funcKeyword = try! NSRegularExpression(pattern:
        #"(?:\bfunc|\bfn|\bfunction\*?|\bdef|\bfun\s+(?:<[^>]*>\s*)?(?:[\w.]+\.)?)\s+(?:self\.)?([A-Za-z_$][\w$]*[?!]?)"#)
    private static let funcKotlin = try! NSRegularExpression(pattern: #"\bfun\s+(?:<[^>]*>\s*)?(?:[\w.]+\.)?([A-Za-z_]\w*)\s*\("#)
    private static let arrow = try! NSRegularExpression(pattern:
        #"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*(?::[^=]+)?=>"#)
    private static let method = try! NSRegularExpression(pattern:
        #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|protected|static|final|abstract|synchronized|override|async|virtual|internal|default|native|suspend|open|export|get|set)\s+)*(?:<[^>]+>\s+)?(?:[\w$.<>\[\],?*&]+\s+)*?([A-Za-z_$][\w$]*)\s*\([^;]*\)\s*(?:throws\s+[\w.,\s]+)?(?::\s*[^{;=]+)?\s*\{\s*$"#)

    static func indent(_ line: String) -> Int {
        var n = 0
        for c in line { if c == " " { n += 1 } else if c == "\t" { n += 4 } else { break } }
        return n
    }

    /// The declaration a single line introduces ("Server.Handle", "createUser", "UserController"), if any.
    static func declaration(_ line: String, ext: String) -> String? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        func group(_ r: NSRegularExpression, _ i: Int = 1) -> String? {
            guard let m = r.firstMatch(in: line, range: full), m.range(at: i).location != NSNotFound else { return nil }
            return ns.substring(with: m.range(at: i))
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("#") && ext != "rs" && ext != "c" { return nil }
        if ext == "go", let m = goMethod.firstMatch(in: line, range: full) {
            return ns.substring(with: m.range(at: 1)) + "." + ns.substring(with: m.range(at: 2))
        }
        if ext == "rs", let t = group(rustImpl) { return t }
        if let name = group(classLike), !control.contains(name) { return name }
        if ext == "kt" || ext == "kts", let name = group(funcKotlin) { return name }
        if let name = group(funcKeyword), !control.contains(name) { return name }
        if ["js", "jsx", "ts", "tsx", "mjs"].contains(ext), let name = group(arrow) { return name }
        let bracey: Set<String> = ["java", "kt", "kts", "scala", "groovy", "cs", "js", "jsx", "ts", "tsx", "mjs", "swift", "php", "c", "h", "cpp", "hpp", "m", "dart", "go", "rs"]
        if bracey.contains(ext), let name = group(method), !control.contains(name) { return name }
        return nil
    }

    /// Enclosing declarations of line `index` (0-based), outermost first, at most three.
    static func container(lines: [String], index: Int, ext: String) -> String? {
        guard index >= 0, index < lines.count else { return nil }
        var names: [String] = []
        var threshold = indent(lines[index])
        // A usage inside a signature belongs to that function.
        if let own = declaration(lines[index], ext: ext) {
            names.append(own)
            threshold = indent(lines[index])
        }
        var j = index - 1
        var steps = 0
        while j >= 0, names.count < 3, threshold > 0, steps < 4000 {
            steps += 1
            let line = lines[j]
            j -= 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let level = indent(line)
            guard level < threshold else { continue }
            threshold = level
            if let name = declaration(line, ext: ext) { names.append(name) }
        }
        // The first declaration may sit on the line itself at indentation 0 (top-level function).
        return names.isEmpty ? nil : names.reversed().joined(separator: ".")
    }
}
