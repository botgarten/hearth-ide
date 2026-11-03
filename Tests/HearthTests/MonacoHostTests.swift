import Foundation
import AppKit
import WebKit
import SwiftUI
import Testing
@testable import Hearth

/// Boots the real bundled Monaco in a WKWebView, the way the editor pane does.
@MainActor
final class MonacoProbe: NSObject, WKScriptMessageHandler {
    let view: WKWebView
    let window: NSWindow
    var messages: [[String: Any]] = []
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    var isReady = false

    init(theme: ThemePalette? = nil) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let page = MonacoPage.html(locale: "en", labels: ["findUsages": "Find Usages", "goToDefinition": "Go to Definition"], background: "#2B2B2B")
        config.setURLSchemeHandler(MonacoURLSchemeHandler(resources: MonacoResources(page: page)), forURLScheme: MonacoResources.scheme)
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 500), configuration: config)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        super.init()
        config.userContentController.add(self, name: "hearth")
        view.load(URLRequest(url: MonacoResources.pageURL))
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        messages.append(body)
        if body["t"] as? String == "ready" {
            isReady = true
            readyWaiters.forEach { $0.resume() }
            readyWaiters = []
        }
    }

    func waitUntilReady(seconds: Double = 20) async throws {
        if isReady { return }
        let deadline = Date().addingTimeInterval(seconds)
        while !isReady && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        try require(isReady, "Monaco did not become ready: \(messages)")
    }

    func apply(_ state: [String: Any]) async throws {
        _ = try await view.callAsyncJavaScript("window.hearth.apply(state)", arguments: ["state": state], in: nil, contentWorld: .page)
    }

    func eval(_ js: String) async throws -> Any? {
        try await view.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
    }
}

/// One shared Monaco for the JS-level tests (booting one per test made the whole suite slow enough to
/// starve the timing of the other view tests). Every test uses its own file keys.
@Suite(.serialized)
struct MonacoHostTests {
    @MainActor private static var sharedProbe: MonacoProbe?

    @MainActor static func probe() async throws -> MonacoProbe {
        try require(MonacoAsset.isAvailable, "run scripts/fetch-monaco.sh")
        _ = NSApplication.shared
        if let p = sharedProbe { return p }
        let probe = MonacoProbe()
        try await probe.waitUntilReady()
        try await probe.apply(["theme": MonacoTheme.definition(palette: .darcula, systemDark: true), "fontSize": 13])
        sharedProbe = probe
        return probe
    }

    /// JS prelude: `m` is the model of a file.
    static func model(_ key: String) -> String { "const m = window.monaco.editor.getModels().find(x => x.uri.path === '\(key)');" }

    /// Messages of one type received since `mark` (`probe.messages.count` at the start of the test).
    @MainActor static func messages(_ probe: MonacoProbe, _ type: String, since mark: Int = 0) -> [[String: Any]] {
        probe.messages.dropFirst(mark).filter { $0["t"] as? String == type }
    }

    @Test @MainActor func bootsWithoutErrors() async throws {
        let turn = await ViewTestGate.turn()
        defer { turn.end() }
        let probe = try await Self.probe()
        let mark = probe.messages.count
        try await probe.apply(["doc": ["key": "/t1/Main.java", "text": "public class Main {\n    void run() { helper(); }\n}\n", "language": "java"]])
        let value = try await probe.eval(Self.model("/t1/Main.java") + "return m.getLanguageId() + ':' + m.getLineCount()")
        #expect(value as? String == "java:4")
        #expect(Self.messages(probe, "error", since: mark).isEmpty, "\(probe.messages)")
        #expect(Self.messages(probe, "error").isEmpty, "\(probe.messages)")
    }

