import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Hearth

@MainActor
struct ContextSwitchTests {
    private func json(_ data: Any) throws -> JSON { JSON.parse(try JSONSerialization.data(withJSONObject: data))! }

    @Test func staleLoadsCannotPublishAfterSwitchBack() throws {
        let a = "run:a", b = "run:b"
        var requests = LatestRequest<String>()
        let oldA = requests.begin(a)
        let loadB = requests.begin(b)
        try require(!requests.accepts(oldA, current: b) && requests.accepts(loadB, current: b), "A overwrites B")
        requests.invalidate()
        let newA = requests.begin(a)
        try require(!requests.accepts(oldA, current: a) && !requests.accepts(loadB, current: a), "A-B-A accepts obsolete response")
        try require(requests.accepts(newA, current: a), "Latest A response rejected")
        requests.invalidate()
        try require(!requests.accepts(newA, current: a), "Disposed view can still publish")

        let file = URL(fileURLWithPath: "/work/a/source.swift")
        let editorA = EditorLoadKey(presentation: EditorPresentation(root: "/work/a", file: file), mode: "Datei", revision: 1)
        let editorB = EditorLoadKey(presentation: EditorPresentation(root: "/work/b", file: file), mode: "Datei", revision: 1)
        var editorRequests = LatestRequest<EditorLoadKey>()
        let oldDiff = editorRequests.begin(editorA)
        _ = editorRequests.begin(editorB)
        try require(!editorRequests.accepts(oldDiff, current: editorB), "Diff from another workspace accepted")
        try require(EditorPresentation.relativePath(file, root: "/work/a") == "source.swift", "Valid relative path")
        try require(EditorPresentation.relativePath(URL(fileURLWithPath: "/work/ab/file"), root: "/work/a") == nil, "Prefix collision assigned wrong repository")
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    @Test func nativeEditorSwitchResetsViewNotBuffers() async throws {
        let turn = await ViewTestGate.turn()
        defer { turn.end() }
        _ = NSApplication.shared
        final class Buffer { var text: String; init(_ text: String) { self.text = text } }
        let a = Buffer(String(repeating: "let number = 42\n", count: 100))
        let b = Buffer("")
        var focusedDocument: String?
        func editor(_ id: String, _ buffer: Buffer) -> AnyView {
            AnyView(CodeEditor(text: Binding(get: { buffer.text }, set: { buffer.text = $0 }), language: .swift, editable: true,
                               onFocus: { focusedDocument = id })
                .id(EditorPresentation(root: "/work", file: URL(fileURLWithPath: "/work/\(id).swift"))))
        }
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: editor("a", a))
        window.contentView = host; window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        guard let first = find(CodeTextView.self, in: host) else { throw SandboxGitRunner.Failure("No native editor") }
        window.makeFirstResponder(first)
        try require(focusedDocument == "a", "Native editor focus not delivered")
        first.replace(NSRange(location: (first.string as NSString).length, length: 0), with: "unsaved A")
        try await Task.sleep(for: .milliseconds(50))
        let savedA = a.text
        try require(savedA.hasSuffix("unsaved A"), "Editor binding lost edit")
        first.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 500))
        b.text = savedA // Identical contents/language but a DIFFERENT document.
        host.rootView = editor("b", b)
        try await Task.sleep(for: .milliseconds(150))
        guard let second = find(CodeTextView.self, in: host) else { throw SandboxGitRunner.Failure("No switched editor") }
        try require(first !== second && first.undoManager !== second.undoManager, "Document reuses native editor/undo state")
        try require(second.enclosingScrollView?.contentView.bounds.minY == 0, "Old scroll offset carried into new document")
        window.makeFirstResponder(second)
        try require(focusedDocument == "b", "Focus remained with previous editor")
        second.replace(NSRange(location: 0, length: 0), with: "B edit\n")
        try await Task.sleep(for: .milliseconds(50))
        try require(second.undoManager?.canUndo == true, "Private undo manager not functional")
        second.undoManager?.undo()
        try require(second.string == savedA && a.text == savedA, "Undo affected the other document")
        host.rootView = editor("a", a)
        try await Task.sleep(for: .milliseconds(100))
        try require(find(CodeTextView.self, in: host)?.string == savedA, "Returning to A lost unsaved buffer")
    }

    @Test func nativeMarkdownRemeasuresOnTextAndWidthChanges() async throws {
        let turn = await ViewTestGate.turn()
        defer { turn.end() }
        _ = NSApplication.shared
        func content(_ text: String) -> AnyView {
            AnyView(VStack(alignment: .leading) {
                SelectableMarkdown(text: text, scale: 1).id("same-message")
                Spacer(minLength: 0)
            }.padding(8))
        }
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 600, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let text = String(repeating: "A long paragraph with **bold** and `code` that wraps across the available width.\n\n", count: 30)
        let host = NSHostingView(rootView: content(text))
        window.contentView = host; window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        guard let first = find(MarkdownTextView.self, in: host) else { throw SandboxGitRunner.Failure("No native Markdown") }
        let wide = first.intrinsicContentSize.height
        window.setContentSize(NSSize(width: 300, height: 700))
        try await Task.sleep(for: .milliseconds(150))
        try require(first.intrinsicContentSize.height >= wide, "Narrow pane kept stale Markdown height")
        try require(abs((first.textContainer?.containerSize.width ?? 0) - first.bounds.width) < 1, "TextKit width detached from actual frame")
        let oldHeight = first.frame.height
        host.rootView = content("## Short\n\nOnly a small paragraph.")
        try await Task.sleep(for: .milliseconds(150))
        guard let short = find(MarkdownTextView.self, in: host) else { throw SandboxGitRunner.Failure("Markdown disappeared") }
        try require(short === first && short.string.contains("Only a small paragraph"), "Native content not updated")
        try require(short.frame.height > 0 && short.frame.height < oldHeight, "SwiftUI retained old native text height")
    }
}

