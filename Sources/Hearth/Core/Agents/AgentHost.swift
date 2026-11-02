import AppKit
import Foundation
import SwiftTerm

/// One agent session in a sandbox. Its terminal view lives as long as the session,
/// independent of which session the window currently shows.
@MainActor
@Observable
final class AgentRun: Identifiable {
    enum Purpose: String, Codable { case session, login }

    let id: String
    let kind: AgentKind
    let directory: String
    let purpose: Purpose
    var title: String
    var status: AgentStatus = .inactive
    /// Last message from the agent (e.g. which permission it asks for).
    var detail: String?
    /// The agent's own session ID, used to continue the conversation after a restart.
    var sessionID: String?
    let created: Date
    var updated: Date
    var isRunning = false
    var exitCode: Int32?
    var error: String?
    /// Bumped on every (re)start so views pick up the terminal view.
    var launchCount = 0

    @ObservationIgnored var terminal: LocalProcessTerminalView?
    @ObservationIgnored var themedScale: Double?
    @ObservationIgnored var restartAfterExit = false
    @ObservationIgnored fileprivate var delegate: AgentTerminalDelegate?
    @ObservationIgnored fileprivate var eventOffset: UInt64 = 0
    @ObservationIgnored var themedDark: Bool?
    @ObservationIgnored var themedTheme: AppAppearance?

    init(id: String = UUID().uuidString.lowercased(), kind: AgentKind, directory: String, purpose: Purpose = .session,
         title: String? = nil, sessionID: String? = nil, created: Date = Date(), updated: Date = Date()) {
        self.id = id
        self.kind = kind
        self.directory = directory
        self.purpose = purpose
        self.title = title ?? (purpose == .login ? String(localized: "\(kind.displayName) – Sign-in") : kind.displayName)
        self.sessionID = sessionID
        self.created = created
        self.updated = updated
    }

    var folderName: String { URL(fileURLWithPath: directory).lastPathComponent }

    /// Whether the agent can continue this conversation. Claude Code only writes its
    /// transcript with the first message, so a session that never got a prompt has none.
    var canResume: Bool {
        guard let sid = sessionID else { return false }
        guard kind == .claude else { return true }
        // Transcripts live in Hearth's own Claude folder (AgentHome).
        let projects = URL(fileURLWithPath: AgentHome.claudeProjects(support: SandboxManager.supportDirectory.path))
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        return dirs.contains { FileManager.default.fileExists(atPath: projects.appendingPathComponent("\($0)/\(sid).jsonl").path) }
    }
    var hasCustomTitle: Bool { title != kind.displayName }
}

/// Starts, tracks and persists agent sessions. Status comes from the agent's hooks
/// (Claude Code), its notify command (Codex) or terminal heuristics (others).
@MainActor
@Observable
final class AgentHost {
    private(set) var runs: [AgentRun] = []
    var selectedRunID: String?
    var startSheet: StartAgentRequest?

    struct StartAgentRequest: Identifiable {
        let id = UUID()
        var directory: String?
        var kind: AgentKind?
    }

    @ObservationIgnored private var poller: Timer?
    @ObservationIgnored var onAttention: ((AgentRun) -> Void)?
    /// The agent may have changed files (a tool ran, a turn ended, the session exited).
    @ObservationIgnored var onFilesChanged: ((AgentRun) -> Void)?
    @ObservationIgnored private var lastFilesSignal: [String: Date] = [:]

    private func filesChanged(_ run: AgentRun) {
        let now = Date()
        if let last = lastFilesSignal[run.id], now.timeIntervalSince(last) < 1 { return }
        lastFilesSignal[run.id] = now
        onFilesChanged?(run)
    }

