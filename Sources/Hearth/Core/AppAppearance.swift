import AppKit
import SwiftUI
import Observation
import os

/// App-wide theme, independent of the macOS setting. The macOS themes use the system's
/// dynamic colours; the others bring their own palette for panes, editor, syntax and terminal.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    case hearthLight = "hearth-light"
    case darcula, storm
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "Same as system")
        case .light: String(localized: "macOS Light")
        case .dark: String(localized: "macOS Dark")
        case .hearthLight: "Hearth Light"
        case .darcula: "Darcula"
        case .storm: "Storm"
        }
    }

    /// Light or dark base for AppKit/SwiftUI controls; nil follows macOS.
    var isDark: Bool? {
        switch self {
        case .system: nil
        case .light, .hearthLight: false
        case .dark, .darcula, .storm: true
        }
    }

    /// Own colours; nil keeps the system colours.
    var palette: ThemePalette? {
        switch self {
        case .system, .light, .dark: nil
        case .hearthLight: .hearthLight
        case .darcula: .darcula
        case .storm: .storm
        }
    }

    static let defaultsKey = "ui.appearance"

    @MainActor
    static var current: AppAppearance {
        get { ThemeStore.shared.appearance }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            ThemeStore.shared.appearance = newValue
            newValue.apply()
        }
    }

    static var stored: AppAppearance {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppAppearance.init) ?? .system
    }

    /// Setting NSApp.appearance re-themes every window, including SwiftUI's colorScheme.
    @MainActor
    func apply() {
        switch isDark {
        case nil: NSApp.appearance = nil
        case false?: NSApp.appearance = NSAppearance(named: .aqua)
        case true?: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        for window in NSApp.windows { ThemeStore.style(window, palette: palette) }
    }
}

/// The current theme, observable so every window re-renders when it changes.
@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()
    var appearance: AppAppearance = AppAppearance.stored {
        didSet { let palette = appearance.palette; Self.snapshot.withLock { $0 = palette } }
    }

    /// The palette for code that draws outside SwiftUI's observation (highlighting, gutter).
    nonisolated static var palette: ThemePalette? { snapshot.withLock { $0 } }
    private nonisolated static let snapshot = OSAllocatedUnfairLock<ThemePalette?>(initialState: AppAppearance.stored.palette)

    /// Window background behind the SwiftUI content (title bar area, gaps between panes).
    static func style(_ window: NSWindow, palette: ThemePalette?) {
        window.backgroundColor = palette?.window ?? .windowBackgroundColor
    }
}

/// Colours of one theme. Syntax colours follow the token kinds of `Highlighter`.
struct ThemePalette: Equatable, @unchecked Sendable {
    var window: NSColor
    var pane: NSColor
    var editorBackground: NSColor
    var editorForeground: NSColor
    var gutter: NSColor
    var gutterText: NSColor
    var selection: NSColor
    var caret: NSColor
    var accent: NSColor
    var keyword: NSColor
    var type: NSColor
    var string: NSColor
    var number: NSColor
    var comment: NSColor
    var attribute: NSColor
    var function: NSColor
    var key: NSColor
    var tag: NSColor
    var punctuation: NSColor
    var heading: NSColor
    /// ANSI colours 0–15 for the terminals.
    var ansi: [NSColor]

