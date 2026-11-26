import SwiftUI
import AppKit

/// Running agents as cards in columns – needs you, working, done, idle – each with a timer.
/// Wide panes show the columns side by side, narrow ones stack them.
struct AgentBoardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themePalette) private var palette
    /// Switches the sessions area back to the list (ended sessions live there).
    var showList: () -> Void = {}

    static let symbol = "rectangle.split.3x1"

    enum Column: CaseIterable, Identifiable {
        case needsYou, working, done, idle
        var id: Self { self }

        var title: String {
            switch self {
            case .needsYou: String(localized: "Needs you")
            case .working: String(localized: "Working")
            case .done: String(localized: "Done")
            case .idle: String(localized: "Idle")
            }
        }
        var symbol: String {
            switch self {
            case .needsYou: "hand.raised.fill"
            case .working: "gearshape.2.fill"
            case .done: "checkmark.circle.fill"
            case .idle: "moon.zzz.fill"
            }
        }
        var color: Color {
            switch self {
            case .needsYou: .orange
            case .working: .blue
            case .done: .green
            case .idle: .secondary
            }
        }

        /// Which column a session belongs in; ended sessions without a result stay off the board.
        @MainActor static func of(_ run: AgentRun) -> Column? {
            switch run.status {
            case .needsInput, .blocked: .needsYou
            case .running: .working
            case .done: .done
            case .idle: run.isRunning ? .idle : nil
            case .inactive: nil
            }
        }
    }

    var body: some View {
        let runs = model.agents.runs.filter { $0.purpose == .session }
        let grouped = Dictionary(grouping: runs.compactMap { run in Column.of(run).map { ($0, run) } }, by: \.0)
            .mapValues { $0.map(\.1).sorted(by: Self.order) }
        let ended = runs.count - grouped.values.reduce(0) { $0 + $1.count }

        GeometryReader { geo in
            let wide = geo.size.width >= 620
            ScrollView(wide ? .horizontal : .vertical) {
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(Column.allCases) { column in
                                ScrollView(.vertical) { columnView(column, grouped[column] ?? []) }
                                    .frame(width: max(200, (geo.size.width - 50) / 4))
                            }
                        }
                    } else {
                        // Narrow: stacked, empty columns left out.
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Column.allCases.filter { grouped[$0] != nil }) { column in
                                columnView(column, grouped[column] ?? [])
                            }
                        }
                    }
                }
                .padding(10)
                .frame(minHeight: wide ? geo.size.height : nil, alignment: .top)
            }
        }
        .overlay(alignment: .bottom) {
            if runs.isEmpty {
                ContentUnavailableView {
                    Label("No agents", systemImage: Self.symbol)
                } description: {
                    Text("Started agents appear here as cards.")
                } actions: {
                    Button("Start agent…") { model.agents.startSheet = .init() }
                }
                .frame(maxHeight: .infinity)
            } else if ended > 0 {
                Button("Ended sessions in the list: \(ended)") { showList() }
                    .buttonStyle(.link).scaledFont(.caption).padding(8)
            }
        }
    }

    /// Longest waiting or working first: the oldest state is the one most likely forgotten.
    private static func order(_ a: AgentRun, _ b: AgentRun) -> Bool {
        if a.status == .done { return a.clock.statusSince > b.clock.statusSince }
        return a.clock.statusSince < b.clock.statusSince
    }

    private func columnView(_ column: Column, _ runs: [AgentRun]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: column.symbol).foregroundStyle(column.color)
                Text(column.title).scaledFont(.callout, bold: true)
                Text("\(runs.count)").scaledFont(.caption, digits: true).foregroundStyle(.secondary)
                Spacer()
            }
            if runs.isEmpty {
                Text("–").scaledFont(.caption).foregroundStyle(.tertiary).padding(.leading, 2)
            }
            ForEach(runs) { run in
                AgentCard(run: run, accent: column.color, selected: model.agents.selectedRunID == run.id) {
                    open(run)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Opens the session in the chat area; a maximized sessions area steps aside so the chat is visible.
    private func open(_ run: AgentRun) {
        if let id = model.layout.maximizedPane, model.layout.paneTree.pane(id)?.tab == .sessions {
            model.layout.maximizedPane = nil
        }
        model.selectRun(run.id)
        model.layout.show(.chat)
    }
}

private struct AgentCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themePalette) private var palette
    let run: AgentRun
    let accent: Color
    let selected: Bool
    let action: () -> Void
    private let hovering = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: run.kind.symbol).foregroundStyle(accent).frame(width: 16)
                    Text(run.title).scaledFont(.callout, bold: true).lineLimit(2)
                    Spacer(minLength: 4)
                    if run.status == .blocked { StatusBadge(status: run.status) }
                }
                HStack(spacing: 4) {
                    Text(run.folderName).lineLimit(1)
                    Spacer(minLength: 4)
                    TurnTimer(run: run).foregroundStyle(TurnTimer.isLive(run) ? accent : .secondary)
                }
                .scaledFont(.caption).foregroundStyle(.secondary)
                if let progress = run.progress, run.status == .running || run.status == .needsInput {
                    ProgressView(value: Double(progress), total: 100).controlSize(.small).tint(accent)
                }
                if let detail = run.detail ?? run.error {
                    Text(detail).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: palette?.pane ?? .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8).fill(accent).frame(width: 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hovering.wrappedValue ? 0.25 : 0.1),
                                  lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering.wrappedValue = $0 }
        .help(run.directory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        .contextMenu {
            if run.isRunning {
                Button { model.agents.stop(run) } label: { Label("End session", systemImage: "stop.circle") }
            }
            if run.status == .done {
                Button { model.agents.acknowledge(run) } label: { Label("Mark as seen", systemImage: "checkmark") }
            }
        }
    }
}

/// "working 3:07", "waiting 0:42" or "done after 4:10"; ticks every second while live.
struct TurnTimer: View {
    let run: AgentRun

    static func isLive(_ run: AgentRun) -> Bool {
        run.isRunning && (run.status == .running || run.status == .needsInput || run.status == .blocked)
    }

    var body: some View {
        if Self.isLive(run) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                label(now: context.date)
            }
        } else {
            label(now: Date())
        }
    }

    @ViewBuilder
    private func label(now: Date) -> some View {
        let clock = run.clock
        Group {
            switch run.status {
            case .running:
                Text("working \(TurnClock.format(now.timeIntervalSince(clock.turnStarted ?? clock.statusSince)))")
            case .needsInput, .blocked where run.isRunning:
                Text("waiting \(TurnClock.format(now.timeIntervalSince(clock.statusSince)))")
            case .blocked:
                Text(run.updated.formatted(.relative(presentation: .named)))
            case .done:
                if let last = clock.lastTurn {
                    Text("done after \(TurnClock.format(last))")
                } else {
                    Text(clock.statusSince.formatted(.relative(presentation: .named)))
                }
            case .idle, .inactive:
                Text(run.updated.formatted(.relative(presentation: .named)))
            }
        }
        .monospacedDigit()
        .lineLimit(1)
    }
}
