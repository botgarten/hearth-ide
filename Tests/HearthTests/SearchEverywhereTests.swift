import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Hearth

/// Search Everywhere: matching, the sources, ranking and the double-Shift shortcut.
struct SearchEverywhereTests {
    @Test func matchingLikeIntelliJ() throws {
        // Substring, word initials (camel case, snake case), several terms.
        #expect(SearchEverywhere.score("MainLayoutView.java", "mlv") != nil)
        #expect(SearchEverywhere.score("app_model.py", "apmo") != nil)
        #expect(SearchEverywhere.score("ReferencesView.java", "refview") != nil)
        #expect(SearchEverywhere.score("AboutView.java", "view about") != nil)
        #expect(SearchEverywhere.score("README.md", "xyz") == nil)
        // A prefix ranks above a later substring, an exact name above everything.
        let prefix = try #require(SearchEverywhere.score("OfferView.java", "offer"))
        let inner = try #require(SearchEverywhere.score("MyOfferView.java", "offer"))
        #expect(prefix > inner)
        #expect(try #require(SearchEverywhere.score("pom.xml", "pom.xml")) > prefix)
    }

    @Test func scopesCycleWithTab() {
        #expect(SearchScope.all.next() == .files)
        #expect(SearchScope.actions.next() == .all)
        #expect(SearchScope.all.next(backwards: true) == .actions)
    }

    static func project() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-search-\(UUID().uuidString)")
        let files: [String: String] = [
            "src/main/java/app/MainLayout.java": "package app;\n\npublic class MainLayout {\n    void render() { /* TODO header */ }\n}\n",
            "src/main/java/app/OfferView.java": "class OfferView {\n  String title = \"Angebot\";\n}\n",
            "README.md": "# Demo\nThe header explains things.\n",
            "node_modules/lib/index.js": "function header() {}\n",
            "target/classes/x.txt": "header\n",
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root.path
    }

