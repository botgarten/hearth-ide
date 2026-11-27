import SwiftUI

/// What the spec views can do; SpecsView owns the state and passes these down.
struct SpecActions {
    var hasAgent: Bool
    /// Sends a prompt and remembers it as the spec's current agent activity.
    var ask: (_ prompt: String, _ label: String, _ phase: SpecPhase?) -> Void
    var write: (SpecPhase, _ clarify: Bool) -> Void
    var approve: (SpecPhase) -> Void
    var revoke: (SpecPhase) -> Void
    var revise: (SpecPhase, String) -> Void
    var fix: (SpecFinding) -> Void
    var setTask: (SpecTask, Bool) -> Void
    var runTask: (SpecTask) -> Void
    var runAll: () -> Void
    var verify: () -> Void
    var record: ((inout SpecRecord) -> Void) -> Void
    var open: (SpecPhase) -> Void
    var showChat: () -> Void
    var startAgent: () -> Void
    var newSpec: () -> Void
}

/// What the agent is doing for this spec right now.
enum SpecAgentState: Equatable {
    case none
    case working(String, since: Date)
    case needsYou(String)
}

/// Guided mode: one station at a time, with exactly the next thing to do.
struct SpecGuideView: View {
    let spec: Spec
    let agent: SpecAgentState
    let actions: SpecActions

    /// Station the user looks at; nil follows the spec.
    @State private var viewing: Int?
    @State private var expanded = false
    @State private var revising = false
    @State private var feedback = ""
    @State private var clarify = true
    @State private var implementationTab = 0