@MainActor
struct EditorPerformanceTests {
    /// Measures a real tab switch: new native editor, text, highlighting, layout and drawing.
    func measureTabSwitch(hunks: [DiffHunk] = []) async throws -> [String: Double] {
        _ = NSApplication.shared
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repo = ProcessInfo.processInfo.environment["HEARTH_REPO"].map { URL(fileURLWithPath: $0) } ?? base
        let files = ["Sources/Hearth/Core/AppModel.swift", "docs/api/opencode-v2.2.0-openapi.json", "Sources/Hearth/UI/CodeEditor.swift"]
            .map { repo.appendingPathComponent($0) }
        let texts = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        func editor(_ i: Int) -> AnyView {
            AnyView(CodeEditor(text: .constant(texts[i]), language: SyntaxLanguage.detect(files[i]), editable: true, hunks: hunks)
                .id(EditorPresentation(root: repo.path, file: files[i])))
        }
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: editor(0))
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(200))
        var results: [String: Double] = [:]
        for round in 0..<3 {
            for i in [1, 0, 2] {
                let start = Date()
                host.rootView = editor(i)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let ms = Date().timeIntervalSince(start) * 1000
                if round > 0 { results[files[i].lastPathComponent] = max(results[files[i].lastPathComponent] ?? 0, ms) }
            }
        }
        return results
    }
}

extension EditorPerformanceTests {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    func tabSwitchKeepsStateAndOverlays() async throws {
        _ = NSApplication.shared
        let a = (1...400).map { "let value\($0) = \"text\" // line \($0)" }.joined(separator: "\n")
        let b = (1...300).map { "func f\($0)() {}" }.joined(separator: "\n")
        let big = "{\n" + (1...9000).map { "  \"key\($0)\": \"value \($0)\"," }.joined(separator: "\n") + "\n  \"end\": true\n}"
        var hunks: [DiffHunk] = []
        func editor(_ id: String, _ text: String, _ lang: SyntaxLanguage) -> AnyView {
            AnyView(CodeEditor(text: .constant(text), language: lang, editable: true, hunks: hunks, stateKey: "/work/" + id,
                               takesFocusFromPreviousEditor: true)
                .id(id))
        }
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: editor("a", a, .swift))
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        guard let first = find(CodeTextView.self, in: host), let clip = first.enclosingScrollView?.contentView else {
            throw SandboxGitRunner.Failure("No editor")
        }
        // Scroll + caret in A, switch to B, back to A: both restored.
        first.setSelectedRange(NSRange(location: 1234, length: 5))
        clip.scroll(to: NSPoint(x: 0, y: 2400))
        first.enclosingScrollView?.reflectScrolledClipView(clip)
        window.makeFirstResponder(first)
        host.rootView = editor("b", b, .swift)
        try await Task.sleep(for: .milliseconds(100))
        try require(window.firstResponder is CodeTextView && window.firstResponder !== first, "Keyboard focus not handed to the new tab's editor")
        host.rootView = editor("a", a, .swift)
        host.layoutSubtreeIfNeeded()
        if let early = find(CodeTextView.self, in: host)?.enclosingScrollView?.contentView {
            try require(abs(early.bounds.origin.y - 2400) < 2, "First frame shows the wrong position (visible jump): \(early.bounds.origin.y)")
        }
        try await Task.sleep(for: .milliseconds(150))
        guard let again = find(CodeTextView.self, in: host), let clip2 = again.enclosingScrollView?.contentView else {
            throw SandboxGitRunner.Failure("Editor missing after switch")
        }
        try require(again !== first, "Expected a fresh native editor per document")
        try require(again.selectedRange() == NSRange(location: 1234, length: 5), "Selection not restored: \(again.selectedRange())")
        try require(abs(clip2.bounds.origin.y - 2400) < 2, "Scroll position not restored: \(clip2.bounds.origin.y)")