    @Test func filesTextAndSymbols() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let index = SearchEverywhere.indexFiles(root: root)
        #expect(Set(index) == ["src/main/java/app/MainLayout.java", "src/main/java/app/OfferView.java", "README.md"],
                "Dependency/build folders must be skipped")

        let context = SearchContext(root: root, recentFiles: ["README.md"])
        let files = SearchEverywhere.files("ml", in: index, context: context)
        #expect(files.first?.title == "MainLayout.java" && files.first?.subtitle == "src/main/java/app")
        #expect(SearchEverywhere.files("", in: index, context: context).map(\.title) == ["README.md"], "Empty query: recent files")

        let text = SearchEverywhere.text("HEADER", root: root, index: index)
        #expect(Set(text.map(\.subtitle)) == ["MainLayout.java:4", "README.md:2"])
        #expect(text.contains { $0.target == .file(path: "src/main/java/app/MainLayout.java", line: 4) })
        #expect(SearchEverywhere.text("h", root: root, index: index).isEmpty, "One character searches nothing")

        let symbols = SearchEverywhere.symbols("offer", in: SearchEverywhere.indexSymbols(root: root, index: index))
        #expect(symbols.first?.title == "OfferView" && symbols.first?.target == .file(path: "src/main/java/app/OfferView.java", line: 1))
    }

    @Test func chatSessionsTestsAndActions() {
        let chats = [SearchContext.Chat(runID: "r1", title: "Claude Code – shop", text: "> fix the login\nDone: login fixed\nother")]
        let chat = SearchEverywhere.chat("login", in: chats)
        #expect(chat.count == 2 && chat.allSatisfy { $0.target == .chat(runID: "r1", text: "login") && $0.detail == "Claude Code – shop" })

        let sessions = [SearchContext.Session(id: "a", title: "Claude Code – shop", kind: "Claude Code", directory: "/u/shop", status: "running"),
                        SearchContext.Session(id: "b", title: "Codex – blog", kind: "Codex", directory: "/u/blog", status: "done")]
        #expect(SearchEverywhere.sessions("blog", in: sessions).map(\.id) == ["session:b"])
        #expect(SearchEverywhere.sessions("", in: sessions).count == 2)

        let tests = [TestCase(id: "t1", suite: "S", className: "app.CartTest", name: "addsItem", time: 0, outcome: .passed, message: nil, details: nil),
                     TestCase(id: "t2", suite: "S", className: "app.CartTest", name: "removesItem", time: 0, outcome: .failed, message: "x", details: nil)]
        #expect(SearchEverywhere.tests("", in: tests).map(\.title) == ["removesItem"], "Empty query: failures only")
        #expect(SearchEverywhere.tests("cart", in: tests).count == 2)

        let actions = [SearchContext.Action(id: "theme.darcula", title: "Theme: Darcula", keywords: "appearance", symbol: "paintpalette"),
                       SearchContext.Action(id: "zoom.in", title: "Larger text", keywords: "zoom font", symbol: "plus")]
        #expect(SearchEverywhere.actions("darc", in: actions).map(\.id) == ["action:theme.darcula"])
        #expect(SearchEverywhere.actions("font", in: actions).map(\.id) == ["action:zoom.in"], "Keywords match too")

        let all = SearchEverywhere.combine([.files: [], .sessions: SearchEverywhere.sessions("", in: sessions),
                                            .actions: SearchEverywhere.actions("", in: actions)])
        #expect(all.first?.scope == .actions && all.last?.scope == .sessions)
    }

    @Test func doubleShift() {
        var d = DoubleShiftDetector()
        func tap(_ t: Double) -> Bool {
            _ = d.flagsChanged(shift: true, otherModifiers: false, at: t)
            return d.flagsChanged(shift: false, otherModifiers: false, at: t + 0.05)
        }
        var fired: [Bool] = []
        fired.append(tap(1.0))
        fired.append(tap(1.2))                       // second tap within 0.4 s
        fired.append(tap(3.0)); fired.append(tap(3.6))   // too slow
        fired.append(tap(5.0)); d.keyDown(); fired.append(tap(5.2))   // a capital letter in between
        _ = d.flagsChanged(shift: true, otherModifiers: false, at: 7.0)
        fired.append(d.flagsChanged(shift: false, otherModifiers: false, at: 7.6)); fired.append(tap(7.7))   // held, not tapped
        fired.append(tap(9.0)); _ = d.flagsChanged(shift: true, otherModifiers: true, at: 9.1); fired.append(tap(9.2))   // ⌘⇧
        #expect(fired == [false, true, false, false, false, false, false, false, false, false])
    }

    /// The editor marks every occurrence and selects the one on the hit's line, also when the
    /// document's text only arrives after the editor was created (files load asynchronously).
    @MainActor
    @Test func editorMarksAndSelectsTheHit() async throws {
        _ = NSApplication.shared
        final class Buffer { var text = "" }
        let buffer = Buffer()
        let content = (1...200).map { $0 == 150 ? "let header = Header() // header" : "let line\($0) = \($0)" }.joined(separator: "\n")
        func editor() -> some View {
            CodeEditor(text: Binding(get: { buffer.text }, set: { buffer.text = $0 }), language: .swift, editable: true,
                       highlightLine: 150, searchTerm: "header")
        }
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: AnyView(editor()))
        window.contentView = host; window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(100))
        buffer.text = content                      // the file's text arrives later
        host.rootView = AnyView(editor())
        var tv: NSTextView?
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            tv = Self.find(NSTextView.self, in: host)
            if let tv, tv.selectedRange().length > 0 { break }
        }
        let view = try #require(tv)
        let ns = view.string as NSString
        let line150 = ns.range(of: "let header = Header() // header")
        let selected = view.selectedRange()
        #expect(ns.substring(with: selected).lowercased() == "header" && NSLocationInRange(selected.location, line150),
                "The occurrence on the hit's line must be selected")
        let marks = [ns.range(of: "header", range: line150), ns.range(of: "Header", range: line150)].filter {
            view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: $0.location, effectiveRange: nil) != nil
        }
        #expect(marks.count == 2, "Every occurrence (any case) is marked")
        #expect((view.enclosingScrollView?.contentView.bounds.minY ?? 0) > 1000, "Scrolled to the hit")
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }

    @MainActor
    @Test func searchHitsMarkTheTermInTheEditor() throws {
        let layout = LayoutStore()
        let editor = EditorStore(layout: layout)
        let url = URL(fileURLWithPath: "/tmp/hearth-search-test.swift")
        editor.open(url, line: 4, highlight: "header")
        #expect(editor.highlight == "header" && editor.line == 4)
        editor.open(url)
        #expect(editor.highlight == nil, "A normal open must not keep an old mark")
    }
}
