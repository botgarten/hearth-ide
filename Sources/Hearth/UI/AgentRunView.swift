import SwiftUI
import AppKit


/// The chat area for an agent that runs as a terminal (Claude Code and every agent
/// without a native chat yet): same header and status as a native chat, with the
/// agent's own interface below.
struct AgentRunView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.textScale) private var scale
    let run: AgentRun
    private let renaming = State(initialValue: false)
    private let newTitle = State(initialValue: "")

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = run.error {
                notice(error, symbol: "exclamationmark.triangle.fill", color: .red)
            } else if let detail = run.detail, run.status == .needsInput {
                notice(detail, symbol: "hand.raised.fill", color: .orange)
            }
            ZStack {
                if run.terminal != nil || run.launchCount > 0 {
                    AgentTerminalHost(run: run, launchCount: run.launchCount, dark: colorScheme == .dark, scale: scale,
                                      theme: ThemeStore.shared.appearance)
                } else {
                    resumePlaceholder
                }
                if !run.isRunning, run.terminal != nil {
                    VStack {
                        Spacer()
                        HStack(spacing: 10) {
                            Text(run.exitCode.map { "Session ended (code \($0))" } ?? "Session ended").font(.callout)
                            if run.purpose == .session {
                                Button(run.canResume ? "Resume" : "Restart") { model.agents.resume(run) }
                                    .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(14)
                    }
                }
            }
        }
        .alert("Rename session", isPresented: renaming.projectedValue) {
            TextField("Title", text: newTitle.projectedValue)
            Button("Rename") { model.agents.rename(run, to: newTitle.wrappedValue) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: run.kind.symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(run.title).scaledFont(.headline).lineLimit(1)
                    if run.status != .idle { StatusBadge(status: run.status) }
                }
                HStack(spacing: 4) {
                    Text(run.kind.displayName)
                    Text("·")
                    Text(run.directory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.head)
                }
                .scaledFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SandboxBadge(kind: run.kind, running: run.isRunning)
            if run.isRunning {
                Button { model.agents.stop(run) } label: { Image(systemName: "stop.circle") }
                    .help("End session")
            } else if run.purpose == .session {
                Button { model.agents.resume(run) } label: { Image(systemName: "play.circle") }
                    .help(run.canResume ? "Resume the conversation" : "Restart")
            }
            Menu {
                Button("Rename…") { newTitle.wrappedValue = run.title; renaming.wrappedValue = true }
                Button("New session in the same folder") { model.startAgent(run.kind, directory: run.directory) }
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: run.directory) }
                Divider()
                Button("Show sandbox profile") {
                    NSWorkspace.shared.open(SandboxManager.runDirectory(run.id).appendingPathComponent("nono-profile.json"))
                }
                Button("Show sandbox log") {
                    NSWorkspace.shared.open(SandboxManager.runDirectory(run.id).appendingPathComponent("nono.log"))
                }
                Divider()
                Button("Remove session", role: .destructive) { model.agents.remove(run) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func notice(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).scaledFont(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(color.opacity(0.08))
    }

    private var resumePlaceholder: some View {
        ContentUnavailableView {
            Label(run.title, systemImage: run.kind.symbol)
        } description: {
            Text(run.canResume
                 ? "This session has ended. \(run.kind.displayName) can resume the conversation in a new sandbox."
                 : "This session has ended.")
        } actions: {
            Button(run.canResume ? "Resume" : "Restart") { model.agents.resume(run) }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Shows that the agent runs sandboxed, with what the sandbox allows on hover.
struct SandboxBadge: View {
    let kind: AgentKind
    let running: Bool

    var body: some View {
        Label("Sandbox", systemImage: running ? "lock.shield.fill" : "lock.shield")
            .font(.caption.bold())
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(running ? Color.green : Color.secondary)
            .background((running ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
            .help(summary)
    }

    private var summary: String {
        let spec = kind.sandbox
        let home = AgentHome.layout(for: kind, support: SandboxManager.supportDirectory.path, home: NSHomeDirectory())
        let own: String = home.root != nil ? String(localized: " and Hearth’s own \(kind.displayName) folder")
            : home.hostReadWrite.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: ", ")
        var lines: [String] = [String(localized: "nono sandbox (Seatbelt)"),
                     String(localized: "Write: only this folder") + (own.isEmpty || own.hasPrefix(" ") ? own : String(localized: " and ") + own),
                     String(localized: "Blocked: SSH keys, shell configuration, browser data, the rest of your home folder"),
                     String(localized: "Network: LLM APIs, package registries, GitHub/GitLab, documentation") + (spec.domains.isEmpty ? "" : ", " + spec.domains.joined(separator: ", "))]
        if spec.keychain { lines.append(String(localized: "Keychain: allowed (the agent’s login)")) }
        return lines.joined(separator: "\n")
    }
}

/// Hosts a run's long-lived terminal view. Switching sessions only moves the view;
/// the process keeps running.
struct AgentTerminalHost: NSViewRepresentable {
    let run: AgentRun
    let launchCount: Int
    let dark: Bool
    let scale: Double
    var theme: AppAppearance = .system

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let terminal = run.terminal else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if terminal.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            terminal.removeFromSuperview()
            terminal.frame = container.bounds
            terminal.autoresizingMask = [.width, .height]
            container.addSubview(terminal)
            DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        }
        if run.themedDark != dark || run.themedScale != scale || run.themedTheme != theme {
            TerminalTheme.apply(to: terminal, dark: dark, scale: scale)
            run.themedDark = dark
            run.themedTheme = theme
            run.themedScale = scale
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        // Detach only; the terminal (and its process) belongs to the run.
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Inbox row for an agent session.
struct AgentRunRow: View {
    @Environment(AppModel.self) private var model
    let run: AgentRun
    private let renaming = State(initialValue: false)
    private let newTitle = State(initialValue: "")

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: run.kind.symbol).foregroundStyle(run.isRunning ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(run.title).lineLimit(1)
                Spacer(minLength: 4)
                if run.status != .idle && run.status != .inactive { StatusBadge(status: run.status) }
            }
            HStack(spacing: 4) {
                Text(run.folderName)
                Text("·")
                Text(run.isRunning ? String(localized: "running") : String(localized: "ended"))
                Text("·")
                Text(run.updated.formatted(.relative(presentation: .named)))
            }
            .scaledFont(.caption).foregroundStyle(.secondary)
            if let detail = run.detail, run.status == .needsInput || run.status == .done {
                Text(detail).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let error = run.error {
                Text(error).scaledFont(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if run.isRunning {
                Button { model.agents.stop(run) } label: { Label("End session", systemImage: "stop.circle") }
            } else if run.purpose == .session {
                Button { model.agents.resume(run); model.selectRun(run.id) } label: {
                    Label(run.canResume ? "Resume" : "Restart", systemImage: "play.circle")
                }
            }
            Button { newTitle.wrappedValue = run.title; renaming.wrappedValue = true } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button { model.startAgent(run.kind, directory: run.directory) } label: {
                Label("New session in the same folder", systemImage: "plus.bubble")
            }
            Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: run.directory) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Divider()
            Button(role: .destructive) { model.agents.remove(run) } label: { Label("Remove", systemImage: "trash") }
        }
        .alert("Rename session", isPresented: renaming.projectedValue) {
            TextField("Title", text: newTitle.projectedValue)
            Button("Rename") { model.agents.rename(run, to: newTitle.wrappedValue) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