        // Line ranges: first, middle, last line without trailing newline.
        let ns = a as NSString
        let c = try { () throws -> CodeEditor.Coordinator in
            guard let c = again.delegate as? CodeEditor.Coordinator else { throw SandboxGitRunner.Failure("No coordinator") }
            return c
        }()
        try require(c.rangeOf(line: 1).map { ns.substring(with: $0) } == "let value1 = \"text\" // line 1\n", "Line 1 range")
        try require(c.rangeOf(line: 200).map { ns.substring(with: $0) }?.hasPrefix("let value200 ") == true, "Line 200 range")
        try require(c.rangeOf(line: 400).map { ns.substring(with: $0) } == "let value400 = \"text\" // line 400", "Last line range")
        try require(c.rangeOf(line: 401) == nil, "Out-of-range line")

        // Hunks change: tint applied, syntax colours untouched (no re-tokenize flicker).
        let keyword = again.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        hunks = [DiffHunk(oldStart: 3, oldCount: 2, newStart: 3, newCount: 2, oldLines: ["x", "y"], newLines: ["a", "b"], patchBody: "")]
        host.rootView = editor("a", a, .swift)
        try await Task.sleep(for: .milliseconds(80))
        let line3 = c.rangeOf(line: 3)!.location
        try require(again.textStorage!.attribute(.backgroundColor, at: line3, effectiveRange: nil) != nil, "Hunk tint missing")
        try require(again.textStorage!.attribute(.backgroundColor, at: c.rangeOf(line: 10)!.location, effectiveRange: nil) == nil, "Tint on wrong line")
        try require((again.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == keyword && keyword != NSColor.labelColor,
                    "Syntax colours lost when hunks changed")
        hunks = []

        // Tab order: reorder, move to end, drop onto itself, insert from another editor.
        let u = ["a", "b", "c", "d"].map { URL(fileURLWithPath: "/w/\($0)") }
        try require(TabOrdering.place(u[3], in: u, before: u[1]) == [u[0], u[3], u[1], u[2]], "Reorder left")
        try require(TabOrdering.place(u[0], in: u, before: u[3]) == [u[1], u[2], u[0], u[3]], "Reorder right")
        try require(TabOrdering.place(u[1], in: u, before: nil) == [u[0], u[2], u[3], u[1]], "Move to end")
        try require(TabOrdering.place(u[2], in: u, before: u[2]) == u, "Drop onto itself")
        let foreign = URL(fileURLWithPath: "/w/x")
        try require(TabOrdering.place(foreign, in: u, before: u[0]) == [foreign] + u, "Insert from other editor")
        try require(TabOrdering.place(foreign, in: u, before: URL(fileURLWithPath: "/w/missing")) == u + [foreign], "Unknown target appends")

        // Large documents: text immediately, colours asynchronously.
        let start = Date()
        host.rootView = editor("big", big, .json)
        host.layoutSubtreeIfNeeded()
        let switchMs = Date().timeIntervalSince(start) * 1000
        guard let large = find(CodeTextView.self, in: host) else { throw SandboxGitRunner.Failure("No large editor") }
        try require(large.string == big, "Large text not shown immediately")
        var coloured = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            let colour = large.textStorage!.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
            if colour != nil, colour != NSColor.labelColor { coloured = true; break }
        }
        try require(coloured, "Large document never highlighted")
        try require(switchMs < 1000, "Large document switch blocked for \(Int(switchMs)) ms")
    }
}
