import SwiftUI
import WebKit

/// Serves `hearth-monaco://editor/…` from memory and the bundled Monaco folder (see MonacoResources).
final class MonacoURLSchemeHandler: NSObject, WKURLSchemeHandler {
    let resources: MonacoResources
    init(resources: MonacoResources) { self.resources = resources }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == MonacoResources.scheme, url.host == "editor",
              url.query == nil, url.fragment == nil, let (data, mime) = resources.resource(forPath: url.path) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let charset = mime.hasPrefix("font/") ? "" : "; charset=utf-8"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime + charset, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*",
        ]) ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// The code editor of the Preview pane: Monaco (the editor of VS Code) in a web view that is
/// served from the app bundle and has no network. One web view per pane; every open file is a
/// Monaco model there, so undo history, cursor and scroll position survive tab switches.
/// Swift stays the owner of the files: edits arrive through `onTextChange`, saving is Swift's.
struct MonacoEditor: NSViewRepresentable {
    let text: String
    /// Identifies the document (its path); also the model key inside the web view.
    let stateKey: String
    let languageID: String
    var fontSize: CGFloat = 12
    var highlightLine: Int?
    /// Marks every occurrence (case-insensitive) and selects the one on `highlightLine`.
    var searchTerm: String?
    /// Unstaged changes shown inline (change bar + tinted lines).
    var hunks: [DiffHunk] = []
    var selectedHunk: String?
    /// Paths of the open tabs: models of closed files are released.
    var openKeys: [String] = []
    var takesFocusFromPreviousEditor = false
    /// False while a viewer (image, rendered Markdown) covers the editor: it is hidden and gives up the keyboard.
    var isVisible = true
    var onTextChange: (String, String) -> Void = { _, _ in }
    var onSave: (String) -> Void = { _ in }
    /// ⌘-click / F12 on a name: (symbol, qualifier before a ".", if any).
    var onCommandClick: (String, String?) -> Void = { _, _ in }
    /// Right-click ▸ Find Usages / ⌥F7: (symbol, qualifier).
    var onFindUsages: (String, String?) -> Void = { _, _ in }
    var onHunkClick: (String) -> Void = { _ in }
    var onHunkStep: (Int) -> Void = { _ in }
    var onNavigate: (Int) -> Void = { _ in }
    var onFocus: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let c = context.coordinator
        let dark = context.environment.colorScheme == .dark
        let theme = MonacoTheme.definition(palette: context.environment.themePalette, systemDark: dark)
        let background = (theme["colors"] as? [String: String])?["editor.background"] ?? (dark ? "#1E1E1E" : "#FFFFFF")
        let labels = [
            "findUsages": String(localized: "Find Usages"),
            "goToDefinition": String(localized: "Go to Definition"),
        ]
        let page = MonacoPage.html(locale: AppLanguage.active.rawValue, labels: labels, background: background)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.setURLSchemeHandler(MonacoURLSchemeHandler(resources: MonacoResources(page: page)), forURLScheme: MonacoResources.scheme)
        config.userContentController.add(c, name: "hearth")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = c
        view.allowsMagnification = false
        view.setValue(false, forKey: "drawsBackground")
        c.webView = view
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "hearth-monaco-offline-v1",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]"#) { [weak view, weak c] rules, error in
                guard let view, let c else { return }
                if let rules { config.userContentController.add(rules) }
                else { NSLog("Monaco: offline protection not loaded: \(error?.localizedDescription ?? "unknown")") }
                view.load(URLRequest(url: MonacoResources.pageURL))
            }
        if takesFocusFromPreviousEditor {
            // Same rule as for the native editor: take focus only when nothing live has it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
                guard let view, let window = view.window else { return }
                let current = window.firstResponder
                let orphaned = (current as? NSView).map { $0.window == nil } ?? true
                if current == nil || current === window || orphaned { window.makeFirstResponder(view); c.wantsFocus = true; c.sync() }
            }
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.environment = context.environment
        if view.isHidden == isVisible {
            view.isHidden = !isVisible
            if !isVisible, let window = view.window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) {
                window.makeFirstResponder(nil)
            }
        }
        context.coordinator.sync()
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "hearth")
        view.navigationDelegate = nil
        coordinator.ready = false
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MonacoEditor
        var environment: EnvironmentValues?
        weak var webView: WKWebView?
        var ready = false
        var wantsFocus = false

        // What the web view already has, so only differences are sent.
        private struct ThemeKey: Equatable { var palette: ThemePalette?; var dark: Bool }
        private var themeKey: ThemeKey?
        private var sentFont: CGFloat?
        private var shownKey: String?
        private var shownLanguage: String?
        private var knownText: [String: String] = [:]
        private var hunkToken: String?
        private var revealToken: String?
        private var retained: [String] = []

        init(_ parent: MonacoEditor) { self.parent = parent }

        func sync() {
            guard ready, let view = webView else { return }
            let p = parent
            var state: [String: Any] = [:]

            let key = ThemeKey(palette: environment?.themePalette, dark: environment?.colorScheme == .dark)
            if key != themeKey {
                themeKey = key
                state["theme"] = MonacoTheme.definition(palette: key.palette, systemDark: key.dark)
            }
            if sentFont != p.fontSize {
                sentFont = p.fontSize
                state["fontSize"] = Double(p.fontSize)
            }
            let keyChanged = shownKey != p.stateKey
            let textChanged = knownText[p.stateKey] != p.text
            if keyChanged || textChanged || shownLanguage != p.languageID {
                let sendText = keyChanged || textChanged
                state["doc"] = ["key": p.stateKey, "text": sendText ? p.text as Any : NSNull(), "language": p.languageID] as [String: Any]
                knownText[p.stateKey] = p.text
                shownKey = p.stateKey
                shownLanguage = p.languageID
            }
            let hunks = "\(p.stateKey)|\(p.hunks.map(\.id).joined(separator: ";"))|\(p.selectedHunk ?? "")"
            if hunks != hunkToken {
                hunkToken = hunks
                state["hunks"] = ["key": p.stateKey, "selected": p.selectedHunk ?? NSNull(),
                                  "list": p.hunks.map { h -> [String: Any] in
                                      ["id": h.id, "kind": "\(h.kind)", "start": h.newStart, "count": h.newCount, "anchor": h.anchorLine]
                                  }] as [String: Any]
            }
            let open = p.openKeys
            if open != retained {
                retained = open
                state["retain"] = open
                knownText = knownText.filter { open.contains($0.key) || $0.key == p.stateKey }
            }
            let reveal = "\(p.stateKey)|\(p.highlightLine ?? -1)|\(p.searchTerm ?? "")"
            if reveal != revealToken {
                revealToken = reveal
                state["reveal"] = ["line": p.highlightLine ?? NSNull(), "term": p.searchTerm ?? NSNull()] as [String: Any]
            }
            if wantsFocus { wantsFocus = false; state["focus"] = true }
            guard !state.isEmpty else { return }
            view.callAsyncJavaScript("window.hearth.apply(state)", arguments: ["state": state], in: nil, in: .page) { result in
                if case .failure(let error) = result { NSLog("Monaco: \(error.localizedDescription)") }
            }
        }

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["t"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                sync()
            case "change":
                guard let key = body["key"] as? String, let text = body["text"] as? String else { return }
                knownText[key] = text
                parent.onTextChange(key, text)
            case "save":
                if let key = body["key"] as? String { parent.onSave(key) }
            case "define":
                if let symbol = body["symbol"] as? String { parent.onCommandClick(symbol, body["qualifier"] as? String) }
            case "usages":
                if let symbol = body["symbol"] as? String { parent.onFindUsages(symbol, body["qualifier"] as? String) }
            case "hunk-click":
                if let id = body["id"] as? String { parent.onHunkClick(id) }
            case "hunk":
                if let dir = body["dir"] as? Int { parent.onHunkStep(dir) }
            case "nav":
                if let dir = body["dir"] as? Int { parent.onNavigate(dir) }
            case "focus":
                parent.onFocus()
            case "error":
                NSLog("Monaco: \(body["message"] as? String ?? "error")")
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only the fixed page, once: no links, dropped files, popups or other navigation.
            let allowed = navigationAction.request.url == MonacoResources.pageURL && navigationAction.targetFrame?.isMainFrame == true
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // Start over: Swift still owns every text, so nothing is lost but the undo history.
            ready = false
            themeKey = nil; sentFont = nil; shownKey = nil; shownLanguage = nil
            knownText = [:]; hunkToken = nil; revealToken = nil; retained = []
            webView.load(URLRequest(url: MonacoResources.pageURL))
        }
    }
}
