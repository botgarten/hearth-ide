import AppKit
import Foundation

/// Where the bundled Monaco (the editor of VS Code) lives. In the app bundle under
/// Resources/monaco; during `swift run`/tests in the repo's Vendor/monaco (scripts/fetch-monaco.sh).
enum MonacoAsset {
    static let hostFileName = "monaco-host.js"
    static let pinnedVersion = "0.52.2"

    /// Folder that contains `vs/`, or nil when Monaco was not fetched (the app then uses the native editor).
    static let root: URL? = {
        let fm = FileManager.default
        func valid(_ dir: URL) -> URL? { fm.fileExists(atPath: dir.appendingPathComponent("vs/loader.js").path) ? dir : nil }
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("monaco"), let ok = valid(dir) { return ok }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            dir.deleteLastPathComponent()
            if let ok = valid(dir.appendingPathComponent("Vendor/monaco/\(pinnedVersion)")) { return ok }
        }
        return nil
    }()

    static let hostScript: URL? = {
        let fm = FileManager.default
        if let u = Bundle.main.resourceURL?.appendingPathComponent(hostFileName), fm.fileExists(atPath: u.path) { return u }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("Resources/\(hostFileName)")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }()

    static var isAvailable: Bool { root != nil && hostScript != nil }
}

/// What the closed `hearth-monaco://editor` origin serves (like the Mermaid one): the generated page,
/// the host script and files below Monaco's `vs/` folder – nothing else, no directory grant, no network.
struct MonacoResources: Sendable {
    static let scheme = "hearth-monaco"
    static let pageURL = URL(string: "\(scheme)://editor/index.html")!
    static let allowedExtensions: [String: String] = [
        "js": "application/javascript", "css": "text/css", "ttf": "font/ttf",
    ]

    let page: String
    let root: URL?
    let hostScript: URL?

    init(page: String, root: URL? = MonacoAsset.root, hostScript: URL? = MonacoAsset.hostScript) {
        self.page = page
        self.root = root
        self.hostScript = hostScript
    }

    /// The bytes and media type served for a request path, or nil (not found / not allowed).
    func resource(forPath path: String) -> (data: Data, mime: String)? {
        if path == "/index.html" { return (Data(page.utf8), "text/html") }
        if path == "/" + MonacoAsset.hostFileName, let hostScript, let data = try? Data(contentsOf: hostScript) {
            return (data, "application/javascript")
        }
        guard let root, path.hasPrefix("/vs/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\\") || $0.contains("\0") }),
              let mime = Self.allowedExtensions[(path as NSString).pathExtension.lowercased()] else { return nil }
        let file = root.appendingPathComponent(String(path.dropFirst()))
        // The resolved file must stay inside the Monaco folder (no symlink out of it).
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base),
              let data = try? Data(contentsOf: file) else { return nil }
        return (data, mime)
    }
}

enum MonacoLanguage {
    /// Monaco's language id for a file.
    static func id(for url: URL, syntax: SyntaxLanguage) -> String {
        switch url.pathExtension.lowercased() {
        case "php": return "php"
        case "lua": return "lua"
        case "ps1", "psm1": return "powershell"
        case "scala", "sc": return "scala"
        case "scss": return "scss"
        case "less": return "less"
        case "toml": return "ini"
        case "gradle", "groovy": return "java"
        default: break
        }
        switch syntax {
        case .swift: return "swift"
        case .go: return "go"
        case .java: return "java"
        case .kotlin: return "kotlin"
        case .javascript: return "javascript"
        case .typescript: return "typescript"
        case .python: return "python"
        case .ruby: return "ruby"
        case .rust: return "rust"
        case .c: return "cpp"
        case .csharp: return "csharp"
        case .shell: return "shell"
        case .json: return "json"
        case .yaml: return "yaml"
        case .toml, .properties: return "ini"
        case .xml: return "xml"
        case .html: return "html"
        case .css: return "css"
        case .markdown: return "markdown"
        case .sql: return "sql"
        case .dockerfile: return "dockerfile"
        case .makefile, .plain: return "plaintext"
        }
    }
}

