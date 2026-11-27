import SwiftUI

/// Spec-driven development: one feature at a time through requirements → design → tasks →
/// implementation. The agent writes each document, the user reviews and approves it here,
/// and only an approved document unlocks the next step. Each spec runs guided (one step at a
/// time, with a quality check and a review checklist) or free (everything at once).
struct SpecsView: View {
    @Environment(AppModel.self) private var model
    let root: String
    /// Snapshots: behave as if an agent session were running.
    private let previewAgent: Bool

    /// `preloaded` skips the first scan and shows `initialSpec` (snapshots).
    init(root: String, preloaded: [Spec]? = nil, initialSpec: String? = nil, previewAgent: Bool = false) {
        self.root = root
        self.previewAgent = previewAgent
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
    /// nil follows the spec's current step (free mode).
    @State private var chosenStep: Step?
    @State private var reloadToken = 0
    @State private var showNewSpec = false
    @State private var revising = false
    @State private var feedback = ""
    @State private var showFindings = false
    @State private var implementationTab = 0

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
        .sheet(isPresented: $showNewSpec) {
            NewSpecWizard(hasAgent: hasAgent, onCreate: createSpec, onCancel: { showNewSpec = false })
        }
    }

    /// A running session in this folder that receives the prompts.
    private var targetRun: AgentRun? {
        if let run = model.agents.selectedRun, run.isRunning, run.directory == root { return run }
        return model.agents.runs.first { $0.isRunning && $0.directory == root && $0.purpose == .session }
    }

    private var hasAgent: Bool { previewAgent || targetRun != nil }

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

    private func update(_ spec: Spec) {
        if let i = specs?.firstIndex(where: { $0.id == spec.id }) { specs?[i] = spec }
    }

    private func fail(_ error: Error) {
        model.banner = String(localized: "The spec could not be saved: \(error.localizedDescription)")
    }

    // MARK: Agent

    /// Sends a prompt to this folder's session and remembers what it is doing for the spec.
    private func send(_ prompt: String, for spec: Spec, label: String, phase: SpecPhase?, interview: Bool = false) {
        guard let run = targetRun else {
            model.banner = String(localized: "First select a running agent session on the left to receive the task.")
            return
        }
        if model.agents.selectedRunID != run.id { model.selectRun(run.id) }
        model.ask(prompt)
        model.specActivity.started(spec.id, runID: run.id, label: label, phase: phase,
                                   before: phase.flatMap { spec.documents[$0] }, interview: interview)
    }

    private func agentState(_ spec: Spec) -> SpecAgentState {
        guard let entry = model.specActivity.entries[spec.id], let run = model.agents.run(entry.runID), run.isRunning else { return .none }
        let changed = entry.phase.map { spec.documents[$0] != entry.before } ?? false
        switch run.status {
        case .running:
            return .working(entry.label, since: entry.started)
        case .needsInput, .blocked:
            return .needsYou(run.detail ?? entry.label)
        default:
            if entry.interview && !changed {
                return .needsYou(String(localized: "It asked you questions before writing the requirements."))
            }
            // Just sent: the agent hasn't reported that it started yet.
            if Date().timeIntervalSince(entry.started) < 6 { return .working(entry.label, since: entry.started) }
            return .none
        }
    }

    private func actions(_ spec: Spec) -> SpecActions {
        SpecActions(
            hasAgent: hasAgent,
            ask: { prompt, label, phase in send(prompt, for: spec, label: label, phase: phase) },
            write: { phase, clarify in write(phase, of: spec, clarify: clarify) },
            approve: { approve($0, of: spec) },
            revoke: { phase in
                do { update(try SpecLibrary.revokeApproval(phase, of: spec)) } catch { fail(error) }
            },
            revise: { phase, text in
                send(SpecPrompts.revise(phase, of: spec, feedback: text, steering: steering), for: spec,
                     label: String(localized: "The agent revises: \(phase.title)"), phase: phase)
            },
            fix: { fix($0, of: spec) },
            setTask: { task, done in
                do {
                    try SpecLibrary.setTask(task, done: done, in: spec)
                    reloadToken += 1
                } catch { fail(error) }
            },
            runTask: { task in
                send(SpecPrompts.run(task, of: spec, steering: steering), for: spec,
                     label: String(localized: "The agent implements task \(task.id)"), phase: nil)
            },
            runAll: {
                send(SpecPrompts.runRemaining(of: spec, steering: steering), for: spec,
                     label: String(localized: "The agent works through all open tasks"), phase: nil)
            },
            verify: {
                send(SpecPrompts.verify(spec, steering: steering), for: spec,
                     label: String(localized: "The agent checks the code against the requirements"), phase: nil)
            },
            record: { change in
                do { update(try SpecLibrary.update(spec, change)) } catch { fail(error) }
            },
            open: { model.editor.open(spec.url($0)) },
            showChat: {
                if let id = model.specActivity.entries[spec.id]?.runID ?? targetRun?.id { model.selectRun(id) }
                model.layout.show(.chat)
            },
            startAgent: { model.agents.startSheet = .init(directory: root) },
            newSpec: { showNewSpec = true })
    }