    @Test @MainActor func javaScriptServiceAnswersThroughAWorker() async throws {
        let turn = await ViewTestGate.turn()
        defer { turn.end() }
        let probe = try await Self.probe()
        try await probe.apply(["doc": ["key": "/t2/app.js", "text": "const items = [1, 2, 3];\nitems.ma", "language": "javascript"]])
        // Completions come from the TypeScript worker: items.ma → map.
        let js = Self.model("/t2/app.js") + """
        const worker = await window.monaco.languages.typescript.getJavaScriptWorker();
        const svc = await worker(m.uri);
        const r = await svc.getCompletionsAtPosition(m.uri.toString(), m.getValueLength());
        return r ? r.entries.map(e => e.name).filter(n => n === 'map').length : -1;
        """
        #expect(try await probe.eval(js) as? Int == 1)
        // Single-file semantics only: an unresolved import must not produce errors.
        try await probe.apply(["doc": ["key": "/t2/b.ts", "text": "import { Missing } from './nowhere';\nconst x: Missing = 1;\n", "language": "typescript"]])
        try await Task.sleep(nanoseconds: 600_000_000)
        let markers = try await probe.eval("return window.monaco.editor.getModelMarkers({resource: window.monaco.Uri.file('/t2/b.ts')}).length") as? Int
        #expect(markers == 0)
    }

    @Test @MainActor func everyBundledLanguageHasATokenizer() async throws {
        let turn = await ViewTestGate.turn()
        defer { turn.end() }
        let probe = try await Self.probe()
        let ids = ["go", "java", "javascript", "typescript", "python", "rust", "kotlin", "swift", "csharp", "cpp", "shell", "yaml",
                   "xml", "html", "css", "markdown", "sql", "dockerfile", "ini", "ruby", "json"]
        for id in ids {
            try await probe.apply(["doc": ["key": "/t3/file.\(id)", "text": "x", "language": id]])
        }
        let list = ids.map { "'\($0)'" }.joined(separator: ",")
        let js = "const known = new Set(window.monaco.languages.getLanguages().map(l => l.id)); return [\(list)].filter(id => !known.has(id)).join(',')"
        let missing = try await probe.eval(js) as? String
        #expect(missing == "", "no tokenizer for: \(missing ?? "?")")
    }

    @Test @MainActor func editsAreReportedAndSwiftEditsKeepUndo() async throws {
        let turn = await ViewTestGate.turn()
        defer { turn.end() }
        let probe = try await Self.probe()
        let mark = probe.messages.count
        try await probe.apply(["doc": ["key": "/t4/a.go", "text": "package a\n", "language": "go"]])
        _ = try await probe.eval(Self.model("/t4/a.go") + "m.applyEdits([{range: m.getFullModelRange(), text: 'package b\\n'}])")
        try await Task.sleep(nanoseconds: 400_000_000)
        let changes = Self.messages(probe, "change", since: mark)
        #expect(changes.last?["text"] as? String == "package b\n")
        #expect(changes.last?["key"] as? String == "/t4/a.go")
        // A text pushed from Swift (e.g. "Discard") is not echoed back as an edit, and undo restores the edit.
        try await probe.apply(["doc": ["key": "/t4/a.go", "text": "package a\n", "language": "go"]])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(Self.messages(probe, "change", since: mark).count == changes.count)
        _ = try await probe.eval("window.monaco.editor.getEditors()[0].trigger('test', 'undo', null)")
        #expect(try await probe.eval(Self.model("/t4/a.go") + "return m.getValue()") as? String == "package b\n")
    }

    @Test @MainActor func flushReturnsTheLatestText() async throws {
        let turn = await ViewTestGate.turn()
        defer { turn.end() }
        let probe = try await Self.probe()
        let mark = probe.messages.count
        try await probe.apply(["doc": ["key": "/t5/a.py", "text": "x = 1\n", "language": "python"]])
        _ = try await probe.eval(Self.model("/t5/a.py") + "m.applyEdits([{range: m.getFullModelRange(), text: 'x = 2\\n'}])")
        let flushed = try await probe.eval("return window.hearth.flush()") as? [String: Any]
        #expect(flushed?["text"] as? String == "x = 2\n")
        #expect(Self.messages(probe, "change", since: mark).last?["text"] as? String == "x = 2\n")
    }

