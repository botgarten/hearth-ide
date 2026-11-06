import SwiftUI

/// Tree of an agent session's steps, decisions and questions ("Anti-Burnout"): the overview
/// the user reads instead of the agent's whole output. Entries can be revoked.
struct JournalView: View {
    @Environment(AppModel.self) private var model
    let run: AgentRun

    enum Filter: String, CaseIterable, Identifiable {
        case all, steps, decisions, open
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .steps: String(localized: "Steps")
            case .decisions: String(localized: "Decisions")
            case .open: String(localized: "Open")
            }
        }
    }

    @AppStorage(JournalSupport.enabledKey) private var enabled = true
    @State private var filter = Filter.all
    @State private var collapsed = Set<String>()
    @State private var details = Set<String>()
    @State private var revoking: String?
    @State private var reason = ""

    private var journal: Journal { run.journal }

    var body: some View {
        VStack(spacing: 0) {
            if !enabled { disabled } else if journal.isEmpty { empty } else { content }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var disabled: some View {
        ContentUnavailableView {
            Label("Overview is turned off", systemImage: "list.bullet.indent")
        } description: {
            Text("Agents started while it is off do not get the journal command.")
        } actions: {
            Button("Turn on") { enabled = true }.buttonStyle(.borderedProminent)
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No history yet", systemImage: "list.bullet.indent")
        } description: {
            Text("Steps and decisions the agent records with hearth-journal appear here as a tree.")
        } actions: {
            if run.isRunning {
                Button("Ask the agent to record its work") { model.ask(JournalSupport.instruction) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Segmented control when there is room, a compact menu in narrow panes.
                ViewThatFits(in: .horizontal) {
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer(minLength: 0)
                Button { collapsed = collapsed.isEmpty ? Set(journal.nodeIDs) : [] } label: {
                    Image(systemName: collapsed.isEmpty ? "chevron.up.chevron.down" : "chevron.down.chevron.up")
                }
                .buttonStyle(.borderless)
                .help(collapsed.isEmpty ? String(localized: "Collapse all") : String(localized: "Expand all"))
            }
            .padding(8)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows(), id: \.node.id) { row in
                        nodeRow(row)
                        if details.contains(row.node.id) { detail(row.node, depth: row.depth) }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: Rows

    private struct Row { let node: JournalNode; let depth: Int }

    private func rows() -> [Row] {
        var result: [Row] = []
        func visit(_ parent: String?, _ depth: Int) {
            for node in journal.children(of: parent) where matches(node) {
                result.append(Row(node: node, depth: depth))
                if !collapsed.contains(node.id) { visit(node.id, depth + 1) }
            }
        }
        visit(nil, 0)
        return result
    }

    private func matches(_ node: JournalNode) -> Bool {
        let own: Bool = switch filter {
        case .all: true
        case .steps: node.kind == .step
        case .decisions: node.kind == .decision
        case .open: node.revoked == nil && (node.status == .open || node.status == .blocked || node.status == .running)
        }
        return own || journal.children(of: node.id).contains(where: matches)
    }

    private func nodeRow(_ row: Row) -> some View {
        let node = row.node
        let hasChildren = !journal.children(of: node.id).isEmpty
        let isCurrent = journal.currentID == node.id
        return HStack(spacing: 6) {
            Group {
                if hasChildren {
                    Button { toggle(node.id) } label: {
                        Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .frame(width: 14)
                    }.buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 14)
                }
            }
            icon(node)
            Text(node.title)
                .fontWeight(node.kind == .step && node.status == .running ? .semibold : .regular)
                .strikethrough(node.revoked != nil)
                .foregroundStyle(node.revoked != nil ? .secondary : .primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            if let label = statusLabel(node) {
                Text(label).font(.caption).foregroundStyle(statusColor(node)).lineLimit(1)
            }
            if isCurrent {
                Label("current", systemImage: "location.fill")
                    .font(.caption).foregroundStyle(.tint).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.12), in: Capsule())
            }
            if collapsed.contains(node.id), journal.openCount(below: node.id) > 0 {
                Text("\(journal.openCount(below: node.id)) open")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer(minLength: 4)
            Button { toggleDetail(node.id) } label: {
                Image(systemName: details.contains(node.id) ? "info.circle.fill" : "info.circle")
                    .foregroundStyle(details.contains(node.id) ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Details"))
        }
        .padding(.leading, 10 + CGFloat(row.depth) * 18)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func icon(_ node: JournalNode) -> some View {
        if node.revoked != nil {
            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
        } else {
            switch node.kind {
            case .step:
                switch node.status {
                case .running: Image(systemName: "circle.inset.filled").foregroundStyle(.blue)
                case .done: Image(systemName: "checkmark.circle").foregroundStyle(.green)
                case .blocked: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                default: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                }
            case .decision:
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.purple)
            case .question:
                Image(systemName: node.status == .answered ? "lightbulb" : "questionmark.circle")
                    .foregroundStyle(node.status == .answered ? Color.teal : Color.orange)
            }
        }
    }

    private func statusLabel(_ node: JournalNode) -> String? {
        if node.revoked != nil { return String(localized: "revoked") }
        switch (node.kind, node.status) {
        case (.step, .running): return String(localized: "running")
        case (.step, .done): return String(localized: "done")
        case (.step, .blocked): return String(localized: "blocked")
        case (.question, .open): return String(localized: "open")
        case (.question, .answered): return String(localized: "answered")
        default: return nil
        }
    }

    private func statusColor(_ node: JournalNode) -> Color {
        if node.revoked != nil { return .purple }
        switch node.status {
        case .running: return .blue
        case .done, .answered: return .green
        case .blocked, .open: return .orange
        case .planned: return .secondary
        }
    }

    // MARK: Detail card

    private func detail(_ node: JournalNode, depth: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(cardTitle(node))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let why = node.why { field(String(localized: "Reasoning"), why) }
            if !node.rejected.isEmpty {
                field(String(localized: "Rejected alternatives"), node.rejected.map { "– " + $0 }.joined(separator: "\n"))
            }
            if let answer = node.answer { field(String(localized: "Answer"), answer) }
            if let revoked = node.revoked {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Revoked", systemImage: "arrow.uturn.backward").font(.caption.weight(.semibold))
                    if !revoked.reason.isEmpty { Text(revoked.reason).font(.callout) }
                    if let by = revoked.replacedBy, let replacement = journal.node(by) {
                        Text("Replaced by \(replacement.title)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.purple)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            } else if revoking == node.id {
                revokeForm(node)
            } else {
                Button { revoking = node.id; reason = "" } label: { Label("Revoke…", systemImage: "arrow.uturn.backward") }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        .padding(.leading, 34 + CGFloat(depth) * 18)
        .padding(.trailing, 10)
        .padding(.bottom, 6)
    }

    private func cardTitle(_ node: JournalNode) -> String {
        let kind: String = switch node.kind {
        case .step: String(localized: "Step")
        case .decision: String(localized: "Decision")
        case .question: String(localized: "Question")
        }
        return "\(kind) · \(journal.path(of: node.id))"
    }

    private func field(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled)
        }
    }

    private func revokeForm(_ node: JournalNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Why? (optional)", text: $reason, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onSubmit { commitRevoke(node) }
            HStack {
                Button("Revoke and tell the agent") { commitRevoke(node) }
                    .controlSize(.small)
                    .disabled(!run.isRunning)
                    .help(run.isRunning ? "" : String(localized: "The session is not running."))
                Button("Cancel") { revoking = nil }.controlSize(.small)
            }
        }
    }

    private func commitRevoke(_ node: JournalNode) {
        model.agents.revoke(run, id: node.id, reason: reason)
        revoking = nil
        reason = ""
    }

    private func toggle(_ id: String) {
        if !collapsed.insert(id).inserted { collapsed.remove(id) }
    }

    private func toggleDetail(_ id: String) {
        if !details.insert(id).inserted { details.remove(id) }
    }
}