    func syntax(_ kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: keyword
        case .type: type
        case .string: string
        case .number: number
        case .comment: comment
        case .attribute: attribute
        case .function: function
        case .key: key
        case .tag: tag
        case .punctuation: punctuation
        case .heading: heading
        }
    }

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func colors(_ values: [UInt32]) -> [NSColor] { values.map(hex) }

    /// IntelliJ's classic dark theme.
    static let darcula = ThemePalette(
        window: hex(0x3C3F41), pane: hex(0x3C3F41), editorBackground: hex(0x2B2B2B), editorForeground: hex(0xA9B7C6),
        gutter: hex(0x313335), gutterText: hex(0x606366), selection: hex(0x214283), caret: hex(0xBBBBBB),
        accent: hex(0x4A88C7),
        keyword: hex(0xCC7832), type: hex(0xA9B7C6), string: hex(0x6A8759), number: hex(0x6897BB),
        comment: hex(0x808080), attribute: hex(0xBBB529), function: hex(0xFFC66D), key: hex(0x9876AA),
        tag: hex(0xE8BF6A), punctuation: hex(0xCC7832), heading: hex(0xCC7832),
        ansi: colors([0x000000, 0xFF6B68, 0xA8C023, 0xD6BF55, 0x5394EC, 0xAE8ABE, 0x299999, 0x999999,
                      0x555555, 0xFF8785, 0xB6D95F, 0xFFFF00, 0x7EAEF1, 0xFF99FF, 0x6CDADA, 0xFFFFFF]))

    /// A calm blue night, after Tokyo Night Storm.
    static let storm = ThemePalette(
        window: hex(0x1F2335), pane: hex(0x1F2335), editorBackground: hex(0x24283B), editorForeground: hex(0xC0CAF5),
        gutter: hex(0x1F2335), gutterText: hex(0x3B4261), selection: hex(0x364A82), caret: hex(0xC0CAF5),
        accent: hex(0x7AA2F7),
        keyword: hex(0xBB9AF7), type: hex(0x2AC3DE), string: hex(0x9ECE6A), number: hex(0xFF9E64),
        comment: hex(0x565F89), attribute: hex(0xE0AF68), function: hex(0x7AA2F7), key: hex(0x73DACA),
        tag: hex(0xF7768E), punctuation: hex(0x89DDFF), heading: hex(0x7AA2F7),
        ansi: colors([0x1D202F, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                      0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5]))

    /// A soft light theme: white editor on light grey panes, IntelliJ-like syntax colours.
    static let hearthLight = ThemePalette(
        window: hex(0xF2F3F5), pane: hex(0xF7F8FA), editorBackground: hex(0xFFFFFF), editorForeground: hex(0x1F2328),
        gutter: hex(0xF7F8FA), gutterText: hex(0xAEB3C2), selection: hex(0xC9DCFB), caret: hex(0x1F2328),
        accent: hex(0x3574F0),
        keyword: hex(0x0033B3), type: hex(0x00627A), string: hex(0x067D17), number: hex(0x1750EB),
        comment: hex(0x8C8C8C), attribute: hex(0x9E880D), function: hex(0x00627A), key: hex(0x871094),
        tag: hex(0x0033B3), punctuation: hex(0x6E7781), heading: hex(0x0033B3),
        ansi: colors([0x24292F, 0xCF222E, 0x116329, 0x7D4E00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
                      0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F]))
}

private struct ThemePaletteKey: EnvironmentKey {
    static let defaultValue: ThemePalette? = nil
}

extension EnvironmentValues {
    /// The current theme's palette (nil: system colours). Set once per window by `hearthTheme()`.
    var themePalette: ThemePalette? {
        get { self[ThemePaletteKey.self] }
        set { self[ThemePaletteKey.self] = newValue }
    }
}

/// Applies the current theme to a window's SwiftUI content: palette, accent and pane background.
private struct HearthTheme: ViewModifier {
    func body(content: Content) -> some View {
        let palette = ThemeStore.shared.appearance.palette
        content
            .environment(\.themePalette, palette)
            .tint(palette.map { Color(nsColor: $0.accent) })
            .background { if let palette { Color(nsColor: palette.pane).ignoresSafeArea() } }
            .background(WindowStyler(palette: palette))
    }
}

/// Gives the hosting window the theme's background (also windows opened later).
private struct WindowStyler: NSViewRepresentable {
    let palette: ThemePalette?
    func makeNSView(context: Context) -> NSView { StylerView() }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? StylerView)?.palette = palette
        if let window = view.window { ThemeStore.style(window, palette: palette) }
    }

    final class StylerView: NSView {
        var palette: ThemePalette?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { ThemeStore.style(window, palette: palette) }
        }
    }
}

extension View {
    func hearthTheme() -> some View { modifier(HearthTheme()) }
}
