import SwiftUI
import AppKit

/// Syntax-highlighted code view based on NSTextView: fast for large files,
/// native selection/search (⌘F), optional editing, line-number gutter.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: SyntaxLanguage
    var editable = false
    var highlightLine: Int?
    /// Marks every occurrence (case-insensitive) and selects the one on `highlightLine`.
    var searchTerm: String?
    var fontSize: CGFloat = 12
    var onSave: (() -> Void)?
    /// ⌘-click on an identifier: (symbol, qualifier before a ".", if any).
    var onCommandClick: ((String, String?) -> Void)?
    /// Unstaged changes shown inline (gutter markers + tinted lines).
    var hunks: [DiffHunk] = []
    var selectedHunk: String?
    var onHunkClick: ((DiffHunk) -> Void)?
    var onGoToLine: (() -> Void)?
    var onFocus: (() -> Void)?
    /// Identifies the document so scroll position and selection survive tab switches.
    var stateKey: String?
    /// Take keyboard focus when the window has no live first responder (e.g. after a tab switch).
    var takesFocusFromPreviousEditor = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 on purpose: the line-number gutter uses NSLayoutManager, and
        // touching it on a TextKit 2 view switches modes mid-flight (text vanished).
        let scroll = NSScrollView()
        scroll.clipsToBounds = true
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let tv = CodeTextView(usingTextLayoutManager: false)
        scroll.documentView = tv
        tv.delegate = context.coordinator
        tv.font = Self.font(fontSize)
        context.coordinator.fontSize = fontSize
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: LineNumberGutter.width(for: fontSize) + 6, height: 6)
        context.coordinator.applyTheme(context.environment.themePalette, to: tv)
        // No line wrapping: code reads better with horizontal scrolling. Without
        // maxSize/autoresizing the text view stays zero-width and draws nothing.
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true

        // Line numbers as an overlay above the clip view. (Drawing them inside
        // NSTextView.draw worked offscreen but not on screen, where AppKit draws
        // text through cached layer tiles.)
        let gutter = LineNumberGutter(textView: tv)
        scroll.addSubview(gutter, positioned: .above, relativeTo: scroll.contentView)
        gutter.refresh()
        context.coordinator.gutter = gutter
        gutter.columnWidth = LineNumberGutter.width(for: fontSize)

        context.coordinator.textView = tv
        tv.onCommandClick = { [weak coordinator = context.coordinator] symbol, qualifier in
            coordinator?.parent.onCommandClick?(symbol, qualifier)
        }
        tv.onGoToLine = { [weak coordinator = context.coordinator] in coordinator?.parent.onGoToLine?() }
        tv.onFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocus?() }
        tv.language = language
        tv.indentUnit = { [weak coordinator = context.coordinator, weak tv] in
            coordinator?.indentUnitFor(tv?.string ?? "") ?? "    "
        }
        context.coordinator.hunks = hunks
        context.coordinator.selectedHunk = selectedHunk
        gutter.hunks = hunks
        gutter.selectedHunk = selectedHunk
        context.coordinator.lastHighlightLine = highlightLine
        context.coordinator.apply(text: text, language: language)
        tv.isEditable = editable
        if let key = stateKey { context.coordinator.restore(key, line: highlightLine) }
        else if let line = highlightLine { context.coordinator.reveal(line: line) }
        context.coordinator.markSearch(searchTerm, line: highlightLine)
        if takesFocusFromPreviousEditor {
            // Tab switch while editing: hand keyboard focus to the new document's editor
            // (the previous editor was removed). Never steal focus from other inputs.
            DispatchQueue.main.async { [weak tv] in
                guard let tv, let window = tv.window else { return }
                let current = window.firstResponder
                let orphaned = (current as? NSView).map { $0.window == nil } ?? true
                if current == nil || current === window || orphaned { window.makeFirstResponder(tv) }
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        tv.isEditable = editable
        (tv as? CodeTextView)?.language = language
        if !tv.string.isLiterallyEqual(to: text) || c.language != language {
            c.apply(text: text, language: language)
            if let pending = c.pendingSearch, pending.term == searchTerm {
                c.pendingSearch = nil
                c.markSearch(pending.term, line: pending.line, force: true)
            }
        }
        if c.hunks != hunks || c.selectedHunk != selectedHunk {
            c.hunks = hunks
            c.selectedHunk = selectedHunk
            c.gutter?.hunks = hunks
            c.gutter?.selectedHunk = selectedHunk
            c.applyOverlays()
        }
        c.gutter?.onHunkClick = onHunkClick
        if c.palette != context.environment.themePalette {
            c.applyTheme(context.environment.themePalette, to: tv)
            c.highlight()
        }
        if c.fontSize != fontSize {
            c.fontSize = fontSize
            tv.font = Self.font(fontSize)
            let gutterWidth = LineNumberGutter.width(for: fontSize)
            c.gutter?.columnWidth = gutterWidth
            tv.textContainerInset = NSSize(width: gutterWidth + 6, height: 6)
            c.highlight()
        }
        if c.lastHighlightLine != highlightLine {
            c.lastHighlightLine = highlightLine
            if let line = highlightLine { c.reveal(line: line) }
            c.markSearch(searchTerm, line: highlightLine, force: true)
        } else if c.searchTerm != searchTerm {
            c.markSearch(searchTerm, line: highlightLine)
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let key = coordinator.parent.stateKey { coordinator.save(key) }
        coordinator.invalidate()
        coordinator.textView?.delegate = nil
        coordinator.textView?.undoManager?.removeAllActions()
        (coordinator.textView as? CodeTextView)?.onFocus = nil
    }

    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func color(_ kind: TokenKind) -> NSColor {
        if let palette = ThemeStore.palette { return palette.syntax(kind) }
        return switch kind {
        case .keyword: .systemPink
        case .type: .systemTeal
        case .string: .systemRed
        case .number: .systemOrange
        case .comment: .secondaryLabelColor
        case .attribute: .systemPurple
        case .function: .systemBlue
        case .key: .systemIndigo
        case .tag: .systemBlue
        case .punctuation: .systemOrange
        case .heading: .systemPink
        }
    }

    /// Text colour without a token.
    static var foreground: NSColor { ThemeStore.palette?.editorForeground ?? .labelColor }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var palette: ThemePalette?
        var searchTerm: String?
        private var searchRanges: [NSRange] = []
        /// A mark requested before the document's text arrived; applied with the text.
        var pendingSearch: (term: String, line: Int?)?

        /// Marks all occurrences of `term`, selects the one on `line` (else the first), scrolls
        /// it into view and flashes it. Runs after layout, so it wins over restored scroll positions.
        func markSearch(_ term: String?, line: Int?, force: Bool = false) {
            guard force || term != searchTerm else { return }
            searchTerm = term
            DispatchQueue.main.async { [weak self] in self?.applySearch(term, line: line) }
        }

        private func applySearch(_ term: String?, line: Int?) {
            guard let tv = textView, let lm = tv.layoutManager else { return }
            let ns = tv.string as NSString
            for r in searchRanges where NSMaxRange(r) <= ns.length {
                lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
            }
            searchRanges = []
            guard let term, !term.isEmpty else { return }
            guard ns.length > 0 else { pendingSearch = (term, line); return }
            var ranges: [NSRange] = []
            var search = NSRange(location: 0, length: ns.length)
            while ranges.count < 5000 {
                let r = ns.range(of: term, options: .caseInsensitive, range: search)
                guard r.location != NSNotFound else { break }
                ranges.append(r)
                let next = NSMaxRange(r)
                search = NSRange(location: next, length: ns.length - next)
            }
            let mark = NSColor.systemOrange.withAlphaComponent(0.35)
            for r in ranges { lm.addTemporaryAttribute(.backgroundColor, value: mark, forCharacterRange: r) }
            searchRanges = ranges
            var lineRange: NSRange?
            if let line, line > 0 {
                var n = 0
                ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, r, _, stop in
                    n += 1
                    if n == line { lineRange = r; stop.pointee = true }
                }
            }
            let target = lineRange.flatMap { l in ranges.first { NSIntersectionRange($0, l).length > 0 } } ?? ranges.first
            if let target {
                tv.setSelectedRange(target)
                tv.scrollRangeToVisible(target)
                tv.showFindIndicator(for: target)
            }
        }

        /// Editor colours of the theme (nil: system colours).
        func applyTheme(_ palette: ThemePalette?, to tv: NSTextView) {
            self.palette = palette
            tv.backgroundColor = palette?.editorBackground ?? .textBackgroundColor
            tv.insertionPointColor = palette?.caret ?? .textColor
            tv.selectedTextAttributes = [.backgroundColor: palette?.selection ?? .selectedTextBackgroundColor]
            gutter?.needsDisplay = true
        }
        weak var textView: NSTextView?
        weak var gutter: LineNumberGutter?
        var language: SyntaxLanguage = .plain
        var fontSize: CGFloat = 12
        var hunks: [DiffHunk] = []
        var selectedHunk: String?
        var lastHighlightLine: Int?
        private var pending: DispatchWorkItem?
        private var revision = UUID()

        init(_ parent: CodeEditor) { self.parent = parent }

        func apply(text: String, language: SyntaxLanguage) {
            guard let tv = textView else { return }
            invalidate()
            self.language = language
            let selected = tv.selectedRanges
            tv.string = text
            // New content: the old undo history refers to text that no longer exists (⌘Z crashed).
            tv.undoManager?.removeAllActions()
            if (selected.first?.rangeValue.upperBound ?? 0) <= (text as NSString).length { tv.selectedRanges = selected }
            highlight()
            tv.needsDisplay = true
        }

        func invalidate() { pending?.cancel(); pending = nil; revision = UUID() }

        /// Syntax colouring. Large documents are tokenized off the main thread so a
        /// tab switch shows text immediately; colours follow when ready.
        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let text = storage.string
            let language = language
            let expected = revision
            let key = parent.stateKey
            if let key, let cached = Self.tokenCache[key], cached.language == language, cached.text.isLiterallyEqual(to: text) {
                applyTokens(cached.tokens, to: storage)
                return
            }
            if (text as NSString).length > Self.asyncThreshold {
                applyTokens([], to: storage)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let tokens = Highlighter.tokens(in: text, language: language)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.revision == expected, let storage = self.textView?.textStorage,
                              storage.string.isLiterallyEqual(to: text) else { return }
                        self.applyTokens(tokens, to: storage)
                        if let key { Self.remember(key, text: text, language: language, tokens: tokens) }
                    }
                }
            } else {
                let tokens = Highlighter.tokens(in: text, language: language)
                applyTokens(tokens, to: storage)
                if let key { Self.remember(key, text: text, language: language, tokens: tokens) }
            }
        }

        /// Tokens of recently shown documents: revisiting an unchanged tab skips the regex pass.
        nonisolated(unsafe) static var tokenCache: [String: (text: String, language: SyntaxLanguage, tokens: [Token])] = [:]
        nonisolated(unsafe) static var tokenOrder: [String] = []
        static func remember(_ key: String, text: String, language: SyntaxLanguage, tokens: [Token]) {
            tokenCache[key] = (text, language, tokens)
            tokenOrder.removeAll { $0 == key }
            tokenOrder.append(key)
            while tokenOrder.count > 24 { tokenCache[tokenOrder.removeFirst()] = nil }
        }

        static let asyncThreshold = 120_000

        private func applyTokens(_ tokens: [Token], to storage: NSTextStorage) {
            let full = NSRange(location: 0, length: storage.length)
            let base = CodeEditor.font(fontSize)
            let italic = base.withItalic
            let bold = CodeEditor.font(fontSize, weight: .bold)
            storage.beginEditing()
            storage.setAttributes([.font: base, .foregroundColor: CodeEditor.foreground], range: full)
            for t in tokens where NSMaxRange(t.range) <= storage.length {
                storage.addAttribute(.foregroundColor, value: CodeEditor.color(t.kind), range: t.range)
                if t.kind == .comment { storage.addAttribute(.font, value: italic, range: t.range) }
                if t.kind == .heading || t.kind == .keyword && language == .markdown {
                    storage.addAttribute(.font, value: bold, range: t.range)
                }
            }
            storage.endEditing()
            applyOverlays()
        }

        /// Diff tint and highlighted line only – no re-tokenizing when hunks arrive.
        func applyOverlays() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let ns = storage.string as NSString
            lineStarts = Self.lineStarts(ns)
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
            for h in hunks {
                guard let lines = h.newRange else { continue }
                let color: NSColor = h.kind == .added ? .systemGreen : .systemBlue
                let alpha: CGFloat = h.id == selectedHunk ? 0.28 : 0.13
                for line in lines {
                    if let r = rangeOf(line: line) {
                        storage.addAttribute(.backgroundColor, value: color.withAlphaComponent(alpha), range: r)
                    }
                }
            }
            if let line = lastHighlightLine, let range = rangeOf(line: line) {
                storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.25), range: range)
            }
            storage.endEditing()
            gutter?.refresh()
        }

        private var lineStarts: [Int] = [0]

        static func lineStarts(_ ns: NSString) -> [Int] {
            var starts = [0]
            starts.reserveCapacity(ns.length / 30 + 1)
            var buffer = [unichar](repeating: 0, count: ns.length)
            ns.getCharacters(&buffer, range: NSRange(location: 0, length: ns.length))
            for (i, c) in buffer.enumerated() where c == 10 { starts.append(i + 1) }
            return starts
        }

        func rangeOf(line: Int) -> NSRange? {
            guard let ns = textView?.string as NSString?, line > 0 else { return nil }
            if lineStarts.count == 1 && ns.length > 0 || (lineStarts.last ?? 0) > ns.length { lineStarts = Self.lineStarts(ns) }
            guard line <= lineStarts.count else { return nil }
            let start = lineStarts[line - 1]
            guard start <= ns.length else { return nil }
            let end = line < lineStarts.count ? lineStarts[line] : ns.length
            return NSRange(location: start, length: end - start)
        }

        // MARK: Per-document view state (scroll + selection)

        nonisolated(unsafe) static var viewStates: [String: (origin: NSPoint, selection: NSRange)] = [:]

        func save(_ key: String) {
            guard let tv = textView, let clip = tv.enclosingScrollView?.contentView else { return }
            Self.viewStates[key] = (clip.bounds.origin, tv.selectedRange())
            if Self.viewStates.count > 200 { Self.viewStates.removeValue(forKey: Self.viewStates.keys.first!) }
        }

        func restore(_ key: String, line: Int?) {
            if let line { reveal(line: line); return }
            guard let state = Self.viewStates[key], let tv = textView else { return }
            let length = (tv.string as NSString).length
            if NSMaxRange(state.selection) <= length { tv.setSelectedRange(state.selection) }
            // Position synchronously before the first frame (no visible jump from the top);
            // the async pass below only corrects clamping once SwiftUI has sized the view.
            if let lm = tv.layoutManager, let container = tv.textContainer, let clip = tv.enclosingScrollView?.contentView {
                lm.ensureLayout(for: container)
                tv.sizeToFit()
                clip.setBoundsOrigin(state.origin)
            }
            let expected = revision
            DispatchQueue.main.async { [weak self, weak tv] in
                guard let self, self.revision == expected, let tv, let scroll = tv.enclosingScrollView,
                      let lm = tv.layoutManager, let container = tv.textContainer else { return }
                lm.ensureLayout(for: container)
                let maxY = max(0, tv.frame.height - scroll.contentView.bounds.height)
                let target = NSPoint(x: state.origin.x, y: min(state.origin.y, maxY))
                if abs(scroll.contentView.bounds.origin.y - target.y) > 1 || abs(scroll.contentView.bounds.origin.x - target.x) > 1 {
                    scroll.contentView.scroll(to: target)
                }
                scroll.reflectScrolledClipView(scroll.contentView)
                self.gutter?.refresh()
            }
        }

        func reveal(line: Int) {
            guard let tv = textView, let range = rangeOf(line: line) else { return }
            applyOverlays()
            tv.setSelectedRange(NSRange(location: range.location, length: 0))
            let expectedRevision = revision
            // Wait for SwiftUI's final layout, then center the line and stay at the left edge.
            DispatchQueue.main.async { [weak self, weak tv] in
                guard let self, self.revision == expectedRevision, let tv,
                      NSMaxRange(range) <= (tv.string as NSString).length,
                      let lm = tv.layoutManager, let container = tv.textContainer,
                      let clip = tv.enclosingScrollView?.contentView else { return }
                lm.ensureLayout(for: container)
                let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let rect = lm.boundingRect(forGlyphRange: glyphs, in: container)
                let y = max(0, rect.midY + tv.textContainerInset.height - clip.bounds.height / 2)
                clip.scroll(to: NSPoint(x: 0, y: min(y, max(0, tv.frame.height - clip.bounds.height))))
                tv.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView, notification.object as? NSTextView === tv else { return }
            invalidate()
            parent.text = tv.string
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.highlight() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            gutter?.refresh()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let tv = textView as? CodeTextView else { return false }
            let unit = indentUnit(textView.string)
            let multiLine = (tv.string as NSString).substring(with: tv.selectedRange()).contains("\n")
            if selector == #selector(NSResponder.insertTab(_:)) {
                if multiLine { tv.shiftLines(right: true, unit: unit) } else { textView.insertText(unit, replacementRange: textView.selectedRange()) }
                return true
            }
            if selector == #selector(NSResponder.insertBacktab(_:)) {
                tv.shiftLines(right: false, unit: unit)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let ns = textView.string as NSString
                let sel = textView.selectedRange()
                let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
                let line = ns.substring(with: NSRange(location: lineRange.location, length: sel.location - lineRange.location))
                let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                let prev: unichar? = sel.location > 0 ? ns.character(at: sel.location - 1) : nil
                let next: unichar? = NSMaxRange(sel) < ns.length ? ns.character(at: NSMaxRange(sel)) : nil
                let opens: [unichar: unichar] = [123: 125, 40: 41, 91: 93]   // { ( [
                if let p = prev, let close = opens[p] {
                    if next == close {
                        // "{|}" + ↩ → block with the caret on an indented middle line.
                        let insert = "\n" + indent + unit + "\n" + indent
                        tv.replace(sel, with: insert, select: NSRange(location: sel.location + 1 + (indent + unit as NSString).length, length: 0))
                    } else {
                        textView.insertText("\n" + indent + unit, replacementRange: sel)
                    }
                    return true
                }
                textView.insertText("\n" + indent, replacementRange: sel)
                return true
            }
            return false
        }

        func indentUnitFor(_ text: String) -> String { indentUnit(text) }

        private func indentUnit(_ text: String) -> String {
            if language == .go || language == .makefile { return "\t" }
            let tabs = text.components(separatedBy: "\n\t").count
            let spaces2 = text.components(separatedBy: "\n  ").count
            let spaces4 = text.components(separatedBy: "\n    ").count
            if tabs > spaces2 { return "\t" }
            return spaces4 * 2 >= spaces2 ? "    " : "  "
        }
    }
}

