import SwiftUI
import AppKit
import SwiftTerm

/// Font and colors of the user's default iTerm2 profile, so the embedded
/// terminal looks like the terminal they chose in the settings.
struct ITermProfile {
    var font: NSFont?
    var foreground: NSColor?
    var background: NSColor?
    var cursor: NSColor?
    var selection: NSColor?
    var ansi: [NSColor] = []

    static func load(dark: Bool) -> ITermProfile? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.googlecode.iterm2.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let profiles = root["New Bookmarks"] as? [[String: Any]], !profiles.isEmpty else { return nil }
        let guid = root["Default Bookmark Guid"] as? String
        let p = profiles.first { $0["Guid"] as? String == guid } ?? profiles[0]
        // Profiles may keep separate light/dark palettes ("Foreground Color (Dark)").
        let separate = p["Use Separate Colors for Light and Dark Mode"] as? Bool ?? false
        func color(_ key: String) -> NSColor? {
            let dict = (separate ? p["\(key) (\(dark ? "Dark" : "Light"))"] : nil) ?? p[key]
            guard let c = dict as? [String: Any],
                  let r = c["Red Component"] as? Double, let g = c["Green Component"] as? Double,
                  let b = c["Blue Component"] as? Double else { return nil }
            return NSColor(srgbRed: r, green: g, blue: b, alpha: c["Alpha Component"] as? Double ?? 1)
        }
        var profile = ITermProfile()
        if let spec = p["Normal Font"] as? String, let space = spec.lastIndex(of: " "),
           let size = Double(spec[spec.index(after: space)...]) {
            profile.font = NSFont(name: String(spec[..<space]), size: size)
        }
        profile.foreground = color("Foreground Color")
        profile.background = color("Background Color")
        profile.cursor = color("Cursor Color")
        profile.selection = color("Selection Color")
        profile.ansi = (0..<16).compactMap { color("Ansi \($0) Color") }
        return profile
    }
}

/// Embedded terminal pane: the user's login shell in the workspace, on the host (no sandbox,
/// labelled as such); looks like iTerm2 when that is the preferred terminal.
struct TerminalPaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.textScale) private var scale
    let root: String?

    private let generation = State(initialValue: 0)   // bump to restart the process
    private let exited = State(initialValue: Int32?.none)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text(title).scaledFont(.caption, bold: true).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("no sandbox").scaledFont(.caption2).foregroundStyle(.orange)
                    .help("This shell runs directly on the Mac, not in the sandbox. Files an agent wrote are not trustworthy.")
                Button { generation.wrappedValue += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("Restart terminal")
                Button { openExternally() } label: { Image(systemName: "arrow.up.forward.app") }
                    .help("Open in \(TerminalLauncher.preferred.rawValue)")
            }
            .buttonStyle(.borderless)
            .scaledFont(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            ZStack(alignment: .bottom) {
                EmbeddedTerminal(command: command, cwd: root ?? NSHomeDirectory(), dark: colorScheme == .dark,
                                 scale: scale, theme: ThemeStore.shared.appearance, onExit: { exited.wrappedValue = $0 })
                    .id("\(generation.wrappedValue)#\(command.joined(separator: " "))#\(root ?? "")#\(colorScheme == .dark)")
                if let code = exited.wrappedValue {
                    HStack {
                        Text("Process ended (code \(code))").font(.caption)
                        Button("Restart") { generation.wrappedValue += 1 }.controlSize(.small)
                    }
                    .padding(8).background(.regularMaterial, in: Capsule()).padding(10)
                }
            }
        }
        .onChange(of: generation.wrappedValue) { exited.wrappedValue = nil }
    }

    private var title: String {
        (root ?? NSHomeDirectory()).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// argv for the process: the login shell.
    private var command: [String] {
        [ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", "-l"]
    }

    private func openExternally() {
        let cmd = "cd \(TerminalLauncher.shellQuote(root ?? NSHomeDirectory()))"
        Task {
            if let err = await TerminalLauncher.launch(TerminalLauncher.preferred, command: cmd) { model.banner = err }
        }
    }
}

/// SwiftTerm's LocalProcessTerminalView (real PTY) wrapped for SwiftUI.
struct EmbeddedTerminal: NSViewRepresentable {
    let command: [String]
    let cwd: String
    let dark: Bool
    let scale: Double
    /// Current theme; a change re-colours the running terminal.
    var theme: AppAppearance = .system
    let onExit: (Int32?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let security = TerminalSecurity(view)
        context.coordinator.security = security
        view.terminalDelegate = security
        view.processDelegate = context.coordinator
        applyTheme(to: view)
        context.coordinator.themed = theme
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "hearth"
        if env["LANG"] == nil { env["LANG"] = "de_DE.UTF-8" }
        view.startProcess(executable: command[0], args: Array(command.dropFirst()),
                          environment: env.map { "\($0.key)=\($0.value)" },
                          execName: "-" + URL(fileURLWithPath: command[0]).lastPathComponent,
                          currentDirectory: cwd)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        let size = baseFontSize * scale
        if abs(view.font.pointSize - size) > 0.1 { view.font = font(size: size) }
        if context.coordinator.themed != theme {
            context.coordinator.themed = theme
            applyTheme(to: view)
        }
    }

    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
        view.terminate()
    }

    private var baseFontSize: Double { TerminalTheme.baseFontSize(dark: dark) }

    private func font(size: Double) -> NSFont { TerminalTheme.font(size: size, dark: dark) }

    private func applyTheme(to view: LocalProcessTerminalView) {
        TerminalTheme.apply(to: view, dark: dark, scale: scale)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var security: TerminalSecurity?
        var themed: AppAppearance?
        let onExit: (Int32?) -> Void
        init(onExit: @escaping (Int32?) -> Void) { self.onExit = onExit }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { self.onExit(exitCode) }
        }
    }
}