    private var currentIndex: Int { spec.currentPhase.map { SpecPhase.allCases.firstIndex(of: $0)! } ?? 3 }
    private var shown: Int { viewing ?? currentIndex }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                JourneyRail(stations: stations, selected: shown) { i in
                    withAnimation(.easeOut(duration: 0.2)) { viewing = i == currentIndex ? nil : i }
                }
                .padding(.top, 4)
                stepHeader
                Group {
                    if shown < 3 {
                        documentStation(SpecPhase.allCases[shown])
                    } else {
                        implementationStation
                    }
                }
                .transition(.opacity)
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: currentIndex) { _, _ in
            withAnimation(.easeOut(duration: 0.25)) { viewing = nil; expanded = false }
        }
    }

    private var stations: [JourneyRail.Station] {
        var list = SpecPhase.allCases.enumerated().map { i, phase in
            let state: JourneyRail.StationState = switch spec.status(phase) {
            case .approved: .done
            case .changed: .attention
            default: i == currentIndex ? .current : .upcoming
            }
            return JourneyRail.Station(id: i, title: phase.title, symbol: phase.symbol, state: state)
        }
        list.append(JourneyRail.Station(id: 3, title: String(localized: "Implementation"), symbol: "hammer",
                                        state: spec.isComplete ? .done : currentIndex == 3 ? .current : .upcoming))
        return list
    }

    private var stepHeader: some View {
        let title = shown < 3 ? SpecPhase.allCases[shown].title : String(localized: "Implementation")
        return VStack(alignment: .leading, spacing: 4) {
            Text("Step \(shown + 1) of 4").font(.caption.weight(.semibold)).foregroundStyle(SpecStyle.fire)
            Text(title).font(.title2.bold())
            Text(stepPurpose(shown)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepPurpose(_ i: Int) -> String {
        switch i {
        case 0: String(localized: "What should the result do? User stories and testable acceptance criteria – the yardstick for everything that follows.")
        case 1: String(localized: "How will it be built? Architecture, interfaces, data and error handling, based on the approved requirements.")
        case 2: String(localized: "In which steps? Small coding tasks, each linked to the criteria it fulfils.")
        default: String(localized: "The agent works through the tasks one at a time, and you keep an eye on coverage.")
        }
    }

    // MARK: Agent activity

    @ViewBuilder
    private var agentCard: some View {
        switch agent {
        case .none: EmptyView()
        case .working(let label, let since):
            SpecCard(highlighted: true) {
                HStack(spacing: 12) {
                    Image(systemName: "flame.fill").font(.title2).foregroundStyle(SpecStyle.fire)
                        .symbolEffect(.pulse, options: .repeating)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).font(.headline)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text("Working for \(Self.duration(ctx.date.timeIntervalSince(since)))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Show chat") { actions.showChat() }
                }
            }
        case .needsYou(let label):
            SpecCard(highlighted: true) {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill").font(.title2).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The agent is waiting for you").font(.headline)
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Answer in the chat") { actions.showChat() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var agentBusy: Bool { agent != .none }

    // MARK: Documents

    @ViewBuilder
    private func documentStation(_ phase: SpecPhase) -> some View {
        let status = spec.status(phase)
        agentCard
        if status == .missing {
            if !agentBusy { startCard(phase) }
        } else {
            if status == .approved {
                approvedCard(phase)
            }
            qualityCard(phase)
            documentCard(phase)
            if status != .approved {
                checklistCard(phase)
                approveBar(phase)
            }
        }
    }

    private func startCard(_ phase: SpecPhase) -> some View {
        SpecCard(highlighted: spec.canWrite(phase)) {
            if spec.canWrite(phase) {
                Text("What you get").font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(deliverables(phase), id: \.self) { item in
                        Label(item, systemImage: "checkmark").font(.callout)
                    }
                }
                if phase == .requirements {
                    Toggle("Let the agent ask questions first", isOn: $clarify).toggleStyle(.switch).font(.callout)
                }
                HStack {
                    if actions.hasAgent {
                        Button { actions.write(phase, phase == .requirements && clarify) } label: {
                            Label(writeTitle(phase), systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    } else {
                        Button { actions.startAgent() } label: { Label("Start an agent…", systemImage: "play.circle") }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        Text("An agent session in this folder writes the documents.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let previous = phase.previous {
                Label("First approve: \(previous.title)", systemImage: "lock").font(.callout)
            }
        }
    }

    private func writeTitle(_ phase: SpecPhase) -> String {
        switch phase {
        case .requirements: clarify ? String(localized: "Start the interview") : String(localized: "Write the requirements")
        case .design: String(localized: "Write the design")
        case .tasks: String(localized: "Plan the tasks")
        }
    }

    private func deliverables(_ phase: SpecPhase) -> [String] {
        switch phase {
        case .requirements:
            switch spec.record.kind {
            case .feature: [String(localized: "User stories for everyone involved"),
                            String(localized: "Acceptance criteria in EARS notation, each testable"),
                            String(localized: "Edge cases, errors and open questions")]
            case .bugfix: [String(localized: "Current and expected behaviour, steps to reproduce"),
                           String(localized: "The suspected cause, from the code"),
                           String(localized: "Criteria for the fix and a regression guard")]
            case .refactor: [String(localized: "Goals, limits and what is out of scope"),
                             String(localized: "What must not change, as testable criteria"),
                             String(localized: "How unchanged behaviour is verified")]
            }
        case .design: [String(localized: "Architecture and components, with a diagram where it helps"),
                       String(localized: "Interfaces, data models and error handling"),
                       String(localized: "A testing strategy and how each requirement is met")]
        case .tasks: [String(localized: "Small coding steps in a sensible order"),
                      String(localized: "Each step linked to the criteria it covers"),
                      String(localized: "Tests as part of the plan")]
        }
    }

    private func approvedCard(_ phase: SpecPhase) -> some View {
        SpecCard {
            HStack {
                Label("Approved", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.headline)
                Spacer()
                Button("Withdraw approval") { actions.revoke(phase) }.controlSize(.small)
            }
        }
    }

    private func qualityCard(_ phase: SpecPhase) -> some View {
        let findings = SpecAnalysis.findings(spec).filter { $0.phase == phase }
        let issues = findings.filter { $0.severity == .issue }.count
        return SpecCard {
            HStack {
                Label("Quality check", systemImage: "stethoscope").font(.headline)
                Spacer()
                if issues > 0 {
                    Text("\(issues) to fix").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule()).foregroundStyle(.orange)
                } else {
                    Text("OK").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.green.opacity(0.18), in: Capsule()).foregroundStyle(.green)
                }
            }
            SpecFindingsList(findings: findings, cleanSummary: cleanSummary(phase), canFix: actions.hasAgent && !agentBusy,
                             onFix: actions.fix)
        }
    }

    private func cleanSummary(_ phase: SpecPhase) -> String {
        let doc = spec.documents[.requirements].map(SpecAnalysis.requirements) ?? SpecRequirementsDoc()
        switch phase {
        case .requirements:
            return String(localized: "\(doc.requirements.count) requirements, \(doc.criteria.count) criteria, all testable.")
        case .design:
            return String(localized: "Covers all the usual topics and every requirement.")
        case .tasks:
            return String(localized: "\(spec.tasks.count) tasks cover all \(doc.criteria.count) criteria.")
        }
    }

    private func documentCard(_ phase: SpecPhase) -> some View {
        SpecCard {
            HStack {
                Label(phase.fileName, systemImage: "doc.text").font(.headline.monospaced())
                if spec.status(phase) == .changed {
                    Text("changed since approval").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button { actions.open(phase) } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help("Open in the editor")
                Button("Revise…") { feedback = ""; revising = true }
                    .controlSize(.small).disabled(!actions.hasAgent || agentBusy)
                    .popover(isPresented: $revising, arrowEdge: .bottom) { revisePopover(phase) }
            }
            MarkdownBlocks(text: spec.documents[phase] ?? "")
                .frame(maxHeight: expanded ? nil : 260, alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: expanded ? 1 : 0.72),
                                           .init(color: .black.opacity(expanded ? 1 : 0), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
            Button(expanded ? String(localized: "Show less") : String(localized: "Read the whole document")) {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            }
            .buttonStyle(.link)
        }
    }

    private func revisePopover(_ phase: SpecPhase) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What should the agent change? (\(phase.title))").font(.headline)
            TextEditor(text: $feedback)
                .font(.body).frame(width: 340, height: 110)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel") { revising = false }.keyboardShortcut(.cancelAction)
                Button("Send to the agent") {
                    actions.revise(phase, feedback)
                    revising = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func checked(_ phase: SpecPhase) -> Set<Int> { Set(spec.record.checks[phase.rawValue] ?? []) }

    private func checklistCard(_ phase: SpecPhase) -> some View {
        let items = SpecAnalysis.checklist(phase, kind: spec.record.kind)
        let ticked = checked(phase)
        return SpecCard {
            HStack {
                Label("Your review", systemImage: "eye").font(.headline)
                Spacer()
                Text("\(ticked.intersection(0..<items.count).count) of \(items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Button {
                    actions.record { r in
                        var set = Set(r.checks[phase.rawValue] ?? [])
                        if set.contains(i) { set.remove(i) } else { set.insert(i) }
                        r.checks[phase.rawValue] = set.sorted()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: ticked.contains(i) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(ticked.contains(i) ? AnyShapeStyle(SpecStyle.fire) : AnyShapeStyle(Color.secondary))
                            .font(.body)
                        Text(item).font(.callout).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func approveBar(_ phase: SpecPhase) -> some View {
        let items = SpecAnalysis.checklist(phase, kind: spec.record.kind).count
        let ready = checked(phase).intersection(0..<items).count == items
        let issues = SpecAnalysis.findings(spec).filter { $0.phase == phase && $0.severity == .issue }.count
        let next = phase.next.map(\.title) ?? String(localized: "Implementation")
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if !ready {
                    Text("Tick off your review first.").font(.caption).foregroundStyle(.secondary)
                } else if issues > 0 {
                    Text("\(issues) findings are still open – you can approve anyway.").font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Looks good. Next: \(next).").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { actions.approve(phase) } label: {
                Label(String(localized: "Approve, then \(next)"), systemImage: "checkmark.seal")
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!ready)
        }
        .padding(.top, 2)
    }

    // MARK: Implementation

    @ViewBuilder
    private var implementationStation: some View {
        if let pending = spec.currentPhase {
            SpecCard {
                Label("First approve: \(pending.title)", systemImage: "lock").font(.callout)
            }
        } else if spec.isComplete && agent == .none {
            celebration
            coverageCard
        } else {
            agentCard
            progressCard
            if !agentBusy, let next = nextTask { nextTaskCard(next) }
            Picker("", selection: $implementationTab) {
                Text("Tasks").tag(0)
                Text("Coverage").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
            if implementationTab == 0 { tasksCard } else { coverageCard }
        }
    }

    private var traces: (SpecRequirementsDoc, [SpecTrace]) {
        let doc = spec.documents[.requirements].map(SpecAnalysis.requirements) ?? SpecRequirementsDoc()
        return (doc, SpecAnalysis.trace(doc, tasks: spec.tasks))
    }

    private var nextTask: SpecTask? {
        let tasks = spec.tasks
        return tasks.first { !$0.done && $0.depth == 0 } ?? tasks.first { !$0.done }
    }

    private var progressCard: some View {
        let tasks = spec.tasks
        let done = tasks.filter(\.done).count
        let (_, t) = traces
        let implemented = t.filter { $0.state == .done }.count
        return SpecCard {
            HStack(spacing: 18) {
                ZStack {
                    FireRing(value: tasks.isEmpty ? 0 : Double(done) / Double(tasks.count))
                    VStack(spacing: 0) {
                        Text("\(tasks.isEmpty ? 0 : done * 100 / tasks.count)%").font(.title3.bold().monospacedDigit())
                        Text("done").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 78, height: 78)
                VStack(alignment: .leading, spacing: 6) {
                    stat("\(done)/\(tasks.count)", String(localized: "tasks done"))
                    stat("\(implemented)/\(t.count)", String(localized: "acceptance criteria implemented"))
                }
                Spacer()
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func nextTaskCard(_ task: SpecTask) -> some View {
        SpecCard(highlighted: true) {
            Text("Up next").font(.caption.weight(.semibold)).foregroundStyle(SpecStyle.fire)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !task.id.hasPrefix("L") { Text(task.id).font(.headline.monospacedDigit()).foregroundStyle(.secondary) }
                Text(task.title).font(.headline)
            }
            ForEach(Array(task.details.prefix(3).enumerated()), id: \.offset) { _, d in
                Text(d).font(.callout).foregroundStyle(.secondary)
            }
            if !task.requirements.isEmpty {
                HStack(spacing: 4) {
                    Text("Fulfils").font(.caption).foregroundStyle(.secondary)
                    ForEach(task.requirements, id: \.self) { r in
                        Text(r).font(.caption2.monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(SpecStyle.flame.opacity(0.15), in: Capsule())
                    }
                }
            }
            HStack {
                if actions.hasAgent {
                    Button { actions.runTask(task) } label: { Label("Start this task", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Run all open tasks") { actions.runAll() }
                } else {
                    Button { actions.startAgent() } label: { Label("Start an agent…", systemImage: "play.circle") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var tasksCard: some View {
        SpecCard {
            ForEach(spec.tasks) { task in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button { actions.setTask(task, !task.done) } label: {
                        Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(task.done ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color.secondary))
                    }
                    .buttonStyle(.plain)
                    if !task.id.hasPrefix("L") {
                        Text(task.id).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(task.title).font(.callout)
                        .strikethrough(task.done, color: .secondary)
                        .foregroundStyle(task.done ? .secondary : .primary)
                    Spacer(minLength: 0)
                    if !task.done, actions.hasAgent, !agentBusy {
                        Button { actions.runTask(task) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless).help("Let the agent implement this task")
                    }
                }
                .padding(.leading, CGFloat(task.depth) * 18)
            }
        }
    }

    private var coverageCard: some View {
        let (doc, t) = traces
        return SpecCard { SpecCoverageView(doc: doc, traces: t) }
    }

    private var celebration: some View {
        let (doc, _) = traces
        let days = max(1, Int(ceil(Date().timeIntervalSince(spec.record.created) / 86_400)))
        return SpecCard(highlighted: true) {
            VStack(spacing: 10) {
                Image(systemName: "flame.fill").font(.system(size: 44)).foregroundStyle(SpecStyle.fire)
                    .symbolEffect(.bounce, value: spec.isComplete)
                Text("Spec implemented").font(.title2.bold())
                Text("\(doc.requirements.count) requirements · \(doc.criteria.count) criteria · \(spec.tasks.count) tasks · \(days) days")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                HStack {
                    Button { actions.verify() } label: { Label("Check against the requirements", systemImage: "checkmark.shield") }
                        .buttonStyle(.borderedProminent).disabled(!actions.hasAgent)
                    Button("New spec…") { actions.newSpec() }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