/// Monaco theme definitions from Hearth's palettes (nil palette: the system's light/dark look).
enum MonacoTheme {
    static func hex(_ color: NSColor, alpha: Double? = nil, dark: Bool = false) -> String {
        var rgb = color
        // Dynamic system colours resolve against an appearance.
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            rgb = color.usingColorSpace(.sRGB) ?? color
        }
        let c = rgb.usingColorSpace(.sRGB) ?? rgb
        func byte(_ v: CGFloat) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        var s = String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
        let a = alpha ?? Double(c.alphaComponent)
        if a < 0.999 { s += String(format: "%02X", byte(CGFloat(a))) }
        return s
    }

    static func isDark(_ color: NSColor) -> Bool {
        let c = color.usingColorSpace(.sRGB) ?? color
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent < 0.5
    }

    static func definition(palette: ThemePalette?, systemDark: Bool) -> [String: Any] {
        guard let p = palette else {
            let bg = NSColor.textBackgroundColor, fg = NSColor.textColor
            return ["base": systemDark ? "vs-dark" : "vs", "inherit": true, "rules": [[String: String]](),
                    "colors": ["editor.background": hex(bg, dark: systemDark),
                               "editor.foreground": hex(fg, dark: systemDark),
                               "editorGutter.background": hex(bg, dark: systemDark),
                               "editor.selectionBackground": hex(.selectedTextBackgroundColor, dark: systemDark)]]
        }
        let dark = isDark(p.editorBackground)
        func rule(_ tokens: [String], _ color: NSColor, style: String? = nil) -> [[String: String]] {
            tokens.map { var r = ["token": $0, "foreground": String(hex(color).dropFirst())]; if let style { r["fontStyle"] = style }; return r }
        }
        let rules: [[String: String]] =
            rule(["keyword", "keyword.flow", "storage"], p.keyword)
            + rule(["type", "type.identifier", "support.type"], p.type)
            + rule(["string", "string.escape", "string.value", "string.html", "string.sql", "attribute.value", "regexp"], p.string)
            + rule(["number", "number.float", "number.hex", "number.octal", "number.binary", "constant"], p.number)
            + rule(["comment", "comment.doc"], p.comment, style: "italic")
            + rule(["annotation", "metatag"], p.attribute)
            + rule(["predefined", "function"], p.function)
            + rule(["string.key.json", "attribute.name", "variable.predefined"], p.key)
            + rule(["tag", "metatag.html", "metatag.xml"], p.tag)
            + [["token": "identifier", "foreground": String(hex(p.editorForeground).dropFirst())],
               ["token": "delimiter", "foreground": String(hex(p.editorForeground).dropFirst())]]
        let fg = p.editorForeground
        let colors: [String: String] = [
            "editor.background": hex(p.editorBackground),
            "editor.foreground": hex(fg),
            "editorLineNumber.foreground": hex(p.gutterText),
            "editorLineNumber.activeForeground": hex(fg),
            "editorGutter.background": hex(p.gutter),
            "editor.selectionBackground": hex(p.selection),
            "editor.inactiveSelectionBackground": hex(p.selection, alpha: 0.6),
            "editor.selectionHighlightBackground": hex(p.selection, alpha: 0.5),
            "editor.wordHighlightBackground": hex(p.accent, alpha: 0.18),
            "editor.wordHighlightStrongBackground": hex(p.accent, alpha: 0.3),
            "editorCursor.foreground": hex(p.caret),
            "editor.lineHighlightBackground": hex(fg, alpha: 0.06),
            "editor.lineHighlightBorder": "#00000000",
            "editorIndentGuide.background1": hex(fg, alpha: 0.1),
            "editorIndentGuide.activeBackground1": hex(fg, alpha: 0.25),
            "editorBracketMatch.background": hex(p.accent, alpha: 0.25),
            "editorBracketMatch.border": "#00000000",
            "editor.findMatchBackground": "#FF9F0080",
            "editor.findMatchHighlightBackground": "#FF9F0050",
            "editorWidget.background": hex(p.pane),
            "editorWidget.border": hex(fg, alpha: 0.2),
            "editorSuggestWidget.background": hex(p.pane),
            "editorSuggestWidget.border": hex(fg, alpha: 0.2),
            "editorSuggestWidget.selectedBackground": hex(p.accent, alpha: 0.3),
            "editorHoverWidget.background": hex(p.pane),
            "editorHoverWidget.border": hex(fg, alpha: 0.2),
            "editorStickyScroll.background": hex(p.editorBackground),
            "editorStickyScrollHover.background": hex(fg, alpha: 0.08),
            "input.background": hex(p.editorBackground),
            "input.foreground": hex(fg),
            "input.border": hex(fg, alpha: 0.25),
            "list.hoverBackground": hex(fg, alpha: 0.08),
            "list.activeSelectionBackground": hex(p.accent, alpha: 0.35),
            "list.activeSelectionForeground": hex(fg),
            "list.focusBackground": hex(p.accent, alpha: 0.35),
            "menu.background": hex(p.pane),
            "menu.foreground": hex(fg),
            "menu.selectionBackground": hex(p.accent, alpha: 0.45),
            "menu.selectionForeground": hex(fg),
            "menu.separatorBackground": hex(fg, alpha: 0.2),
            "scrollbarSlider.background": hex(fg, alpha: 0.2),
            "scrollbarSlider.hoverBackground": hex(fg, alpha: 0.3),
            "scrollbarSlider.activeBackground": hex(fg, alpha: 0.4),
            "focusBorder": hex(p.accent, alpha: 0.6),
        ]
        return ["base": dark ? "vs-dark" : "vs", "inherit": true, "rules": rules, "colors": colors]
    }
}