    private func write(_ phase: SpecPhase, of spec: Spec, clarify: Bool = false) {
        let prompt = switch phase {
        case .requirements: SpecPrompts.requirements(spec, steering: steering, clarify: clarify)
        case .design: SpecPrompts.design(spec, steering: steering)
        case .tasks: SpecPrompts.tasks(spec, steering: steering)
        }
        let label = switch phase {
        case .requirements: clarify ? String(localized: "The agent reads the code and prepares its questions")
                                    : String(localized: "The agent writes the requirements")
        case .design: String(localized: "The agent writes the design")
        case .tasks: String(localized: "The agent plans the tasks")
        }
        send(prompt, for: spec, label: label, phase: phase, interview: clarify)
    }

    private func fix(_ finding: SpecFinding, of spec: Spec) {
        if finding.answerQuestions {
            send(SpecPrompts.answerQuestions(spec, steering: steering), for: spec,
                 label: String(localized: "The agent goes through the open questions with you"), phase: .requirements, interview: true)
        } else if let text = finding.fix {
            send(SpecPrompts.fix(text, in: finding.phase, of: spec, steering: steering), for: spec,
                 label: String(localized: "The agent fixes: \(finding.message)"), phase: finding.phase)
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

    // MARK: Empty state

    private var empty: some View {
        VStack(spacing: 18) {
            Image(systemName: "flame.fill").font(.system(size: 46)).foregroundStyle(SpecStyle.fire)
            VStack(spacing: 6) {
                Text("Build it right, step by step").font(.title2.bold())
                Text("Describe a feature. The agent writes requirements, a design and a task list; you review and approve each one before it implements the tasks one by one.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            HStack(spacing: 22) {
                ForEach(Array(SpecPhase.allCases.enumerated()), id: \.offset) { i, phase in
                    VStack(spacing: 4) {
                        Image(systemName: phase.symbol).font(.title3).foregroundStyle(SpecStyle.fire)
                        Text("\(i + 1). \(phase.title)").font(.caption)
                    }
                }
                VStack(spacing: 4) {
                    Image(systemName: "hammer").font(.title3).foregroundStyle(SpecStyle.fire)
                    Text("4. \(String(localized: "Implementation"))").font(.caption)
                }
            }
            .padding(.vertical, 4)
            Button { showNewSpec = true } label: { Label("New spec…", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large)
            if steering.isEmpty {
                Button("Let the agent write steering documents") { model.ask(SpecPrompts.steering) }
                    .buttonStyle(.link).disabled(!hasAgent)
            }
            if !hasAgent { agentHint }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var agentHint: some View {
        Text("Start or select an agent session: it writes and implements the spec.")
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }

    // MARK: Spec

    @ViewBuilder
    private func content(_ spec: Spec, all: [Spec]) -> some View {
        VStack(spacing: 0) {
            header(spec, all: all)
            Divider()
            if spec.record.guided {
                SpecGuideView(spec: spec, agent: agentState(spec), actions: actions(spec))
                    .id(spec.id)
            } else {
                let step = chosenStep ?? spec.currentPhase.map(Step.document) ?? .implementation
                steps(spec, selected: step)
                Divider()
                switch step {
                case .document(let phase): document(phase, of: spec)
                case .implementation: implementation(spec)
                }
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
                HStack(spacing: 5) {
                    Image(systemName: spec.record.kind.symbol).foregroundStyle(SpecStyle.fire)
                    Text(spec.name).font(.callout.bold()).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(spec.relativePath)
            if all.count > 1 {
                Text("\(all.count)").font(.caption2).padding(.horizontal, 5).background(Color.primary.opacity(0.08), in: Capsule())
            }
            Spacer()
            Picker("Mode", selection: Binding(get: { spec.record.guided }, set: { guided in
                do { update(try SpecLibrary.update(spec) { $0.guided = guided }) } catch { fail(error) }
            })) {
                Image(systemName: "wand.and.stars").help("Guided: one step at a time").tag(true)
                Image(systemName: "slider.horizontal.3").help("Free: everything at once").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Guided or free")
            Button { showNewSpec = true } label: { Image(systemName: "plus") }
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
                    model.ask(SpecPrompts.steering)
                }
            } label: { Image(systemName: "signpost.right") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Steering: product, tech and structure notes every spec prompt refers to")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    // MARK: Free mode

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

    private func documentBar(_ phase: SpecPhase, of spec: Spec) -> some View {
        let status = spec.status(phase)
        let findings = SpecAnalysis.findings(spec).filter { $0.phase == phase }
        let issues = findings.filter { $0.severity == .issue }.count
        return HStack(spacing: 8) {
            switch status {
            case .approved: Label("Approved", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            case .changed: Label("Changed since approval", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            default: Label("Draft: review it", systemImage: "pencil").foregroundStyle(.orange)
            }
            Spacer()
            Button { showFindings = true } label: {
                Label(issues > 0 ? "\(issues)" : "OK", systemImage: "stethoscope")
                    .foregroundStyle(issues > 0 ? Color.orange : Color.green)
            }
            .buttonStyle(.borderless)
            .help("Quality check")
            .popover(isPresented: $showFindings, arrowEdge: .bottom) {
                SpecFindingsList(findings: findings, cleanSummary: String(localized: "Nothing to complain about."),
                                 canFix: hasAgent) { f in showFindings = false; fix(f, of: spec) }
                    .padding(14).frame(width: 380)
            }
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
                    actions(spec).revise(phase, feedback)
                    revising = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

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
                if implementationTab == 1 {
                    ScrollView {
                        let doc = spec.documents[.requirements].map(SpecAnalysis.requirements) ?? SpecRequirementsDoc()
                        SpecCoverageView(doc: doc, traces: SpecAnalysis.trace(doc, tasks: tasks)).padding(12)
                    }
                } else if tasks.isEmpty {
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
        let a = actions(spec)
        return HStack(spacing: 8) {
            ProgressView(value: Double(done), total: Double(max(tasks.count, 1)))
                .tint(SpecStyle.flame)
                .frame(maxWidth: 100)
            Text("\(done) of \(tasks.count) done").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Picker("", selection: $implementationTab) {
                Text("Tasks").tag(0)
                Text("Coverage").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            if spec.isComplete {
                Button("Check against the requirements") { a.verify() }
                    .buttonStyle(.borderedProminent).disabled(!hasAgent)
            } else if let next = nextTask(tasks) {
                Menu {
                    Button("Run all open tasks") { a.runAll() }
                } label: {
                    Text("Run task \(next.id)")
                } primaryAction: {
                    a.runTask(next)
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
                actions(spec).setTask(task, !task.done)
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
                Button { actions(spec).runTask(task) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless).disabled(!hasAgent)
                    .help("Let the agent implement this task")
            }
        }
        .padding(.leading, CGFloat(task.depth) * 18)
        .padding(.vertical, 2)
    }

    // MARK: New spec

    private func createSpec(_ r: NewSpecWizard.Result) {
        do {
            let spec = try SpecLibrary.create(name: r.name, idea: r.idea, kind: r.kind, guided: r.guided, root: root)
            showNewSpec = false
            specs = [spec] + (specs ?? [])
            selectedID = spec.id
            chosenStep = .document(.requirements)
            if hasAgent { write(.requirements, of: spec, clarify: r.clarify) }
            reloadToken += 1
        } catch { fail(error) }
    }
}