    @Test @MainActor func contextMenuActionsPostTheNameUnderTheCursor() async throws {
        let turn = await ViewTestGate.turn()
        defer { turn.end() }
        let probe = try await Self.probe()
        let mark = probe.messages.count
        try await probe.apply(["doc": ["key": "/t6/svc.go", "text": "package main\n\nfunc run() {\n\tserver.Handle(req)\n}\n", "language": "go"]])
        _ = try await probe.eval("window.monaco.editor.getEditors()[0].setPosition({lineNumber: 4, column: 12})")
        _ = try await probe.eval("await window.monaco.editor.getEditors()[0].getAction('hearth.findUsages').run()")
        _ = try await probe.eval("await window.monaco.editor.getEditors()[0].getAction('hearth.goToDefinition').run()")
        let usage = try need(Self.messages(probe, "usages", since: mark).last)
        #expect(usage["symbol"] as? String == "Handle")
        #expect(usage["qualifier"] as? String == "server")
        #expect(Self.messages(probe, "define", since: mark).last?["symbol"] as? String == "Handle")
    }

    @Test @MainActor func commandClickOnANameAsksForItsDefinition() async throws {
        let turn = await ViewTestGate.turn()
        defer { turn.end() }
        let probe = try await Self.probe()
        let mark = probe.messages.count
        try await probe.apply(["doc": ["key": "/t9/svc.go", "text": "package main\n\nfunc run() {\n\tserver.Handle(req)\n}\n", "language": "go"]])
        // The web view is off screen in tests, so its animation frames are paused: lay out and paint by hand.
        _ = try await probe.eval("""
        const ed = window.monaco.editor.getEditors()[0];
        ed.layout(); ed.render(true);
        const pos = ed.getScrolledVisiblePosition({lineNumber: 4, column: 12});
        const box = document.getElementById('editor').getBoundingClientRect();
        const x = box.left + pos.left + 2, y = box.top + pos.top + pos.height / 2;
        const down = (meta) => document.elementFromPoint(x, y).dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true, metaKey: meta, button: 0, clientX: x, clientY: y}));
        down(false);   // a plain click only places the cursor
        down(true);
        return [x, y];
        """)
        let defined = Self.messages(probe, "define", since: mark)
        #expect(defined.count == 1)
        #expect(defined.first?["symbol"] as? String == "Handle")
        #expect(defined.first?["qualifier"] as? String == "server")
        #expect(defined.first?["line"] as? Int == 4)
    }

    @Test @MainActor func closedFilesReleaseTheirModels() async throws {
        let turn = await ViewTestGate.turn()
        defer { turn.end() }
        let probe = try await Self.probe()
        for name in ["a", "b", "c"] { try await probe.apply(["doc": ["key": "/t7/\(name).go", "text": name, "language": "go"]]) }
        try await probe.apply(["retain": ["/t7/a.go"]])
        // Everything not retained goes, except the shown file (c).
        let uris = try await probe.eval("return window.monaco.editor.getModels().map(m => m.uri.path).sort().join(',')") as? String
        #expect(uris == "/t7/a.go,/t7/c.go")
    }

    @Test @MainActor func hunksPaintBarsAndLines() async throws {
        let turn = await ViewTestGate.turn()
        defer { turn.end() }
        let probe = try await Self.probe()
        try await probe.apply(["doc": ["key": "/t8/a.go", "text": "1\n2\n3\n4\n", "language": "go"],
                               "hunks": ["key": "/t8/a.go", "selected": "h2",
                                         "list": [["id": "h1", "kind": "added", "start": 1, "count": 2, "anchor": 1],
                                                  ["id": "h2", "kind": "deleted", "start": 3, "count": 0, "anchor": 3]]]])
        let classes = try await probe.eval(Self.model("/t8/a.go") + """
        return m.getAllDecorations().map(d => (d.options.className || '') + ' ' + (d.options.linesDecorationsClassName || '')).sort().join('|')
        """) as? String
        #expect(classes?.contains("hh-line-added") == true)
        #expect(classes?.contains("hh-bar-deleted") == true)
    }