/// Font and colours shared by every embedded terminal: the user's iTerm2 profile
/// when iTerm2 is the preferred terminal, else the system monospaced font.
enum TerminalTheme {
    static func profile(dark: Bool) -> ITermProfile? {
        TerminalLauncher.preferred == .iTerm ? ITermProfile.load(dark: dark) : nil
    }

    static func baseFontSize(dark: Bool) -> Double {
        profile(dark: dark)?.font.map { Double($0.pointSize) } ?? 12
    }

    static func font(size: Double, dark: Bool) -> NSFont {
        if let f = profile(dark: dark)?.font, let scaled = NSFont(name: f.fontName, size: size) { return scaled }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func apply(to view: TerminalView, dark: Bool, scale: Double) {
        let p = profile(dark: dark)
        view.font = font(size: (p?.font.map { Double($0.pointSize) } ?? 12) * scale, dark: dark)
        if let palette = ThemeStore.palette {
            // A Hearth theme wins over the iTerm2 colours (the iTerm2 font stays).
            view.installColors(palette.ansi.map { c in
                let s = c.usingColorSpace(.sRGB) ?? c
                return SwiftTerm.Color(red: UInt16(s.redComponent * 65535), green: UInt16(s.greenComponent * 65535),
                                       blue: UInt16(s.blueComponent * 65535))
            })
            view.nativeForegroundColor = palette.editorForeground
            view.nativeBackgroundColor = palette.editorBackground
            view.caretColor = palette.caret
            view.selectedTextBackgroundColor = palette.selection
        } else if let p {
            if p.ansi.count == 16 {
                view.installColors(p.ansi.map { c in
                    let s = c.usingColorSpace(.sRGB) ?? c
                    return SwiftTerm.Color(red: UInt16(s.redComponent * 65535), green: UInt16(s.greenComponent * 65535),
                                           blue: UInt16(s.blueComponent * 65535))
                })
            }
            if let fg = p.foreground { view.nativeForegroundColor = fg }
            if let bg = p.background { view.nativeBackgroundColor = bg }
            if let c = p.cursor { view.caretColor = c }
            if let s = p.selection { view.selectedTextBackgroundColor = s }
        } else {
            // Resolve the dynamic system colours for the requested appearance now; the
            // terminal draws with whatever appearance is current at draw time otherwise.
            var fg = NSColor.textColor, bg = NSColor.textBackgroundColor
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                fg = NSColor.textColor.usingColorSpace(.sRGB) ?? fg
                bg = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? bg
            }
            view.nativeForegroundColor = fg
            view.nativeBackgroundColor = bg
        }
    }
}