private extension NSFont {
    var withItalic: NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }
}

/// NSTextView with ⌘-hover underline and ⌘-click "go to definition".
final class CodeTextView: NSTextView {
    private let documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
    var onCommandClick: ((String, String?) -> Void)?
    var language: SyntaxLanguage = .plain
    var autoClosePairs = true
    var indentUnit: () -> String = { "    " }
    var onGoToLine: (() -> Void)?
    /// Subtle background for the caret's line.
    var highlightCurrentLine = true

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard highlightCurrentLine, isEditable, window?.firstResponder === self, selectedRange().length == 0,
              let lm = layoutManager, let container = textContainer else { return }
        let ns = string as NSString
        let loc = min(selectedRange().location, max(ns.length - 1, 0))
        var lineRect: NSRect
        if ns.length == 0 {
            lineRect = NSRect(x: 0, y: textContainerOrigin.y, width: bounds.width, height: font?.boundingRectForFont.height ?? 15)
        } else {
            let g = lm.glyphIndexForCharacter(at: loc)
            lineRect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            if selectedRange().location == ns.length, ns.length > 0, ns.character(at: ns.length - 1) == 10 {
                lineRect = lm.extraLineFragmentRect
            }
            lineRect.origin.y += textContainerOrigin.y
            lineRect.origin.x = 0
            lineRect.size.width = max(bounds.width, container.size.width)
        }
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        lineRect.intersection(rect).fill()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting else { return }
        updateBracketHighlight()
        needsDisplay = true   // move the current-line highlight
    }

    private var bracketRanges: [NSRange] = []
    private func updateBracketHighlight() {
        guard let lm = layoutManager else { return }
        for r in bracketRanges where NSMaxRange(r) <= (string as NSString).length {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
        }
        bracketRanges = []
        if let (a, b) = matchingBracket() {
            for r in [a, b] {
                lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), forCharacterRange: r)
            }
            bracketRanges = [a, b]
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? ""
        if flags == .command {
            switch key {
            case "/": if isEditable { toggleComment() }; return
            case "d": if isEditable { duplicateLines() }; return
            case "l": onGoToLine?(); return
            default: break
            }
        }
        if flags == [.command, .option], key == "f" {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showReplaceInterface.rawValue
            performTextFinderAction(item)
            return
        }
        if flags.contains(.option), !flags.contains(.command), isEditable,
           event.keyCode == 126 || event.keyCode == 125 {   // ↑ / ↓
            moveLines(up: event.keyCode == 126)
            return
        }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if replacementRange.location == NSNotFound, let s = string as? String, isEditable, handlePairs(typed: s) { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        if isEditable, handlePairBackspace() { return }
        super.deleteBackward(sender)
    }
    private var hoverRange: NSRange?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// Identifier under a point plus the identifier before a preceding "." (Go package, Java receiver …).
    func symbol(at point: NSPoint) -> (range: NSRange, name: String, qualifier: String?)? {
        let index = characterIndexForInsertion(at: point)
        let ns = string as NSString
        guard index < ns.length else { return nil }
        let isIdent: (unichar) -> Bool = { c in
            guard let scalar = UnicodeScalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || c == 95 || c == 36   // _ $
        }
        guard isIdent(ns.character(at: index)) else { return nil }
        var start = index, end = index
        while start > 0, isIdent(ns.character(at: start - 1)) { start -= 1 }
        while end < ns.length, isIdent(ns.character(at: end)) { end += 1 }
        let range = NSRange(location: start, length: end - start)
        let name = ns.substring(with: range)
        guard SymbolFinder.isIdentifier(name) else { return nil }
        var qualifier: String?
        if start > 1, ns.character(at: start - 1) == 46 {   // "."
            var qs = start - 1
            while qs > 0, isIdent(ns.character(at: qs - 1)) { qs -= 1 }
            if qs < start - 1 { qualifier = ns.substring(with: NSRange(location: qs, length: start - 1 - qs)) }
        }
        return (range, name, qualifier)
    }

    private func setHover(_ range: NSRange?) {
        guard range != hoverRange, let lm = layoutManager else { return }
        if let old = hoverRange { lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: old) }
        hoverRange = range
        if let range {
            lm.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: range)
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    private func updateHover(_ event: NSEvent) {
        guard onCommandClick != nil, event.modifierFlags.contains(.command) else { setHover(nil); return }
        setHover(symbol(at: convert(event.locationInWindow, from: nil))?.range)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if let window, let current = NSApp.currentEvent {
            let local = NSEvent.mouseEvent(with: .mouseMoved, location: window.mouseLocationOutsideOfEventStream,
                                           modifierFlags: current.modifierFlags, timestamp: current.timestamp,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
            if let local { updateHover(local) }
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHover(nil)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let handler = onCommandClick,
           let hit = symbol(at: convert(event.locationInWindow, from: nil)) {
            setHover(nil)
            handler(hit.name, hit.qualifier)
            return
        }
        super.mouseDown(with: event)
    }
}

/// Line-number column drawn as an overlay exactly as tall as the visible area.
/// (A document-tall view produced layers taller than the GPU texture limit for
/// long files when zoomed, which rendered as garbled/stretched numbers.)
final class LineNumberGutter: NSView {
    static let width: CGFloat = 40
    /// Grows with the font so four-digit line numbers still fit when zoomed.
    var columnWidth: CGFloat = width {
        didSet { refresh() }
    }
    static func width(for fontSize: CGFloat) -> CGFloat { max(width + 4, (fontSize * 3.6).rounded()) }
    private weak var textView: NSTextView?
    private var observers: [NSObjectProtocol] = []
    var hunks: [DiffHunk] = [] { didSet { needsDisplay = true } }
    var selectedHunk: String? { didSet { needsDisplay = true } }
    var onHunkClick: ((DiffHunk) -> Void)?
    static let markerWidth: CGFloat = 4

    /// y-range of a 1-based line in gutter coordinates.
    private func lineRect(_ line: Int) -> NSRect? {
        guard let tv = textView, let lm = tv.layoutManager, let clip = tv.enclosingScrollView?.contentView else { return nil }
        let ns = tv.string as NSString
        guard ns.length > 0 else { return nil }
        var location = 0, current = 1
        while current < line && location < ns.length {
            location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        guard current == line else { return nil }
        let g = lm.glyphIndexForCharacter(at: min(location, ns.length - 1))
        let r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        return NSRect(x: 0, y: r.minY + tv.textContainerOrigin.y - clip.bounds.minY, width: bounds.width, height: r.height)
    }

    /// Marker shape per hunk: bar for added/modified lines, triangle for deletions.
    private func markerRect(_ h: DiffHunk) -> NSRect? {
        let x = bounds.width - Self.markerWidth - 2
        if let range = h.newRange, let first = lineRect(range.lowerBound), let last = lineRect(range.upperBound) {
            return NSRect(x: x, y: first.minY, width: Self.markerWidth, height: last.maxY - first.minY)
        }
        // Deletion after line newStart (newStart 0 = before the first line).
        if h.newStart == 0, let first = lineRect(1) { return NSRect(x: x - 2, y: first.minY - 4, width: 8, height: 8) }
        if let after = lineRect(h.newStart) { return NSRect(x: x - 2, y: after.maxY - 4, width: 8, height: 8) }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Generous hit area: the whole gutter row of a marker.
        if let hit = hunks.first(where: { h in markerRect(h).map { NSRect(x: 0, y: $0.minY - 2, width: bounds.width, height: $0.height + 4).contains(p) } ?? false }) {
            onHunkClick?(hit)
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        for h in hunks { if let r = markerRect(h) { addCursorRect(NSRect(x: 0, y: r.minY, width: bounds.width, height: r.height), cursor: .pointingHand) } }
    }

    override var isFlipped: Bool { true }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        clipsToBounds = true
        // Redraw instead of stretching the old bitmap while resizing.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        textView.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak self] _ in self?.refresh() })
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                    self?.refresh()
                })
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Keeps the overlay aligned with the clip view (left edge, full visible height).
    func refresh() {
        guard let clip = textView?.enclosingScrollView?.contentView else { return }
        let target = NSRect(x: clip.frame.minX, y: clip.frame.minY, width: columnWidth, height: clip.frame.height)
        if frame != target { frame = target }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer,
              let clip = tv.enclosingScrollView?.contentView else { return }
        // Never fill the whole dirtyRect: for views inside a scroll view AppKit can
        // pass a rect larger than the gutter, and since macOS 14 views don't clip to
        // their bounds by default – filling it hid the code and painted over the pane
        // header. Only ever paint our own bounds.
        let column = bounds
        (ThemeStore.palette?.gutter ?? tv.backgroundColor).setFill()
        column.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()

        let ns = tv.string as NSString
        let origin = tv.textContainerOrigin
        let scrollY = clip.bounds.minY
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(9, (tv.font?.pointSize ?? 12) - 2), weight: .regular),
            .foregroundColor: ThemeStore.palette?.gutterText ?? NSColor.tertiaryLabelColor,
        ]
        guard ns.length > 0 else {
            ("1" as NSString).draw(at: NSPoint(x: bounds.maxX - 14, y: origin.y - scrollY), withAttributes: attrs)
            return
        }
        // Visible part of the document in text-container coordinates.
        let containerRect = NSRect(x: 0, y: scrollY + dirtyRect.minY - origin.y, width: container.size.width, height: dirtyRect.height)
        let glyphs = lm.glyphRange(forBoundingRect: containerRect, in: container)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = 1
        ns.enumerateSubstrings(in: NSRange(location: 0, length: chars.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            line += 1
        }
        var index = chars.location
        while index <= min(NSMaxRange(chars), ns.length) {
            let lineRange = ns.lineRange(for: NSRange(location: min(index, ns.length), length: 0))
            let g = lm.glyphIndexForCharacter(at: min(lineRange.location, ns.length - 1))
            let rect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: bounds.maxX - size.width - 10,
                                   y: rect.minY + origin.y - scrollY + (rect.height - size.height) / 2),
                       withAttributes: attrs)
            line += 1
            let next = NSMaxRange(lineRange)
            if next <= index || next >= ns.length { break }
            index = next
        }
        drawDiffMarkers()
    }

    private func drawDiffMarkers() {
        for h in hunks {
            guard let r = markerRect(h), r.maxY >= 0, r.minY <= bounds.height else { continue }
            let selected = h.id == selectedHunk
            switch h.kind {
            case .added, .modified:
                (h.kind == .added ? NSColor.systemGreen : NSColor.systemBlue).withAlphaComponent(selected ? 1 : 0.8).setFill()
                NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
            case .deleted:
                NSColor.systemRed.withAlphaComponent(selected ? 1 : 0.85).setFill()
                let t = NSBezierPath()
                t.move(to: NSPoint(x: r.minX, y: r.minY))
                t.line(to: NSPoint(x: r.maxX, y: r.midY))
                t.line(to: NSPoint(x: r.minX, y: r.maxY))
                t.close()
                t.fill()
            }
        }
        window?.invalidateCursorRects(for: self)
    }
}
