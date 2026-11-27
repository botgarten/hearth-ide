import SwiftUI

/// Agent hooks of the workspace: list, allow, switch on/off, run, create, and what fired recently.
struct HooksView: View {
    @Environment(AppModel.self) private var model
    let root: String

    @State private var showNew = false
    @State private var reviewing: String?

    private var engine: AgentHooksEngine { model.hooks }

    var body: some View {
        let set = engine.sets[root] ?? HookSet()
        _ = engine.trustRevision
        return VStack(spacing: 0) {
            header(set)
            Divider()
            if set.hooks.isEmpty && set.problems.isEmpty {
                empty
            } else {
                List {
                    ForEach(set.problems) { p in
                        Label("\(p.file): \(p.message)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.caption)
                    }
                    ForEach(set.hooks) { hook in row(hook, set: set) }
                    let recent = engine.activity.filter { $0.root == root }
                    if !recent.isEmpty {
                        Section("Recently") {
                            ForEach(recent.prefix(12)) { activityRow($0) }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .task(id: "\(root)#\(model.workspace.settledRevision)") { engine.reload(root) }
        .sheet(isPresented: $showNew) { NewHookSheet(root: root) }
    }

    private var hasAgent: Bool { model.agents.runs.contains { $0.directory == root && $0.isRunning && $0.purpose == .session } }

    private func header(_ set: HookSet) -> some View {
        HStack(spacing: 6) {
            let on = set.hooks.filter { $0.enabled && $0.isSupported && engine.isTrusted($0, root: root) }.count
            Text("\(on) of \(set.hooks.count) active").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { engine.reload(root) } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload hook files")
            Button { showNew = true } label: { Image(systemName: "plus") }
                .help("New hook…")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No agent hooks", systemImage: InspectorTab.hooks.symbol)
        } description: {
            Text("Hooks react to what the agent did: when its turn ends, Hearth checks which files it created, saved or deleted and sends the hook’s prompt to the agent, or runs a command in the sandbox. Turns started by a hook never trigger hooks.")
        } actions: {
            Button("New hook…") { showNew = true }.buttonStyle(.borderedProminent)
        }
    }

    // MARK: Rows

    private func row(_ hook: AgentHook, set: HookSet) -> some View {
        let trusted = engine.isTrusted(hook, root: root)
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { hook.enabled }, set: { setEnabled(hook, $0, trusted: trusted) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help(hook.enabled ? "Switch off" : "Switch on")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: hook.trigger?.symbol ?? "questionmark.circle").foregroundStyle(.secondary)
                    Text(hook.name).bold().lineLimit(1)
                }
                Text(triggerLine(hook)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(actionLine(hook)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if !hook.isSupported {
                    Text("Not supported in Hearth: \(unsupportedPart(hook))").font(.caption2).foregroundStyle(.orange)
                } else if !trusted {
                    Text("New or changed: review and allow it before it runs.").font(.caption2).foregroundStyle(.orange)
                }
                Text(hook.file).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hook.isSupported && !trusted {
                Button("Allow…") { reviewing = hook.id }
                    .controlSize(.small)
                    .popover(isPresented: Binding(get: { reviewing == hook.id }, set: { if !$0 { reviewing = nil } })) {
                        review(hook, set: set)
                    }
            }
            Button { engine.runManually(hook, root: root) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .disabled(!trusted || !hook.isSupported || (!hasAgent && !isCommand(hook)))
                .help("Run now")
            Menu {
                Button("Open in the editor") { model.editor.open(URL(fileURLWithPath: root).appendingPathComponent(hook.file)) }
                if trusted {
                    Button("Withdraw permission") {
                        engine.trust.revoke(hook.file, root: root)
                        engine.allowRevoked()
                    }
                }
                Divider()
                Button("Delete hook", role: .destructive) {
                    do {
                        try HookLibrary.delete(hook, root: root)
                        engine.wrote(file: hook.file, root: root, wasTrusted: trusted)
                    } catch { model.banner = error.localizedDescription }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.vertical, 3)
        .opacity(hook.enabled ? 1 : 0.6)
    }

    private func isCommand(_ hook: AgentHook) -> Bool {
        if case .command = hook.action { return true }
        return false
    }

    private func triggerLine(_ hook: AgentHook) -> String {
        let t = hook.trigger?.title ?? hook.rawTrigger
        guard hook.trigger?.isFileTrigger == true else { return t }
        return t + " · " + (hook.matcher.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "any file"))
    }

    private func actionLine(_ hook: AgentHook) -> String {
        switch hook.action {
        case .agent(let prompt): String(localized: "Prompt: \(AgentHooksEngine.oneLine(prompt))")
        case .command(let c, _): "$ " + c
        case .unsupported(let type): type
        }
    }

    private func unsupportedPart(_ hook: AgentHook) -> String {
        if hook.trigger == nil { return hook.rawTrigger.isEmpty ? "trigger" : hook.rawTrigger }
        if case .unsupported(let t) = hook.action { return t }
        return ""
    }

    private func setEnabled(_ hook: AgentHook, _ on: Bool, trusted: Bool) {
        do {
            try HookLibrary.setEnabled(on, hook: hook, root: root)
            engine.wrote(file: hook.file, root: root, wasTrusted: trusted)
        } catch { model.banner = error.localizedDescription }
    }

    /// Everything the file will do, before the user allows it.
    private func review(_ hook: AgentHook, set: HookSet) -> some View {
        let inFile = set.hooks.filter { $0.file == hook.file }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Allow \(hook.file)?").font(.headline)
            Text("Hook files come from the project, and the agent can write them too. Allow this content only if you know what it does; any change to the file needs another approval.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(inFile) { h in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.name).bold()
                            Text(triggerLine(h)).font(.caption).foregroundStyle(.secondary)
                            switch h.action {
                            case .agent(let p): Text(p).font(.caption).textSelection(.enabled)
                            case .command(let c, _):
                                Text("$ " + c).font(.caption.monospaced()).textSelection(.enabled)
                                Text("Runs in Hearth’s sandbox for this folder.").font(.caption2).foregroundStyle(.secondary)
                            case .unsupported(let t): Text(t).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            HStack {
                Spacer()
                Button("Cancel") { reviewing = nil }.keyboardShortcut(.cancelAction)
                Button("Allow") {
                    engine.allow(file: hook.file, root: root)
                    reviewing = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func activityRow(_ a: AgentHooksEngine.Activity) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol(a.outcome)).foregroundStyle(color(a.outcome))
            VStack(alignment: .leading, spacing: 1) {
                Text(a.hook).font(.caption.bold()).lineLimit(1)
                Text(a.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(outcomeText(a.outcome)).font(.caption2).foregroundStyle(.secondary)
            Text(a.date, style: .time).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }

    private func symbol(_ o: AgentHooksEngine.Activity.Outcome) -> String {
        switch o {
        case .sent: "paperplane.fill"
        case .queued: "clock"
        case .noAgent: "person.crop.circle.badge.questionmark"
        case .commandOK: "checkmark.circle.fill"
        case .commandFailed: "xmark.octagon.fill"
        case .running: "hourglass"
        }
    }

    private func color(_ o: AgentHooksEngine.Activity.Outcome) -> Color {
        switch o {
        case .commandOK, .sent: .green
        case .commandFailed, .noAgent: .orange
        default: .secondary
        }
    }

    private func outcomeText(_ o: AgentHooksEngine.Activity.Outcome) -> String {
        switch o {
        case .sent: String(localized: "sent to the agent")
        case .queued: String(localized: "waits for the agent")
        case .noAgent: String(localized: "no agent running")
        case .commandOK: String(localized: "command succeeded")
        case .commandFailed(let code): code.map { String(localized: "failed (exit \($0))") } ?? String(localized: "failed")
        case .running: String(localized: "running…")
        }
    }
}

/// Creates a hook in `.hearth/hooks/`, from a template or from scratch.
private struct NewHookSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let root: String

    @State private var template: HookTemplate = .blank
    @State private var name = ""
    @State private var trigger: HookTrigger = .fileSave
    @State private var matcher = ""
    @State private var isCommand = false
    @State private var text = ""

    private var matcherValid: Bool { matcher.isEmpty || (try? NSRegularExpression(pattern: matcher)) != nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && matcherValid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New agent hook").font(.title3.bold())
            Picker("Template", selection: $template) {
                ForEach(HookTemplate.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: template) { _, t in apply(t) }
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            Picker("When", selection: $trigger) {
                ForEach(HookTrigger.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            if trigger.isFileTrigger {
                VStack(alignment: .leading, spacing: 3) {
                    TextField("Path pattern (regular expression)", text: $matcher)
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                    Text(matcherValid ? String(localized: "Matched against the path in the project, e.g. \\.swift$ or ^src/. Empty: every file.")
                                      : String(localized: "Not a valid regular expression."))
                        .font(.caption).foregroundStyle(matcherValid ? Color.secondary : Color.orange)
                }
            }
            Picker("Then", selection: $isCommand) {
                Text("Send a prompt to the agent").tag(false)
                Text("Run a command in the sandbox").tag(true)
            }
            .pickerStyle(.radioGroup)
            if isCommand {
                TextField("Command, e.g. npm run lint", text: $text).textFieldStyle(.roundedBorder).font(.body.monospaced())
                Text("Runs in Hearth’s sandbox for this folder. If it fails, its output goes to the agent.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextEditor(text: $text)
                    .font(.body).frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Text("Hearth adds the names of the changed files.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Saved in \(HookLibrary.hearthDir)/").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { save() }.keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func apply(_ t: HookTemplate) {
        guard t != .blank else { return }
        name = t.title
        trigger = t.trigger
        matcher = t.matcher
        isCommand = t.isCommand
        text = t.body
    }

    private func save() {
        do {
            let action: AgentHook.Action = isCommand ? .command(text.trimmingCharacters(in: .whitespacesAndNewlines), timeout: nil)
                                                     : .agent(prompt: text.trimmingCharacters(in: .whitespacesAndNewlines))
            let file = try HookLibrary.create(name: name.trimmingCharacters(in: .whitespaces), description: nil, trigger: trigger,
                                              matcher: matcher, action: action, root: root)
            // Written by the user through Hearth: allowed right away.
            model.hooks.allow(file: file, root: root)
            dismiss()
        } catch { model.banner = error.localizedDescription }
    }
}