    @Test func serverOnlyServesTheEditorsOwnFiles() throws {
        try require(MonacoAsset.isAvailable, "run scripts/fetch-monaco.sh")
        let r = MonacoResources(page: "<html>")
        #expect(r.resource(forPath: "/index.html")?.mime == "text/html")
        #expect(r.resource(forPath: "/vs/loader.js")?.mime == "application/javascript")
        #expect(r.resource(forPath: "/vs/editor/editor.main.css")?.mime == "text/css")
        #expect(r.resource(forPath: "/monaco-host.js") != nil)
        for bad in ["/vs/../../Package.swift", "/vs/%2e%2e/x.js", "/vs/editor/../../loader.js", "/etc/passwd", "/vs/", "/vs/loader.js/../../x.js",
                    "/vs/nope.js", "/vs/editor/editor.main.js.map", "/vs//loader.js", "/Package.swift", "/vs/base/worker/..\\x.js"] {
            #expect(r.resource(forPath: bad) == nil, "\(bad) must not be served")
        }
    }

    @Test func languageIdsFollowTheFileType() {
        func id(_ name: String) -> String { MonacoLanguage.id(for: URL(fileURLWithPath: "/p/\(name)"), syntax: SyntaxLanguage.detect(URL(fileURLWithPath: "/p/\(name)"))) }
        #expect(id("Main.java") == "java")
        #expect(id("main.go") == "go")
        #expect(id("lib.rs") == "rust")
        #expect(id("app.py") == "python")
        #expect(id("app.js") == "javascript")
        #expect(id("app.tsx") == "typescript")
        #expect(id("style.scss") == "scss")
        #expect(id("Cargo.toml") == "ini")
        #expect(id("notes.unknown") == "plaintext")
    }

    @Test func themeBecomesMonacoColors() throws {
        let theme = MonacoTheme.definition(palette: .darcula, systemDark: false)
        #expect(theme["base"] as? String == "vs-dark")
        let colors = try need(theme["colors"] as? [String: String])
        #expect(colors["editor.background"] == "#2B2B2B")
        #expect(colors["editorCursor.foreground"] == "#BBBBBB")
        let rules = try need(theme["rules"] as? [[String: String]])
        #expect(rules.contains { $0["token"] == "keyword" && $0["foreground"] == "CC7832" })
        #expect(MonacoTheme.definition(palette: .hearthLight, systemDark: true)["base"] as? String == "vs")
        #expect(MonacoTheme.definition(palette: nil, systemDark: true)["base"] as? String == "vs-dark")
    }

    // MARK: The SwiftUI wrapper

    @MainActor static func webView(in view: NSView) -> WKWebView? {
        if let w = view as? WKWebView { return w }
        for sub in view.subviews { if let w = webView(in: sub) { return w } }
        return nil
    }

    @MainActor final class Recorder {
        var changes: [(String, String)] = []
        var usages: [String] = []
        var defined: [String] = []
        var saved = 0
        var navigated: [Int] = []
    }

    @MainActor static func editor(_ r: Recorder, text: String, key: String = "/p/Main.java", line: Int? = nil, term: String? = nil,
                                  open: [String]? = nil, visible: Bool = true) -> MonacoEditor {
        MonacoEditor(text: text, stateKey: key, languageID: "java", highlightLine: line, searchTerm: term, openKeys: open ?? [key], isVisible: visible,
                     onTextChange: { r.changes.append(($0, $1)) },
                     onSave: { _ in r.saved += 1 },
                     onCommandClick: { s, _ in r.defined.append(s) },
                     onFindUsages: { s, _ in r.usages.append(s) },
                     onNavigate: { r.navigated.append($0) })
    }