/// The generated host page. All repository text crosses the script bridge; none is ever put into HTML.
enum MonacoPage {
    static func html(locale: String, labels: [String: String], background: String) -> String {
        let nonce = UUID().uuidString
        let config: [String: Any] = ["locale": locale, "labels": labels]
        let json = (try? JSONSerialization.data(withJSONObject: config)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // Never let text inside the JSON end the script element.
        let safeJSON = json.replacingOccurrences(of: "<", with: "\\u003c")
        let origin = "\(MonacoResources.scheme)://editor"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)' \(origin); style-src 'unsafe-inline' \(origin); img-src data: blob:; font-src \(origin) data:; worker-src blob: \(origin); child-src blob:; connect-src \(origin) blob: data:; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <link rel="stylesheet" href="vs/editor/editor.main.css">
        <style>
          :root { --hh-bg: \(background); }
          html,body,#editor{margin:0;height:100%;width:100%;overflow:hidden;background:var(--hh-bg)}
          .hh-line-added{background:rgba(63,185,80,.13)} .hh-line-modified{background:rgba(56,139,253,.14)}
          .hh-line-deleted{background:rgba(248,81,73,.12)}
          .hh-selected.hh-line-added,.hh-selected.hh-line-modified{filter:brightness(1.25)}
          .hh-bar{margin-left:3px;width:4px!important;cursor:pointer}
          .hh-bar-added{background:#3fb950} .hh-bar-modified{background:#388bfd}
          .hh-bar-deleted{background:linear-gradient(#f85149,#f85149) bottom/100% 3px no-repeat}
          .hh-bar.hh-selected{box-shadow:0 0 0 1px currentColor inset}
          .hh-find{background:rgba(255,160,0,.35);border-radius:2px}
          .hh-flash{background:rgba(255,200,0,.28);animation:hh-fade 1.6s ease-out forwards}
          @keyframes hh-fade{from{background:rgba(255,200,0,.45)}to{background:rgba(255,200,0,0)}}
          .hh-link{text-decoration:underline;cursor:pointer;color:#4a9cf6!important}
          .hh-cmd .view-lines{cursor:pointer}
        </style>
        <script nonce="\(nonce)">window.__hearth = \(safeJSON);</script>
        <script src="vs/loader.js"></script></head>
        <body><div id="editor"></div><script src="\(MonacoAsset.hostFileName)"></script></body></html>
        """
    }
}
