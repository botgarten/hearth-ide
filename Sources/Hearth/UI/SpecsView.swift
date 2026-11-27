import SwiftUI

/// Spec-driven development: one feature at a time through requirements → design → tasks →
/// implementation. The agent writes each document, the user reviews and approves it here,
/// and only an approved document unlocks the next step.
struct SpecsView: View {
    @Environment(AppModel.self) private var model
    let root: String

    /// `preloaded` skips the first scan and shows `initialSpec` (snapshots).
    init(root: String, preloaded: [Spec]? = nil, initialSpec: String? = nil) {
        self.root = root
        _specs = State(initialValue: preloaded)
        _selectedID = State(initialValue: initialSpec ?? preloaded?.first?.id)
        if preloaded != nil { _steering = State(initialValue: SpecLibrary.steering(root: root)) }
    }

    private enum Step: Hashable {
        case document(SpecPhase)
        case implementation
    }

    @State private var specs: [Spec]?
    @State private var steering: [String] = []
    @State private var selectedID: String?
    /// nil follows the spec's current step.
    @State private var chosenStep: Step?
    @State private var reloadToken = 0
    @State private var showNewSpec = false
    @State private var newName = ""
    @State private var newIdea = ""
    @State private var revising = false
    @State private var feedback = ""

    var body: some View {
        Group {
            if let specs {
                if let spec = specs.first(where: { $0.id == selectedID }) ?? specs.first {
                    content(spec, all: specs)
                } else {
                    empty
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(root)#\(model.workspace.settledRevision)#\(reloadToken)") { await reload() }
        .sheet(isPresented: $showNewSpec) { newSpecSheet }
    }

    private var hasAgent: Bool { model.agents.selectedRun?.isRunning == true }

    private func reload() async {
        let root = root
        let (found, steeringDocs) = await Task.detached(priority: .userInitiated) {
            (SpecLibrary.scan(root: root), SpecLibrary.steering(root: root))
        }.value
        guard !Task.isCancelled else { return }
        specs = found
        steering = steeringDocs
        if selectedID == nil || !found.contains(where: { $0.id == selectedID }) {
            selectedID = found.first?.id
        }
    }

    private func ask(_ prompt: String) { model.ask(prompt) }

    private func update(_ spec: Spec) {
        if let i = specs?.firstIndex(where: { $0.id == spec.id }) { specs?[i] = spec }
    }

    private func fail(_ error: Error) {
        model.banner = String(localized: "The spec could not be saved: \(error.localizedDescription)")
    }

    // MARK: Empty state

    private var empty: some View {
        ContentUnavailableView {
            Label("No specs yet", systemImage: InspectorTab.specs.symbol)
        } description: {
            Text("Describe a feature. The agent writes requirements, a design and a task list; you review and approve each one before it implements the tasks one by one.")
        } actions: {
            VStack(spacing: 8) {
                Button("New spec…") { startNewSpec() }
                    .buttonStyle(.borderedProminent)
                if steering.isEmpty {
                    Button("Let the agent write steering documents") { ask(SpecPrompts.steering) }
                        .disabled(!hasAgent)
                }
                if !hasAgent { agentHint }
            }
        }
    }

    private var agentHint: some View {
        Text("Start or select an agent session: it writes and implements the spec.")
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }

    // MARK: Spec

    private func content(_ spec: Spec, all: [Spec]) -> some View {
        let step = chosenStep ?? spec.currentPhase.map(Step.document) ?? .implementation
        return VStack(spacing: 0) {
            header(spec, all: all)
            Divider()
            steps(spec, selected: step)
            Divider()
            switch step {
            case .document(let phase): document(phase, of: spec)
            case .implementation: implementation(spec)
            }
        }
    }

    private func header(_ spec: Spec, all: [Spec]) -> some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(all) { s in
                    Button {
                        selectedID = s.id
                        chosenStep = nil
                    } label: {
                        if s.id == spec.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(spec.name).font(.callout.bold()).lineLimit(1)
                    Text(spec.relativePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            if all.count > 1 {
                Text("\(all.count)").font(.caption2).padding(.horizontal, 5).background(Color.primary.opacity(0.08), in: Capsule())
            }
            Spacer()
            Button { startNewSpec() } label: { Image(systemName: "plus") }
                .help("New spec…")
            Menu {
                if steering.isEmpty {
                    Text("No steering documents in \(SpecLibrary.steeringDir)")
                } else {
                    ForEach(steering, id: \.self) { path in
                        Button(path) { model.editor.open(URL(fileURLWithPath: root).appendingPathComponent(path)) }
                    }
                }
                Divider()
                Button(steering.isEmpty ? "Let the agent write steering documents" : "Let the agent update the steering documents") {
                    ask(SpecPrompts.steering)
                }
            } label: { Image(systemName: "signpost.right") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Steering: product, tech and structure notes every spec prompt refers to")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    /// Requirements → Design → Tasks → Implementation, with each step's state.
    private func steps(_ spec: Spec, selected: Step) -> some View {
        ScrollView(.horizontal, showsIndicators: false) { stepRow(spec, selected: selected) }
    }

    private func stepRow(_ spec: Spec, selected: Step) -> some View {
        HStack(spacing: 2) {
            ForEach(SpecPhase.allCases) { phase in
                stepButton(.document(phase), title: phase.title, state: stateSymbol(spec.status(phase)), selected: selected)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            let tasks = spec.tasks
            let done = tasks.filter(\.done).count
            stepButton(.implementation, title: String(localized: "Implementation"),
                       state: spec.isComplete ? ("checkmark.circle.fill", .green)
                           : spec.isImplementing ? ("play.circle", .accentColor) : ("circle", .secondary),
                       badge: tasks.isEmpty ? nil : "\(done)/\(tasks.count)", selected: selected)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }

    private func stateSymbol(_ status: SpecDocStatus) -> (String, Color) {
        switch status {
        case .missing: ("circle", .secondary)
        case .draft: ("pencil.circle", .orange)
        case .approved: ("checkmark.circle.fill", .green)
        case .changed: ("exclamationmark.circle", .orange)
        }
    }

    private func stepButton(_ step: Step, title: String, state: (String, Color), badge: String? = nil, selected: Step) -> some View {
        Button { chosenStep = step } label: {
            HStack(spacing: 4) {
                Image(systemName: state.0).foregroundStyle(state.1)
                Text(title).lineLimit(1)
                if let badge { Text(badge).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            }
            .font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(step == selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Documents

    @ViewBuilder
    private func document(_ phase: SpecPhase, of spec: Spec) -> some View {
        if let text = spec.documents[phase], spec.status(phase) != .missing {
            VStack(spacing: 0) {
                documentBar(phase, of: spec)
                Divider()
                ScrollView {
                    MarkdownBlocks(text: text).padding(12)
                }
            }
        } else {
            ContentUnavailableView {
                Label(String(localized: "\(phase.title): not written yet"), systemImage: phase.symbol)
            } description: {
                if let previous = phase.previous, !spec.canWrite(phase) {
                    Text("First approve: \(previous.title)")
                } else {
                    Text(explanation(phase))
                }
            } actions: {
                if spec.canWrite(phase) {
                    VStack(spacing: 8) {
                        Button("Let the agent write it") { write(phase, of: spec) }
                            .buttonStyle(.borderedProminent).disabled(!hasAgent)
                        if !hasAgent { agentHint }
                    }
                } else if let previous = phase.previous {
                    Button(String(localized: "Show \(previous.title)")) { chosenStep = .document(previous) }
                }
            }
        }
    }

    private func explanation(_ phase: SpecPhase) -> String {
        switch phase {
        case .requirements: String(localized: "User stories with acceptance criteria in EARS notation (WHEN … THEN the system SHALL …).")
        case .design: String(localized: "Architecture, components, data models, error handling and testing strategy, based on the approved requirements.")
        case .tasks: String(localized: "A checklist of small coding steps, each linked to the requirements it covers.")
        }
    }

    private func write(_ phase: SpecPhase, of spec: Spec) {
        let prompt = switch phase {
        case .requirements: SpecPrompts.requirements(spec, steering: steering)
        case .design: SpecPrompts.design(spec, steering: steering)
        case .tasks: SpecPrompts.tasks(spec, steering: steering)
        }
        ask(prompt)
    }

    private func documentBar(_ phase: SpecPhase, of spec: Spec) -> some View {
        let status = spec.status(phase)
        return HStack(spacing: 8) {
            switch status {
            case .approved: Label("Approved", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            case .changed: Label("Changed since approval", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            default: Label("Draft: review it", systemImage: "pencil").foregroundStyle(.orange)
            }
            Spacer()
            Button { model.editor.open(spec.url(phase)) } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless).help("Open in the editor")
            Button("Revise…") { feedback = ""; revising = true }
                .disabled(!hasAgent)
                .popover(isPresented: $revising, arrowEdge: .bottom) { revisePopover(phase, of: spec) }
            if status == .approved {
                Menu {
                    Button("Withdraw approval") {
                        do { update(try SpecLibrary.revokeApproval(phase, of: spec)) } catch { fail(error) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                if let next = phase.next, spec.status(next) == .missing {
                    Button(String(localized: "Write \(next.title)")) { write(next, of: spec); chosenStep = .document(next) }
                        .buttonStyle(.borderedProminent).disabled(!hasAgent)
                }
            } else {
                Button(approveTitle(phase)) { approve(phase, of: spec) }
                    .buttonStyle(.borderedProminent)
                    .help("Approve this version. If the next document is missing, the agent writes it.")
            }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func approveTitle(_ phase: SpecPhase) -> String {
        switch phase.next {
        case .some(let next): String(localized: "Approve → \(next.title)")
        case .none: String(localized: "Approve → Implementation")
        }
    }

    private func approve(_ phase: SpecPhase, of spec: Spec) {
        do {
            let approved = try SpecLibrary.approve(phase, of: spec)
            update(approved)
            if let next = phase.next {
                if approved.status(next) == .missing, hasAgent { write(next, of: approved) }
                chosenStep = .document(next)
            } else {
                chosenStep = .implementation
            }
        } catch { fail(error) }
    }

    private func revisePopover(_ phase: SpecPhase, of spec: Spec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What should the agent change? (\(phase.title))").font(.headline)
            TextEditor(text: $feedback)
                .font(.body)
                .frame(width: 340, height: 110)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel") { revising = false }.keyboardShortcut(.cancelAction)
                Button("Send to the agent") {
                    ask(SpecPrompts.revise(phase, of: spec, feedback: feedback, steering: steering))
                    revising = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    // MARK: Implementation

    @ViewBuilder
    private func implementation(_ spec: Spec) -> some View {
        if let pending = spec.currentPhase {
            ContentUnavailableView {
                Label("Not ready to implement", systemImage: "lock")
            } description: {
                Text("Implementation starts once requirements, design and tasks are approved.")
            } actions: {
                Button(String(localized: "Show \(pending.title)")) { chosenStep = .document(pending) }
            }
        } else {
            let tasks = spec.tasks
            VStack(spacing: 0) {
                implementationBar(spec, tasks: tasks)
                Divider()
                if tasks.isEmpty {
                    ContentUnavailableView("No tasks found", systemImage: "checklist",
                                           description: Text("tasks.md has no checkbox items (- [ ] 1. …)."))
                } else {
                    List(tasks) { task in taskRow(task, of: spec) }
                        .listStyle(.plain)
                }
            }
        }
    }

    private func nextTask(_ tasks: [SpecTask]) -> SpecTask? {
        tasks.first { !$0.done && $0.depth == 0 } ?? tasks.first { !$0.done }
    }

    private func implementationBar(_ spec: Spec, tasks: [SpecTask]) -> some View {
        let done = tasks.filter(\.done).count
        return HStack(spacing: 8) {
            ProgressView(value: Double(done), total: Double(max(tasks.count, 1)))
                .frame(maxWidth: 120)
            Text("\(done) of \(tasks.count) done").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            if spec.isComplete {
                Button("Check against the requirements") { ask(SpecPrompts.verify(spec, steering: steering)) }
                    .buttonStyle(.borderedProminent).disabled(!hasAgent)
            } else if let next = nextTask(tasks) {
                Menu {
                    Button("Run all open tasks") { ask(SpecPrompts.runRemaining(of: spec, steering: steering)) }
                } label: {
                    Text("Run task \(next.id)")
                } primaryAction: {
                    ask(SpecPrompts.run(next, of: spec, steering: steering))
                }
                .fixedSize()
                .disabled(!hasAgent)
                .help(next.title)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func taskRow(_ task: SpecTask, of spec: Spec) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                do {
                    try SpecLibrary.setTask(task, done: !task.done, in: spec)
                    reloadToken += 1
                } catch { fail(error) }
            } label: {
                Image(systemName: task.done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(task.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(task.done ? "Mark as open" : "Mark as done")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if !task.id.hasPrefix("L") {
                        Text(task.id).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(task.title)
                        .strikethrough(task.done, color: .secondary)
                        .foregroundStyle(task.done ? .secondary : .primary)
                }
                ForEach(Array(task.details.prefix(3).enumerated()), id: \.offset) { _, d in
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !task.requirements.isEmpty {
                    Text("Requirements: \(task.requirements.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if !task.done {
                Button { ask(SpecPrompts.run(task, of: spec, steering: steering)) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless).disabled(!hasAgent)
                    .help("Let the agent implement this task")
            }
        }
        .padding(.leading, CGFloat(task.depth) * 18)
        .padding(.vertical, 2)
    }

    // MARK: New spec

    private func startNewSpec() {
        newName = ""
        newIdea = ""
        showNewSpec = true
    }

    private var newSpecSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New spec").font(.title3.bold())
            TextField("Name, e.g. “Password reset”", text: $newName)
                .textFieldStyle(.roundedBorder)
            Text("What should the feature do, for whom, and what is out of scope?").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $newIdea)
                .font(.body)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            if !hasAgent { agentHint }
            HStack {
                Text("Saved in \(SpecLibrary.specsDir)/").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { showNewSpec = false }.keyboardShortcut(.cancelAction)
                Button(hasAgent ? "Create and write requirements" : "Create") { createSpec() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func createSpec() {
        do {
            let spec = try SpecLibrary.create(name: newName, idea: newIdea, root: root)
            showNewSpec = false
            specs = [spec] + (specs ?? [])
            selectedID = spec.id
            chosenStep = .document(.requirements)
            if hasAgent { ask(SpecPrompts.requirements(spec, steering: steering)) }
            reloadToken += 1
        } catch { fail(error) }
    }
}
