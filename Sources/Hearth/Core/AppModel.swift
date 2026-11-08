import Foundation
import AppKit
import Observation

/// Composition root of the app. Owns the stores and the selection that ties them
/// together: the selected agent session decides the workspace folder, which in turn
/// decides what the inspector, the editor tabs and Build & Deployment show.
@MainActor
@Observable
final class AppModel {
    let updates = UpdateChecker()
    let builds = BuildDeployStore()
    /// Agent sessions running in Hearth's own nono sandbox (terminal chat).
    let agents = AgentHost()
    let layout = LayoutStore()
    let editor: EditorStore
    let workspace = WorkspaceState()
    let textZoom = TextZoomStore()
    let ci: CIAccounts
    /// CI/CD pane of the workspace folder (all inspector panes show the same folder).
    let pipelines: PipelinesStore
    /// Search Everywhere (double Shift).
    let search = SearchEverywhereStore()

    /// The user's sandbox rules (domains, ports, folders, projects, credentials).
    private(set) var sandboxSettings = SandboxSettings.load()

    func updateSandboxSettings(_ change: (inout SandboxSettings) -> Void) {
        var updated = sandboxSettings
        change(&updated)
        guard updated != sandboxSettings else { return }
        do {
            try updated.save()
            sandboxSettings = updated
        } catch {
            banner = String(localized: "Settings could not be saved: \(error.localizedDescription)")
        }
    }

    var banner: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var zoomMonitor: TextZoomMonitor?

    init() {
        editor = EditorStore(layout: layout)
        let ci = CIAccounts()
        self.ci = ci
        pipelines = PipelinesStore(.init(detectRemote: { await CIRemote.of(repo: $0) },
                                         loadCredentials: { await ci.load(for: $0) },
                                         client: { ci.api(for: $0) }))
        editor.workspaceRoot = { [weak self] in self?.workspaceRoot }
        editor.notify = { [weak self] in self?.toast($0) }
        layout.notify = { [weak self] in self?.toast($0) }
        layout.onPaneClosed = { [weak self] in self?.editor.paneClosed($0) }
        textZoom.notify = { [weak self] in self?.toast($0) }
        layout.restore()
        editor.restore()

        Notifier.requestAuthorization()
        agents.onAttention = { [weak self] run in
            guard let self else { return }
            let visible = NSApp.isActive && self.agents.selectedRunID == run.id
            guard !visible else {
                // The user is looking at it: a finished turn needs no further attention.
                self.agents.acknowledge(run)
                return
            }
            let what = run.status == .needsInput ? String(localized: "is waiting for you") : String(localized: "is done")
            Notifier.notify(title: run.title, body: "\(run.kind.displayName) \(what)" + (run.detail.map { ": \($0)" } ?? "."))
        }
        search.model = self
        agents.onFilesChanged = { [weak self] run in
            guard let self, self.workspaceRoot == run.directory else { return }
            self.workspace.revision += 1
        }
        // Resolve the login shell's PATH off the main thread before the first start.
        Task.detached(priority: .utility) { _ = SandboxManager.searchPath }
        showWelcome = agents.runningCount == 0 && Self.welcomeEnabled && Snapshotter.directory == nil
        DevelopmentAids.apply(to: self)
        if Snapshotter.directory == nil { zoomMonitor = TextZoomMonitor(model: self) }
    }