    init() {
        load()
        poller = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollEvents() }
        }
    }

    var selectedRun: AgentRun? { selectedRunID.flatMap { id in runs.first { $0.id == id } } }

    /// Sessions sorted for the inbox: attention first, then newest.
    var sorted: [AgentRun] {
        runs.sorted { ($0.status.priority, $1.updated) < ($1.status.priority, $0.updated) }
    }

    func run(_ id: String) -> AgentRun? { runs.first { $0.id == id } }

    // MARK: Lifecycle

    @discardableResult
    func start(kind: AgentKind, directory: String, purpose: AgentRun.Purpose = .session) -> AgentRun {
        let run = AgentRun(kind: kind, directory: directory, purpose: purpose)
        runs.append(run)
        launch(run)
        save()
        return run
    }

    /// Restarts a finished session, continuing the agent's conversation when it supports that.
    func resume(_ run: AgentRun) {
        guard !run.isRunning else { return }
        launch(run)
    }

    func stop(_ run: AgentRun) {
        guard let terminal = run.terminal, run.isRunning else { return }
        terminal.terminate()
    }

    func remove(_ run: AgentRun) {
        stop(run)
        run.terminal?.removeFromSuperview()
        run.terminal = nil
        runs.removeAll { $0.id == run.id }
        if selectedRunID == run.id { selectedRunID = nil }
        try? FileManager.default.removeItem(at: SandboxManager.runDirectory(run.id))
        save()
    }

    func rename(_ run: AgentRun, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        run.title = t
        save()
    }

    /// Selecting a finished session counts as having seen its result.
    func acknowledge(_ run: AgentRun) {
        if run.status == .done { run.status = run.isRunning ? .idle : .inactive }
    }

    func stopAll() { runs.forEach(stop) }

    /// Restarts running sessions so new sandbox settings apply (Claude/Codex continue their conversation).
    func restartRunning() {
        for run in runs where run.isRunning && run.purpose == .session {
            run.restartAfterExit = true
            stop(run)
        }
    }
    var runningCount: Int { runs.filter(\.isRunning).count }

    private func launch(_ run: AgentRun) {
        run.error = nil
        run.exitCode = nil
        let args: [String]
        if run.purpose == .login { args = run.kind.loginArguments ?? [] }
        else {
            if !run.canResume || !(run.sessionID.map(Self.validSessionID) ?? true) { run.sessionID = nil }
            args = run.kind.arguments(resume: run.sessionID)
        }
        let launch: SandboxManager.Launch
        do {
            launch = try SandboxManager.prepare(.agent(run.kind), runID: run.id, directory: run.directory,
                                                arguments: args, statusHooks: run.purpose == .session)
        } catch {
            run.error = error.localizedDescription
            run.status = .blocked
            return
        }
        // Read only events written from now on.
        let events = SandboxManager.runDirectory(run.id).appendingPathComponent("events.jsonl")
        run.eventOffset = (try? FileManager.default.attributesOfItem(atPath: events.path)[.size] as? UInt64) ?? 0

        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let view = run.terminal ?? LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        if run.terminal == nil {
            let delegate = AgentTerminalDelegate(view: view)
            delegate.onExit = { [weak self, weak run] code in
                guard let self, let run else { return }
                self.processExited(run, code: code)
            }
            delegate.security.onSend = { [weak self, weak run] data in
                guard let self, let run else { return }
                self.userTyped(run, data)
            }
            delegate.security.onBell = { [weak self, weak run] in
                guard let self, let run else { return }
                self.bell(run)
            }
            view.terminalDelegate = delegate.security
            view.processDelegate = delegate
            run.delegate = delegate
            run.terminal = view
        } else {
            // Restart in the same view: start below the previous output.
            view.feed(text: String(localized: "\r\n\u{1b}[2m── restarted ──\u{1b}[0m\r\n"))
        }
        TerminalTheme.apply(to: view, dark: dark, scale: 1)
        run.themedDark = dark
        run.themedTheme = ThemeStore.shared.appearance
        view.startProcess(executable: launch.executable, args: launch.arguments, environment: launch.environment,
                          execName: nil, currentDirectory: launch.directory)
        run.themedScale = 1
        run.isRunning = true
        run.launchCount += 1
        run.status = .idle
        run.updated = Date()
    }

    private func processExited(_ run: AgentRun, code: Int32?) {
        run.isRunning = false
        filesChanged(run)
        run.exitCode = code
        pollEvents(run)
        if run.status != .done { run.status = .inactive }
        if run.restartAfterExit {
            run.restartAfterExit = false
            run.updated = Date()
            launch(run)
            return
        }
        if let code, code != 0, run.updated.timeIntervalSinceNow > -3 {
            // Failed right at startup: show nono's/the agent's reason from the log.
            run.error = Self.lastLogLines(run) ?? String(localized: "Exited with code \(code).")
            run.status = .blocked
        }
        run.updated = Date()
        save()
    }

    private static func lastLogLines(_ run: AgentRun) -> String? {
        let log = SandboxManager.runDirectory(run.id).appendingPathComponent("nono.log")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").filter { $0.contains("ERROR") || $0.contains("error") }.suffix(3)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: Status

    private func userTyped(_ run: AgentRun, _ data: ArraySlice<UInt8>) {
        guard run.isRunning, run.kind.statusSource != .hooks, data.contains(13) else { return }
        set(run, .running)
    }

    private func bell(_ run: AgentRun) {
        guard run.isRunning, run.kind.statusSource == .terminal else { return }
        set(run, .needsInput, detail: String(localized: "The agent needs your attention."))
    }

    private func pollEvents() {
        for run in runs where run.isRunning { pollEvents(run) }
    }

    static let maxEventChunk = 1 << 20

    private func pollEvents(_ run: AgentRun) {
        let url = SandboxManager.runDirectory(run.id).appendingPathComponent("events.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        // The sandbox writes this file: read at most 1 MB per poll, skip an oversized line.
        let limit = Self.maxEventChunk
        guard (try? handle.seek(toOffset: run.eventOffset)) != nil,
              let data = try? handle.read(upToCount: limit), !data.isEmpty else { return }
        guard let lastNewline = data.lastIndex(of: 10) else {
            if data.count >= limit { run.eventOffset += UInt64(data.count) }
            return
        }
        let complete = data[data.startIndex...lastNewline]
        run.eventOffset += UInt64(complete.count)
        for line in complete.split(separator: 10) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            apply(obj, to: run)
        }
    }

    /// The event file lies in the run folder, which the sandbox may write. A session ID goes
    /// into the agent's arguments on resume (`--resume <id>`), so it must not look like an
    /// option or carry anything but ID characters (S7 in docs/review-security-architecture.md).
    static func validSessionID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$"#, options: .regularExpression) != nil
    }

    private func apply(_ event: [String: Any], to run: AgentRun) {
        if let sid = event["session_id"] as? String ?? event["thread-id"] as? String, Self.validSessionID(sid), run.sessionID != sid {
            run.sessionID = sid
            save()
        }
        let name = event["hook_event_name"] as? String ?? event["type"] as? String ?? ""
        switch name {
        case "SessionStart":
            if run.status != .running { set(run, .idle) }
        case "UserPromptSubmit":
            if !run.hasCustomTitle, let prompt = event["prompt"] as? String {
                let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
                run.title = String(line.prefix(60))
                save()
            }
            set(run, .running)
        case "PreToolUse":
            set(run, .running)
        case "PostToolUse":
            filesChanged(run)
        case "PermissionRequest":
            let tool = event["tool_name"] as? String
            set(run, .needsInput, detail: tool.map { String(localized: "Wants to use \($0).") } ?? String(localized: "Waiting for approval."))
        case "Notification":
            let type = event["notification_type"] as? String
            let message = event["message"] as? String
            if type == "idle_prompt" {
                if run.status != .done { set(run, .idle) }
            } else {
                set(run, .needsInput, detail: message)
            }
        case "Stop", "agent-turn-complete":
            filesChanged(run)
            let summary = event["last_assistant_message"] as? String ?? event["last-assistant-message"] as? String
            set(run, .done, detail: summary.map { String($0.prefix(140)) })
        case "SessionEnd":
            break
        default:
            break
        }
    }

    private func set(_ run: AgentRun, _ status: AgentStatus, detail: String? = nil) {
        let changed = run.status != status
        run.status = status
        run.detail = (status == .needsInput || status == .done) ? detail : nil
        run.updated = Date()
        if changed, status == .needsInput || status == .done { onAttention?(run) }
    }

    // MARK: Persistence

    private struct Record: Codable {
        var id: String
        var kind: AgentKind
        var directory: String
        var title: String
        var sessionID: String?
        var created: Date
        var updated: Date
    }

    private static var storeURL: URL { SandboxManager.supportDirectory.appendingPathComponent("runs.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        runs = records.map {
            AgentRun(id: $0.id, kind: $0.kind, directory: $0.directory, title: $0.title,
                     sessionID: $0.sessionID, created: $0.created, updated: $0.updated)
        }
    }

    func save() {
        let records = runs.filter { $0.purpose == .session }.map {
            Record(id: $0.id, kind: $0.kind, directory: $0.directory, title: $0.title,
                   sessionID: $0.sessionID, created: $0.created, updated: $0.updated)
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: SandboxManager.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}

/// Wires a terminal view to its run: process exit plus the hardened terminal delegate.
@MainActor
final class AgentTerminalDelegate: NSObject, LocalProcessTerminalViewDelegate {
    let security: TerminalSecurity
    var onExit: ((Int32?) -> Void)?

    init(view: LocalProcessTerminalView) { security = TerminalSecurity(view) }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onExit?(exitCode) } }
    }
}
