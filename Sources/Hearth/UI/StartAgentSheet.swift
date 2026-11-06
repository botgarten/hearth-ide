import SwiftUI
import AppKit

/// Start an agent in a folder: pick folder and agent, or run the agent's login.
struct StartAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AgentHost.StartAgentRequest
    private let directory = State(initialValue: "")
    private let kind = State(initialValue: AgentKind.claude)
    private let installed = State(initialValue: [AgentKind: Bool]())
    @State private var cloning = false
    @State private var cloneURL = ""
    @State private var cloneParent = NSHomeDirectory()
    @State private var cloneName = ""
    @State private var cloneNameEdited = false
    @State private var cloneStatus: String?
    @State private var cloneProgress: Double?
    @State private var cloneError: String?

    static let lastDirectoryKey = "agents.lastDirectory"
    static let lastKindKey = "agents.lastKind"
    static let lastCloneParentKey = "agents.lastCloneParent"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Start agent").font(.title2.bold())
                Text("The agent works in a nono sandbox: it may only write in this folder and only reach known developer hosts.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Picker("", selection: $cloning) {
                Text("Existing folder").tag(false)
                Text("Clone repository").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(cloneStatus != nil)

            if cloning { cloneSection } else {
            VStack(alignment: .leading, spacing: 6) {
                    Text("Folder").font(.headline)
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(directory.wrappedValue.isEmpty ? String(localized: "No folder selected")
                             : directory.wrappedValue.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.head)
                            .foregroundStyle(directory.wrappedValue.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    if let problem = folderProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    } else if let project = model.sandboxSettings.project(for: directory.wrappedValue), !project.folders.isEmpty {
                        Label(String(localized: "Project folders: ") + project.folders.map { URL(fileURLWithPath: $0.path).lastPathComponent + ($0.write ? String(localized: " (write)") : String(localized: " (read)")) }
                                .joined(separator: ", "), systemImage: "folder.badge.gearshape")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Agent").font(.headline)
                VStack(spacing: 2) {
                    ForEach(AgentKind.allCases) { k in
                        agentRow(k)
                    }
                }
                .padding(4)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                if kind.wrappedValue != .shell {
                    Button("Sign in…") { start(.login) }
                        .disabled(cloning || !canStart || (kind.wrappedValue.loginArguments == nil))
                        .help(kind.wrappedValue.loginHint)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(cloning ? String(localized: "Clone and start") : String(localized: "Start")) {
                    if cloning { cloneAndStart() } else { start(.session) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(cloning ? !canClone : !canStart)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task {
            let defaults = UserDefaults.standard
            directory.wrappedValue = request.directory
                ?? defaults.string(forKey: Self.lastDirectoryKey)
                ?? model.workspaceRoot
                ?? model.agents.runs.max(by: { $0.updated < $1.updated })?.directory
                ?? ""
            if let parent = defaults.string(forKey: Self.lastCloneParentKey), FileManager.default.fileExists(atPath: parent) {
                cloneParent = parent
            }
            let found = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, SandboxManager.locate($0) != nil) })
            }.value
            installed.wrappedValue = found
            let preferred = request.kind ?? defaults.string(forKey: Self.lastKindKey).flatMap(AgentKind.init)
            if let preferred, found[preferred] == true { kind.wrappedValue = preferred }
            else if found[kind.wrappedValue] != true, let first = AgentKind.allCases.first(where: { found[$0] == true }) {
                kind.wrappedValue = first
            }
        }
    }

    private func agentRow(_ k: AgentKind) -> some View {
        let available = installed.wrappedValue[k]
        let selected = kind.wrappedValue == k
        return HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            Image(systemName: k.symbol).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(k.displayName)
                if available == false {
                    Text("Not installed – \(k.installHint)").font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if k == .claude {
                    Text("Runs as a terminal in the chat area (uses your Claude subscription)").font(.caption).foregroundStyle(.secondary)
                } else if k == .shell {
                    Text("zsh in the same sandbox, to try out the rules").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if available == nil { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .opacity(available == false ? 0.55 : 1)
        .onTapGesture { if available != false { kind.wrappedValue = k } }
    }

    private var folderProblem: String? {
        let dir = directory.wrappedValue
        guard !dir.isEmpty else { return nil }
        let resolved = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        if !resolved.hasPrefix(NSHomeDirectory() + "/") { return String(localized: "The folder must be inside your home folder.") }
        if !FileManager.default.fileExists(atPath: resolved) { return String(localized: "The folder does not exist.") }
        return nil
    }

    private var canStart: Bool {
        !directory.wrappedValue.isEmpty && folderProblem == nil && installed.wrappedValue[kind.wrappedValue] == true
    }

    // MARK: Clone

    private var cloneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Repository").font(.headline)
            TextField("https://github.com/owner/repo.git or git@host:owner/repo.git", text: $cloneURL)
                .textFieldStyle(.roundedBorder)
                .disabled(cloneStatus != nil)
                .onChange(of: cloneURL) { _, url in
                    if !cloneNameEdited { cloneName = Git.repoName(from: url) }
                }
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(cloneParent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.head)
                Text("/").foregroundStyle(.secondary)
                TextField("Folder name", text: $cloneName)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                    .onChange(of: cloneName) { _, _ in cloneNameEdited = true }
                Spacer()
                Button("Choose…") { chooseCloneParent() }
            }
            .disabled(cloneStatus != nil)
            if let status = cloneStatus {
                if let fraction = cloneProgress { ProgressView(value: fraction) } else { ProgressView().controlSize(.small) }
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let problem = cloneProblem ?? cloneError {
                Text(problem).font(.caption).foregroundStyle(.red).lineLimit(4)
            } else {
                Text("The clone runs in the Git sandbox (SSH keys and keychain only there). The agent then starts in the new folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var cloneProblem: String? {
        let url = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty, !SandboxGitOperation.validCloneURL(url) {
            return String(localized: "Please use an HTTPS or SSH Git URL without a password.")
        }
        let name = cloneName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name.contains("/") || name == "." || name == ".." {
            return String(localized: "The folder name must not contain a slash.")
        }
        if !name.isEmpty, FileManager.default.fileExists(atPath: cloneParent + "/" + name) {
            return String(localized: "“\(name)” already exists in this folder.")
        }
        return nil
    }

    private var canClone: Bool {
        let url = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return cloneStatus == nil && !url.isEmpty && !cloneName.trimmingCharacters(in: .whitespaces).isEmpty
            && cloneProblem == nil && installed.wrappedValue[kind.wrappedValue] == true
    }

    private func chooseCloneParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.directoryURL = URL(fileURLWithPath: cloneParent)
        if panel.runModal() == .OK, let url = panel.url { cloneParent = url.path }
    }

    private func cloneAndStart() {
        let url = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = URL(fileURLWithPath: cloneParent).appendingPathComponent(cloneName.trimmingCharacters(in: .whitespaces))
        cloneError = nil
        cloneStatus = String(localized: "Cloning…")
        cloneProgress = nil
        Task { @MainActor in
            let result = await model.cloneRepository(url, to: destination) { line, fraction in
                Task { @MainActor in
                    cloneStatus = line
                    cloneProgress = fraction
                }
            }
            cloneStatus = nil
            guard result.ok else {
                cloneError = result.output.lastNonEmptyLines(3)
                return
            }
            UserDefaults.standard.set(cloneParent, forKey: Self.lastCloneParentKey)
            directory.wrappedValue = destination.path
            start(.session)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        if !directory.wrappedValue.isEmpty { panel.directoryURL = URL(fileURLWithPath: directory.wrappedValue) }
        if panel.runModal() == .OK, let url = panel.url { directory.wrappedValue = url.path }
    }

    private func start(_ purpose: AgentRun.Purpose) {
        let defaults = UserDefaults.standard
        defaults.set(directory.wrappedValue, forKey: Self.lastDirectoryKey)
        defaults.set(kind.wrappedValue.rawValue, forKey: Self.lastKindKey)
        model.startAgent(kind.wrappedValue, directory: directory.wrappedValue, purpose: purpose)
        dismiss()
    }
}