    @Test @MainActor func wrapperShowsDocumentsAndReportsEditsAndShortcuts() async throws {
        let turn = await ViewTestGate.turn()
        defer { turn.end() }
        try require(MonacoAsset.isAvailable, "run scripts/fetch-monaco.sh")
        _ = NSApplication.shared
        let r = Recorder()
        let host = NSHostingView(rootView: Self.editor(r, text: "class Main {\n  void a() {}\n  void b() {}\n}\n"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        var found: WKWebView?
        for _ in 0..<50 where found == nil {
            host.layoutSubtreeIfNeeded()
            found = Self.webView(in: host)
            if found == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        let web = try need(found, "no web view in the hosted editor")
        func eval(_ js: String) async throws -> Any? { try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) }
        func eventually(_ what: String, _ check: () async throws -> Bool) async throws {
            for _ in 0..<100 { if try await check() { return }; try await Task.sleep(nanoseconds: 100_000_000) }
            throw TestFailure(description: "timed out: \(what)")
        }
        try await eventually("document shown") { (try? await eval("return window.monaco.editor.getModels().length") as? Int) == 1 }

        // The editor reports the user's edits with the document's key.
        _ = try await eval("const m = window.monaco.editor.getModels()[0]; m.applyEdits([{range: new window.monaco.Range(2,1,2,1), text: '  int x;\\n'}])")
        try await eventually("edit reported") { r.changes.last?.1.contains("int x;") == true }
        #expect(r.changes.last?.0 == "/p/Main.java")

        // Swift pushes a changed text (reload, discard) and a line to reveal; unchanged input sends nothing new.
        host.rootView = Self.editor(r, text: "class Main {}\n", line: 1, term: "Main")
        try await eventually("text pushed") { (try? await eval("return window.monaco.editor.getModels()[0].getValue()") as? String) == "class Main {}\n" }
        try await eventually("term marked") { (try? await eval("return window.monaco.editor.getModels()[0].getAllDecorations().filter(d => d.options.inlineClassName === 'hh-find').length") as? Int) == 1 }

        // A second file becomes a second model; closing it (retain) releases it again.
        host.rootView = Self.editor(r, text: "x", key: "/p/Other.java", open: ["/p/Main.java", "/p/Other.java"])
        try await eventually("second model") { (try? await eval("return window.monaco.editor.getModels().length") as? Int) == 2 }
        host.rootView = MonacoEditor(text: "class Main {}\n", stateKey: "/p/Main.java", languageID: "java", openKeys: ["/p/Main.java"])
        try await eventually("model released") { (try? await eval("return window.monaco.editor.getModels().length") as? Int) == 1 }

        // Keyboard: real key events through the window, like a user's keystrokes.
        host.rootView = Self.editor(r, text: "class Main {}\n")
        window.makeFirstResponder(web)
        _ = try await eval("const ed = window.monaco.editor.getEditors()[0]; ed.focus(); ed.setPosition({lineNumber: 1, column: 8});")
        func key(_ chars: String, code: UInt16, _ flags: NSEvent.ModifierFlags) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                window.sendEvent(e)
            }
        }
        key("s", code: 1, .command)
        try await eventually("⌘S saves") { r.saved == 1 }
        key("[", code: 33, .command)
        try await eventually("⌘[ navigates back") { r.navigated == [-1] }
        _ = try await eval("await window.monaco.editor.getEditors()[0].getAction('hearth.findUsages').run()")
        try await eventually("usages posted") { r.usages == ["Main"] }
        // A hidden editor keeps its state but is not shown.
        host.rootView = Self.editor(r, text: "class Main {}\n", visible: false)
        try await eventually("hidden") { web.isHidden }
        host.rootView = Self.editor(r, text: "class Main {}\n")
        try await eventually("shown again") { !web.isHidden }
    }
}
