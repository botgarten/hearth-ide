import SwiftUI
import AppKit

/// Hearth's settings. Sandbox rules are stored by Hearth itself
/// (~/Library/Application Support/Hearth/settings.json) and apply to every
/// sandbox start: agents, Build & Deployment and the Git pane.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AgentSettings().tabItem { Label("Agents", systemImage: "sparkles") }
            SandboxRuleSettings().tabItem { Label("Sandbox", systemImage: "lock.shield") }
            ProjectSettings().tabItem { Label("Projects", systemImage: "folder.badge.gearshape") }
            CredentialSettings().tabItem { Label("Credentials", systemImage: "key") }
            UpdateSettings(checker: model.updates).tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 720, height: 540)
    }
}

/// Sandbox rules are read at start; offers to restart running sessions.
private struct RestartHint: View {
    @Environment(AppModel.self) private var model
    var text = String(localized: "Changes apply to newly started sessions.")

    var body: some View {
        HStack {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
            let running = model.agents.runningCount
            if running > 0 {
                Button("Restart running sessions (\(running))") { model.agents.restartRunning() }
                    .controlSize(.small)
                    .help("Stops the running agents and starts them with the new rules. Claude Code and Codex resume their conversation.")
            }
        }
    }
}

/// One folder grant row: path, read or read+write, remove.
private struct FolderRow: View {
    let folder: SandboxSettings.Folder
    let setWrite: (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: FileManager.default.fileExists(atPath: folder.path) ? "folder" : "questionmark.folder")
                .foregroundStyle(.secondary)
            Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .lineLimit(1).truncationMode(.head).help(folder.path)
            Spacer()
            Picker("", selection: Binding(get: { folder.write }, set: setWrite)) {
                Text("read").tag(false)
                Text("read + write").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }
}

private func chooseFolder(message: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.message = message
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url.resolvingSymlinksInPath().standardizedFileURL.path
}