    /// Short-lived confirmation message.
    func toast(_ message: String) {
        banner = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, banner == message { banner = nil }
        }
    }

    // MARK: Selection

    /// Folder the inspector shows: the selected agent session's.
    var workspaceRoot: String? { agents.selectedRun?.directory }

    /// Shows an agent session (terminal chat), its folder in the inspector and its editor tabs.
    func selectRun(_ id: String) {
        guard let run = agents.run(id) else { return }
        agents.acknowledge(run)
        guard agents.selectedRunID != id else { return }
        if workspaceRoot != run.directory { workspace.gitSnapshot = GitSnapshot() }
        agents.selectedRunID = id
        let runIDs = Set(agents.runs.map(\.id))
        var selected = workspace.selectedFile
        editor.switchWorkspace(to: "run:" + id, selectedFile: &selected) { key in
            // Removed sessions no longer need their tabs.
            !key.hasPrefix("run:") || runIDs.contains(String(key.dropFirst(4)))
        }
        workspace.selectedFile = selected
        workspace.revealID = UUID()
        workspace.refreshNow()
    }

    /// Starts an agent in the sandbox and shows it.
    func startAgent(_ kind: AgentKind, directory: String, purpose: AgentRun.Purpose = .session) {
        let run = agents.start(kind: kind, directory: directory, purpose: purpose)
        selectRun(run.id)
        if let error = run.error { banner = error }
    }

    /// Continues an earlier session (or just shows it when it is still running).
    func openSession(_ run: AgentRun) {
        if !run.isRunning { agents.resume(run) }
        selectRun(run.id)
        if let error = run.error { banner = error }
    }

    /// Types a prepared instruction into the selected agent's terminal and submits it.
    func ask(_ prompt: String) {
        guard let run = agents.selectedRun, run.isRunning, let terminal = run.terminal else {
            banner = String(localized: "First select a running agent session on the left to receive the task.")
            return
        }
        terminal.send(txt: prompt)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            terminal.send(txt: "\r")
        }
        toast(String(localized: "Task sent to \(run.kind.displayName)"))
    }

    /// Types a file path (relative to the workspace) into the agent's prompt, without sending.
    func mention(_ url: URL) {
        guard let run = agents.selectedRun, run.isRunning, let terminal = run.terminal else {
            banner = String(localized: "First select a running agent session on the left.")
            return
        }
        let path = workspaceRoot.flatMap { EditorPresentation.relativePath(url, root: $0) } ?? url.path
        terminal.send(txt: path.contains(" ") ? "\"\(path)\" " : path + " ")
        toast(String(localized: "Inserted into the chat: \(path)"))
    }

    // MARK: Sandbox commands (Build & Deployment, Git)

    @ObservationIgnored private var runners: [String: NonoCommandRunner] = [:]

    /// Hearth's sandbox for commands in `root` (nil when nono is missing).
    func runner(root: String, purpose: SandboxPurpose = .build) -> NonoCommandRunner? {
        guard SandboxManager.locateNono() != nil else { return nil }
        let id = Self.runnerID(root: root, purpose: purpose)
        let runner = runners[id] ?? NonoCommandRunner(root: root, purpose: purpose)
        runners[id] = runner
        return runner
    }

    /// The Build & Deployment sandbox of a folder and its id (BuildRun.serverID).
    struct BuildShell {
        let id: String
        let client: NonoCommandRunner
    }

    func buildShell(root: String) -> BuildShell? {
        runner(root: root).map { BuildShell(id: Self.runnerID(root: root, purpose: .build), client: $0) }
    }

    /// An existing runner by its id (BuildRun.serverID).
    func runner(id: String) -> NonoCommandRunner? { runners[id] }

    static func runnerID(root: String, purpose: SandboxPurpose) -> String {
        switch purpose {
        case .build: "build:" + root
        case .gitNetwork: "git-network:" + root
        case .gitLocal: "git-local:" + root
        case .agent(let kind): "agent-\(kind.rawValue):" + root
        }
    }

    // MARK: Welcome

    static let showWelcomeKey = "ui.showWelcomeOnLaunch"
    var showWelcome = false

    static var welcomeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: showWelcomeKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showWelcomeKey) }
    }

    /// Opens the agent start sheet from the welcome dialog (sheets can't stack).
    func welcomeStartAgent(_ prefill: AgentHost.StartAgentRequest = .init()) {
        showWelcome = false
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            agents.startSheet = prefill
        }
    }
}

/// Developer aids, all opt-in through environment variables (see README).
@MainActor
enum DevelopmentAids {
    static func apply(to model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let path = env["HEARTH_WINDOW_SNAPSHOT"] {
            // Writes the main window's layer tree to a PNG every few seconds (no screen-recording permission needed).
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    Snapshotter.writeWindow(to: URL(fileURLWithPath: path))
                }
            }
        }
        if let size = env["HEARTH_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if let w = NSApp.windows.filter({ $0.isVisible && !$0.isSheet }).max(by: { $0.frame.width < $1.frame.width }) {
                    w.setFrame(NSRect(x: 40, y: 40, width: size[0], height: size[1]), display: true)
                }
            }
        }
        if env["HEARTH_SHOW_START_SHEET"] != nil {
            Task { @MainActor [weak model] in
                try? await Task.sleep(for: .seconds(1.5))
                model?.showWelcome = false
                try? await Task.sleep(for: .milliseconds(400))
                model?.agents.startSheet = .init()
            }
        }
        // `HEARTH_AUTOSTART_AGENT=claude HEARTH_AUTOSTART_DIR=<dir>` starts an agent at launch;
        // `HEARTH_AUTOSTART_PROMPT` then confirms the folder-trust question and types the prompt.
        guard let raw = env["HEARTH_AUTOSTART_AGENT"], let kind = AgentKind(rawValue: raw),
              let dir = env["HEARTH_AUTOSTART_DIR"] else { return }
        Task { @MainActor [weak model] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let model else { return }
            model.showWelcome = false
            model.startAgent(kind, directory: dir)
            if let wanted = env["HEARTH_AUTOSTART_BUILD"] {
                // Opens Build & Deployment and runs the first task whose id/title contains the text.
                if !model.layout.paneTree.contains(tab: .build) { model.layout.addPane(.build) }
                let projects = BuildDetector.scan(root: dir)
                if let task = projects.flatMap(\.tasks).first(where: { $0.id.contains(wanted) || $0.title.contains(wanted) }),
                   let runner = model.runner(root: dir) {
                    await model.builds.start(task, root: dir, serverID: AppModel.runnerID(root: dir, purpose: .build), client: runner)
                }
            }
            guard let prompt = env["HEARTH_AUTOSTART_PROMPT"], let run = model.agents.selectedRun else { return }
            try? await Task.sleep(for: .seconds(6))
            // Claude asks whether to trust a new folder with "No, exit" preselected: pick "Yes" explicitly.
            if kind == .claude { run.terminal?.send(txt: "\u{1b}[B") }
            try? await Task.sleep(for: .milliseconds(300))
            run.terminal?.send(txt: "\r")
            try? await Task.sleep(for: .seconds(3))
            run.terminal?.send(txt: prompt)
            try? await Task.sleep(for: .milliseconds(500))
            run.terminal?.send(txt: "\r")
        }
    }
}
