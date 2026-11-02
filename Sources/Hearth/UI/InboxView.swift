import SwiftUI
import AppKit

/// Left column: every agent session, the ones that need attention first.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themePalette) private var palette
    private let onlyAttention = State(initialValue: false)

    var body: some View {
        let runs = model.agents.sorted
        let attention = runs.filter { $0.status.priority <= AgentStatus.done.priority }
        let shown = onlyAttention.wrappedValue ? attention : runs

        List(selection: Binding(
            get: { model.agents.selectedRunID.map { "run:" + $0 } },
            set: { id in
                if let id, id.hasPrefix("run:") { model.selectRun(String(id.dropFirst(4))) }
            })) {
            Section {
                if attention.isEmpty {
                    Text("All quiet – no agent is waiting.").foregroundStyle(.secondary).scaledFont(.callout)
                } else {
                    Text("\(attention.count) sessions with results, questions or errors.")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
                if !attention.isEmpty || onlyAttention.wrappedValue {
                    Button(onlyAttention.wrappedValue ? "Show all sessions" : "Show only these sessions") {
                        onlyAttention.wrappedValue.toggle()
                    }
                    .buttonStyle(.link).scaledFont(.caption)
                }
            } header: {
                Text(onlyAttention.wrappedValue ? String(localized: "Needs attention (\(attention.count)) · filtered") : String(localized: "Needs attention (\(attention.count))"))
                    .scaledFont(.caption, bold: true)
            }

            Section {
                if runs.isEmpty {
                    Button { model.agents.startSheet = .init() } label: {
                        Label("Start agent…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.link).scaledFont(.callout)
                }
                ForEach(shown) { run in
                    AgentRunRow(run: run).tag("run:" + run.id)
                }
            } header: {
                HStack {
                    Text("Agents (\(model.agents.runningCount) active)").scaledFont(.caption, bold: true)
                    Spacer()
                    Button { model.agents.startSheet = .init() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("Start agent")
                }
                .textCase(nil)
            }
        }
        .listStyle(.sidebar)
        // Opaque like every other pane; the sidebar style alone draws a translucent vibrancy material.
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: palette?.window ?? .windowBackgroundColor))
    }
}

struct StatusBadge: View {
    @Environment(\.textScale) private var scale
    let status: AgentStatus

    var color: Color {
        switch status {
        case .running: .blue
        case .needsInput: .orange
        case .blocked: .red
        case .done: .green
        case .idle, .inactive: .secondary
        }
    }

    var body: some View {
        Text(status.rawValue)
            .font(.system(size: 9 * scale, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}