// MARK: General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    private let terminal = State(initialValue: TerminalLauncher.preferred)
    private let appearance = State(initialValue: AppAppearance.current)
    private let lastWindow = State(initialValue: QuitPreferences.onLastWindow)
    private let welcome = State(initialValue: AppModel.welcomeEnabled)
    private let language = State(initialValue: AppLanguage.chosen)

    var body: some View {
        Form {
            Section("Language") {
                Picker("Language", selection: Binding(get: { language.wrappedValue }, set: {
                    language.wrappedValue = $0
                    AppLanguage.choose($0)
                })) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if language.wrappedValue != AppLanguage.active {
                    HStack {
                        Text("The new language is used after a restart.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart now") { AppLanguage.relaunch() }
                    }
                }
            }
            Section("Appearance") {
                Picker("Theme", selection: Binding(get: { appearance.wrappedValue }, set: {
                    appearance.wrappedValue = $0
                    AppAppearance.current = $0
                })) {
                    ForEach([AppAppearance.system, .light, .dark]) { Text($0.title).tag($0) }
                    Divider()
                    ForEach([AppAppearance.hearthLight, .darcula, .storm]) { Text($0.title).tag($0) }
                }
                Text("Hearth Light, Darcula and Storm also colour the editor, the syntax and the terminals. With iTerm2 as your terminal, the macOS themes keep your iTerm2 colours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Terminal") {
                Picker("External terminal", selection: Binding(get: { terminal.wrappedValue }, set: {
                    terminal.wrappedValue = $0
                    TerminalLauncher.preferred = $0
                })) {
                    ForEach(TerminalLauncher.installed) { Text($0.rawValue).tag($0) }
                }
                Text("The built-in terminals use the font and colours of your iTerm2 profile when iTerm2 is selected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Layout") {
                Button("Reset layout") { model.layout.resetLayout() }
            }
            Section("Start") {
                Toggle("Show the welcome dialog when no agent is running", isOn: Binding(
                    get: { welcome.wrappedValue }, set: { welcome.wrappedValue = $0; AppModel.welcomeEnabled = $0 }))
                Button("Open the welcome dialog now") { model.showWelcome = true }
            }
            Section("Quit") {
                Picker("When the window closes", selection: Binding(get: { lastWindow.wrappedValue }, set: {
                    lastWindow.wrappedValue = $0
                    QuitPreferences.onLastWindow = $0
                })) {
                    ForEach(QuitPreferences.OnLastWindow.allCases) { Text($0.title).tag($0) }
                }
                Text("Running agent sessions are stopped when you quit; Claude Code and Codex can be resumed afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Agents

private struct AgentSettings: View {
    @Environment(AppModel.self) private var model
    private let installed = State(initialValue: [AgentKind: String]())
    private let loaded = State(initialValue: false)

    var body: some View {
        Form {
            Section {
                ForEach(AgentKind.allCases.filter { $0 != .shell }) { kind in
                    agentRow(kind)
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("Every agent uses its own login (Claude subscription, ChatGPT, GitHub …). “Sign in” starts the agent’s login in a sandbox.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Logins in the keychain") {
                Toggle("Agents may use the keychain", isOn: Binding(
                    get: { model.sandboxSettings.agentKeychain },
                    set: { on in model.updateSandboxSettings { $0.agentKeychain = on } }))
                Text("Claude Code, Codex and GitHub Copilot keep their login in the macOS keychain. Without this, they have to sign in with an API key (see Credentials).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("MCP servers") {
                Text("Set up MCP servers in the agent inside Hearth, e.g. with `claude mcp add` in a session. They run in the same sandbox as the agent; allow extra hosts under “Sandbox”.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section { RestartHint() }
        }
        .formStyle(.grouped)
        .task {
            guard !loaded.wrappedValue else { return }
            installed.wrappedValue = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: AgentKind.allCases.compactMap { k in SandboxManager.locate(k).map { (k, $0.path) } })
            }.value
            loaded.wrappedValue = true
        }
    }

    private func agentRow(_ kind: AgentKind) -> some View {
        let path = installed.wrappedValue[kind]
        let home = AgentHome.layout(for: kind, support: SandboxManager.supportDirectory.path, home: NSHomeDirectory())
        let configFolder = home.root ?? home.hostReadWrite.first
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol).frame(width: 20).foregroundStyle(path != nil ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.displayName).bold()
                if let path {
                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                } else if loaded.wrappedValue {
                    HStack(spacing: 4) {
                        Text("Not installed:").font(.caption).foregroundStyle(.secondary)
                        Text(kind.installHint).font(.caption.monospaced()).textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(kind.installHint, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).controlSize(.small).help("Copy command")
                    }
                } else {
                    ProgressView().controlSize(.mini)
                }
                if let config = configFolder {
                    Text("Settings: \(config.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let config = configFolder {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: config)) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless).help("Open the settings folder in the Finder")
                .disabled(!FileManager.default.fileExists(atPath: config))
            }
            Button("Sign in…") {
                model.startAgent(kind, directory: SandboxManager.loginDirectory.path,
                                 purpose: kind.loginArguments != nil ? .login : .session)
                NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true || $0.title == "Hearth IDE" }?.makeKeyAndOrderFront(nil)
            }
            .disabled(path == nil)
            .help(kind.loginHint)
        }
        .padding(.vertical, 2)
    }
}

// MARK: Sandbox rules

private struct SandboxRuleSettings: View {
    @Environment(AppModel.self) private var model
    private let domain = State(initialValue: "")
    private let port = State(initialValue: "")
    private let previewKind = State(initialValue: AgentKind.claude)
    private let error = State(initialValue: String?.none)

    var body: some View {
        Form {
            Section {
                Label("Write only in the session’s folder and in the agent’s settings folder", systemImage: "folder")
                Label("Blocked: SSH keys, shell configuration, browser data, cloud credentials, the rest of your home folder", systemImage: "hand.raised")
                Label("Network: LLM APIs, package registries, GitHub/GitLab, documentation and the agent’s API hosts", systemImage: "network")
            } header: {
                Text("Base rules (always on)")
            }
            .font(.callout)

            Section {
                ForEach(model.sandboxSettings.domains, id: \.self) { d in
                    HStack {
                        Text(d).font(.callout.monospaced())
                        Spacer()
                        Button { model.updateSandboxSettings { $0.domains.removeAll { $0 == d } } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Domain", text: domain.projectedValue,
                              prompt: Text(verbatim: String(localized: "api.example.com, *.example.com or https://github.com/org/**")))
                        .labelsHidden().onSubmit(addDomain)
                    Button("Add", action: addDomain)
                        .disabled(!SandboxSettings.validDomain(domain.wrappedValue))
                }
            } header: {
                Text("Extra domains")
            } footer: {
                Text("Applies to all sessions, Build & Deployment and Git.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(model.sandboxSettings.ports, id: \.self) { p in
                    HStack {
                        Text(verbatim: String(p)).font(.callout.monospaced())
                        Spacer()
                        Button { model.updateSandboxSettings { $0.ports.removeAll { $0 == p } } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Port", text: port.projectedValue, prompt: Text(verbatim: "8080"))
                        .labelsHidden().frame(width: 100).onSubmit(addPort)
                    Button("Add", action: addPort).disabled(Int(port.wrappedValue).map { !(1...65535).contains($0) } ?? true)
                    Spacer()
                }
            } header: {
                Text("Local ports")
            } footer: {
                Text("A service in the sandbox may listen on this port and reach itself (e.g. Spring Boot tests). Build & Deployment opens a service’s port automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(model.sandboxSettings.folders) { f in
                    FolderRow(folder: f,
                              setWrite: { w in model.updateSandboxSettings { s in
                                  if let i = s.folders.firstIndex(where: { $0.path == f.path }) { s.folders[i].write = w } } },
                              remove: { model.updateSandboxSettings { $0.folders.removeAll { $0.path == f.path } } })
                }
                Button { addFolder() } label: { Label("Add folder…", systemImage: "plus") }
                if let error = error.wrappedValue { Text(error).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Extra folders for all sessions")
            } footer: {
                Text("Only for one project folder? Use “Projects”.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Git area") {
                Toggle("Allow fetch, pull and clone over SSH", isOn: Binding(
                    get: { model.sandboxSettings.gitSSH },
                    set: { on in model.updateSandboxSettings { $0.gitSSH = on } }))
                Text("Only the Git area’s fixed Git commands (never an agent) may then read ~/.ssh and reach port 22. Settings such as sshCommand or credential.helper come only from your global ~/.gitconfig, never from the repository.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("View the generated profile") {
                HStack {
                    Picker("Agent", selection: previewKind.projectedValue) {
                        ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    Button("Show") { showProfile() }
                }
                Text("How Hearth starts nono for this agent (without project folders).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section { RestartHint() }
        }
        .formStyle(.grouped)
    }

    private func addDomain() {
        let d = domain.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard SandboxSettings.validDomain(d) else { return }
        domain.wrappedValue = ""
        model.updateSandboxSettings { if !$0.domains.contains(d) { $0.domains.append(d) } }
    }

    private func addPort() {
        guard let p = Int(port.wrappedValue), (1...65535).contains(p) else { return }
        port.wrappedValue = ""
        model.updateSandboxSettings { if !$0.ports.contains(p) { $0.ports.append(p); $0.ports.sort() } }
    }

    private func addFolder() {
        guard let path = chooseFolder(message: String(localized: "Folder all sandboxes may read (you can allow writing afterwards)")) else { return }
        if let problem = SandboxSettings.validFolder(path) { error.wrappedValue = problem; return }
        error.wrappedValue = nil
        model.updateSandboxSettings { if !$0.folders.contains(where: { $0.path == path }) { $0.folders.append(.init(path: path)) } }
    }

    private func showProfile() {
        let kind = previewKind.wrappedValue
        let policy = SandboxPolicy.make(.agent(kind), SandboxManager.context(runDirectory: SandboxManager.runDirectory("<sitzung>"),
                                                                            directory: nil, settings: model.sandboxSettings))
        let data = policy.profileData
        let url = SandboxManager.supportDirectory.appendingPathComponent("profil-vorschau-\(kind.rawValue).json")
        try? FileManager.default.createDirectory(at: SandboxManager.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        NSWorkspace.shared.open(url)
    }
}

// MARK: Projects

private struct ProjectSettings: View {
    @Environment(AppModel.self) private var model
    private let selected = State(initialValue: String?.none)
    private let error = State(initialValue: String?.none)

    private var projects: [SandboxSettings.Project] { model.sandboxSettings.projects }
    private var project: SandboxSettings.Project? {
        projects.first { $0.root == selected.wrappedValue } ?? projects.first
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(projects, selection: selected.projectedValue) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name)
                        Text(p.root.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    .tag(p.root)
                }
                Divider()
                HStack {
                    Button { addProject() } label: { Image(systemName: "plus") }.help("Add project folder…")
                    Button { if let p = project { model.updateSandboxSettings { $0.projects.removeAll { $0.root == p.root } } } } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(project == nil).help("Remove project (the folders stay unchanged)")
                    Spacer()
                }
                .buttonStyle(.borderless).padding(6)
            }
            .frame(minWidth: 200, maxWidth: 240)

            Group {
                if let p = project {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(p.name).font(.title3.bold())
                            Spacer()
                            Button("Start agent here…") { model.agents.startSheet = .init(directory: p.root) }
                        }
                        LabeledContent("Project folder (read + write)") {
                            Text(p.root.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.head)
                        }
                        Text("Extra folders").font(.headline)
                        if p.folders.isEmpty {
                            Text("None yet. Example: a library the agent should read as well.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(p.folders) { f in
                            FolderRow(folder: f,
                                      setWrite: { w in model.updateSandboxSettings { s in
                                          guard let pi = s.projects.firstIndex(where: { $0.root == p.root }),
                                                let fi = s.projects[pi].folders.firstIndex(where: { $0.path == f.path }) else { return }
                                          s.projects[pi].folders[fi].write = w } },
                                      remove: { model.updateSandboxSettings { s in
                                          guard let pi = s.projects.firstIndex(where: { $0.root == p.root }) else { return }
                                          s.projects[pi].folders.removeAll { $0.path == f.path } } })
                        }
                        Button { addFolder(to: p) } label: { Label("Add folder…", systemImage: "plus") }
                        if let error = error.wrappedValue { Text(error).font(.caption).foregroundStyle(.red) }
                        Spacer()
                        RestartHint(text: String(localized: "Applies to sessions that start in exactly this folder."))
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ContentUnavailableView {
                        Label("No projects", systemImage: "folder.badge.gearshape")
                    } description: {
                        Text("A project gives sessions in one folder access to more folders, e.g. a neighbouring repository.")
                    } actions: {
                        Button("Add project folder…") { addProject() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380)
        }
    }

    private func addProject() {
        guard let path = chooseFolder(message: String(localized: "Choose the project folder (where you start the agents)")) else { return }
        if let problem = SandboxSettings.validFolder(path) { error.wrappedValue = problem; return }
        error.wrappedValue = nil
        model.updateSandboxSettings { if $0.project(for: path) == nil { $0.projects.append(.init(root: path)) } }
        selected.wrappedValue = path
    }

    private func addFolder(to p: SandboxSettings.Project) {
        guard let path = chooseFolder(message: String(localized: "Extra folder for “\(p.name)” (read-only at first)")) else { return }
        if let problem = SandboxSettings.validFolder(path) { error.wrappedValue = problem; return }
        error.wrappedValue = nil
        model.updateSandboxSettings { s in
            guard let i = s.projects.firstIndex(where: { $0.root == p.root }),
                  !s.projects[i].folders.contains(where: { $0.path == path }) else { return }
            s.projects[i].folders.append(.init(path: path))
        }
    }
}

// MARK: Credentials

private struct CredentialSettings: View {
    @Environment(AppModel.self) private var model
    private let name = State(initialValue: "")
    private let mode = State(initialValue: SandboxSettings.Credential.Mode.proxy)
    private let upstream = State(initialValue: "")
    private let header = State(initialValue: "Authorization")
    private let format = State(initialValue: "Bearer {}")
    private let secret = State(initialValue: "")
    private let confirmDelete = State(initialValue: String?.none)
    private let changing = State(initialValue: String?.none)
    private let newSecret = State(initialValue: "")
    private let error = State(initialValue: String?.none)

    var body: some View {
        Form {
            Section {
                if model.sandboxSettings.credentials.isEmpty {
                    Text("No credentials yet.").foregroundStyle(.secondary)
                }
                ForEach(model.sandboxSettings.credentials) { c in credentialRow(c) }
            } header: {
                Text("Credentials")
            } footer: {
                Text("The values live in the macOS keychain (service “nono”), not in Hearth. nono reads them when a sandbox starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Add") {
                TextField("Name", text: Binding(get: { name.wrappedValue }, set: { name.wrappedValue = $0.uppercased() }),
                          prompt: Text("e.g. GITHUB_TOKEN"))
                Picker("Kind", selection: mode.projectedValue) {
                    Text("Proxy (recommended)").tag(SandboxSettings.Credential.Mode.proxy)
                    Text("Environment variable").tag(SandboxSettings.Credential.Mode.env)
                }
                .pickerStyle(.segmented)
                if mode.wrappedValue == .proxy {
                    TextField("Target API", text: upstream.projectedValue, prompt: Text(verbatim: "https://api.example.com"))
                    TextField("Header", text: header.projectedValue)
                    TextField("Format ({} = value)", text: format.projectedValue)
                    Text("Inside the sandbox $\(displayName) only holds a placeholder. nono forwards requests to $\(displayName)_BASE_URL to the target API and inserts the real value there.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("The value is in plain text as $\(displayName) inside the sandbox – the agent can read it.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                SecureField("Value", text: secret.projectedValue)
                HStack {
                    if let error = error.wrappedValue { Text(error).font(.caption).foregroundStyle(.red) }
                    Spacer()
                    Button("Add") { add() }.disabled(!canAdd)
                }
            }
            Section { RestartHint() }
        }
        .formStyle(.grouped)
        .confirmationDialog(String(localized: "Delete the credential “\(confirmDelete.wrappedValue ?? "")”?"),
                            isPresented: Binding(get: { confirmDelete.wrappedValue != nil }, set: { if !$0 { confirmDelete.wrappedValue = nil } })) {
            Button("Delete", role: .destructive) {
                guard let n = confirmDelete.wrappedValue,
                      let c = model.sandboxSettings.credentials.first(where: { $0.name == n }) else { return }
                CredentialKeychain.delete(account: c.keychainAccount)
                model.updateSandboxSettings { $0.credentials.removeAll { $0.name == n } }
            }
        } message: { Text("The value is removed from the keychain too.") }
        .alert(String(localized: "New value for \(changing.wrappedValue ?? "")"), isPresented: Binding(
            get: { changing.wrappedValue != nil }, set: { if !$0 { changing.wrappedValue = nil; newSecret.wrappedValue = "" } })) {
            SecureField("Value", text: newSecret.projectedValue)
            Button("Save") {
                if let n = changing.wrappedValue, let c = model.sandboxSettings.credentials.first(where: { $0.name == n }),
                   !newSecret.wrappedValue.isEmpty {
                    if !CredentialKeychain.store(newSecret.wrappedValue, account: c.keychainAccount) {
                        model.banner = String(localized: "The value could not be saved in the keychain.")
                    }
                }
                newSecret.wrappedValue = ""
            }
            Button("Cancel", role: .cancel) { newSecret.wrappedValue = "" }
        }
    }

    private var displayName: String { name.wrappedValue.isEmpty ? "NAME" : name.wrappedValue }

    private var canAdd: Bool {
        SandboxSettings.Credential.validName(name.wrappedValue) && !secret.wrappedValue.isEmpty
            && !model.sandboxSettings.credentials.contains { $0.name == name.wrappedValue }
            && (mode.wrappedValue == .env || URL(string: upstream.wrappedValue)?.scheme == "https")
    }

    private func credentialRow(_ c: SandboxSettings.Credential) -> some View {
        let stored = CredentialKeychain.exists(account: c.keychainAccount)
        return HStack {
            Image(systemName: stored ? "key.fill" : "key.slash").foregroundStyle(stored ? Color.secondary : Color.red)
                .help(stored ? "Value in the keychain" : "No value in the keychain")
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(c.name).bold().font(.callout.monospaced())
                    Text(c.mode == .proxy ? "Proxy" : "Environment").font(.caption2).padding(.horizontal, 5)
                        .background((c.mode == .env ? Color.orange : Color.green).opacity(0.15), in: Capsule())
                        .help(c.mode == .env ? "Value is in plain text inside the sandbox" : "The sandbox only sees a placeholder")
                }
                if c.mode == .proxy {
                    Text("→ \(c.upstream)  ·  \(c.header): \(c.format.replacingOccurrences(of: "{}", with: "…"))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { c.enabled }, set: { on in
                model.updateSandboxSettings { s in if let i = s.credentials.firstIndex(where: { $0.name == c.name }) { s.credentials[i].enabled = on } }
            }))
            .toggleStyle(.switch).labelsHidden().help("Use in sandboxes")
            Button("Change value…") { changing.wrappedValue = c.name }.controlSize(.small)
            Button { confirmDelete.wrappedValue = c.name } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }

    private func add() {
        var c = SandboxSettings.Credential(name: name.wrappedValue, mode: mode.wrappedValue)
        if c.mode == .proxy {
            c.upstream = upstream.wrappedValue.trimmingCharacters(in: .whitespaces)
            c.header = header.wrappedValue.isEmpty ? "Authorization" : header.wrappedValue
            c.format = format.wrappedValue.contains("{}") ? format.wrappedValue : "{}"
        }
        guard CredentialKeychain.store(secret.wrappedValue, account: c.keychainAccount) else {
            error.wrappedValue = String(localized: "The value could not be saved in the keychain.")
            return
        }
        error.wrappedValue = nil
        model.updateSandboxSettings { $0.credentials.append(c) }
        name.wrappedValue = ""; upstream.wrappedValue = ""; secret.wrappedValue = ""
    }
}

/// Each settings tab on its own, for the offscreen snapshot developer aid.
enum SettingsSnapshot {
    @MainActor static var tabs: [(String, AnyView)] {
        [("general", AnyView(GeneralSettings())), ("agents", AnyView(AgentSettings())),
         ("sandbox", AnyView(SandboxRuleSettings())), ("projects", AnyView(ProjectSettings())),
         ("credentials", AnyView(CredentialSettings()))]
    }
}
