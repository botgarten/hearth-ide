import SwiftUI

/// Hearth's fire colours for the spec journey (same as the brand: ember → flame).
enum SpecStyle {
    static let ember = Color(red: 1, green: 0.353, blue: 0.122)
    static let flame = Color(red: 1, green: 0.651, blue: 0.169)
    static let fire = LinearGradient(colors: [ember, flame], startPoint: .bottomLeading, endPoint: .topTrailing)
}

/// A soft card used throughout the guided spec view.
struct SpecCard<Content: View>: View {
    var highlighted = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(highlighted ? AnyShapeStyle(SpecStyle.fire.opacity(0.7)) : AnyShapeStyle(Color.primary.opacity(0.08)),
                                  lineWidth: highlighted ? 1.5 : 1)
            }
    }
}

// MARK: Journey

/// Requirements → Design → Tasks → Implementation as stations on a line of fire.
struct JourneyRail: View {
    enum StationState: Equatable { case done, current, upcoming, attention }

    struct Station: Identifiable {
        let id: Int
        let title: String
        let symbol: String
        let state: StationState
    }

    let stations: [Station]
    let selected: Int
    let onSelect: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(stations) { station in
                Button { onSelect(station.id) } label: {
                    VStack(spacing: 6) {
                        node(station)
                        Text(station.title)
                            .font(.caption.weight(station.id == selected ? .semibold : .regular))
                            .foregroundStyle(station.state == .upcoming ? .secondary : .primary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(minWidth: 64)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(station.title))
                if station.id < stations.count - 1 {
                    connector(lit: station.state == .done)
                        .padding(.top, 14)
                }
            }
        }
        .onAppear { if !reduceMotion { pulse = true } }
    }

    private func connector(lit: Bool) -> some View {
        Capsule()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                Capsule().fill(SpecStyle.fire).scaleEffect(x: lit ? 1 : 0, anchor: .leading)
                    .animation(.easeOut(duration: 0.6), value: lit)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, -6)
    }

    @ViewBuilder
    private func node(_ s: Station) -> some View {
        let size: CGFloat = 30
        ZStack {
            switch s.state {
            case .done:
                Circle().fill(SpecStyle.fire)
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            case .current:
                Circle()
                    .stroke(SpecStyle.flame.opacity(0.55), lineWidth: 2)
                    .scaleEffect(pulse ? 1.55 : 1)
                    .opacity(pulse ? 0 : 0.9)
                    .animation(reduceMotion ? nil : .easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
                Circle().fill(SpecStyle.flame.opacity(0.16))
                Circle().strokeBorder(SpecStyle.fire, lineWidth: 2)
                Image(systemName: s.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(SpecStyle.fire)
            case .attention:
                Circle().fill(Color.orange.opacity(0.15))
                Circle().strokeBorder(Color.orange, lineWidth: 2)
                Image(systemName: "exclamationmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.orange)
            case .upcoming:
                Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1.5)
                Image(systemName: s.symbol).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if s.id == selected && s.state != .current {
                Circle().strokeBorder(SpecStyle.flame.opacity(0.6), lineWidth: 1).padding(-4)
            }
        }
    }
}

/// Progress as a ring of fire.
struct FireRing: View {
    let value: Double
    var lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(AngularGradient(colors: [SpecStyle.ember, SpecStyle.flame, SpecStyle.ember], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.8), value: value)
        }
    }
}

// MARK: Quality check

struct SpecFindingsList: View {
    let findings: [SpecFinding]
    /// Summary when nothing was found, e.g. "4 requirements, 11 criteria, all testable."
    let cleanSummary: String
    let canFix: Bool
    let onFix: (SpecFinding) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if findings.isEmpty {
                Label {
                    Text(cleanSummary)
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
                .font(.callout)
            }
            ForEach(findings) { f in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: f.severity == .issue ? "exclamationmark.triangle.fill" : "lightbulb")
                        .foregroundStyle(f.severity == .issue ? Color.orange : Color.secondary)
                    Text(f.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if f.fix != nil || f.answerQuestions {
                        Button(f.answerQuestions ? String(localized: "Answer") : String(localized: "Let the agent fix it")) { onFix(f) }
                            .controlSize(.small)
                            .disabled(!canFix)
                    }
                }
            }
        }
    }
}

// MARK: Coverage

/// Every acceptance criterion with the tasks that cover it and how far they are.
struct SpecCoverageView: View {
    let doc: SpecRequirementsDoc
    let traces: [SpecTrace]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            if doc.requirements.isEmpty {
                Text("No acceptance criteria found in requirements.md.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(doc.requirements) { req in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(req.id).font(.caption.monospacedDigit().bold()).foregroundStyle(.secondary)
                        Text(req.title.isEmpty ? String(localized: "Requirement \(req.id)") : req.title).font(.callout.bold()).lineLimit(2)
                    }
                    ForEach(req.criteria) { c in
                        if let t = traces.first(where: { $0.id == c.id }) { row(t) }
                    }
                }
            }
        }
    }

    private var summary: some View {
        let total = max(traces.count, 1)
        let covered = traces.filter { $0.state != .uncovered }.count
        let done = traces.filter { $0.state == .done }.count
        return VStack(alignment: .leading, spacing: 6) {
            bar(String(localized: "Planned"), covered, of: traces.count, fraction: Double(covered) / Double(total))
            bar(String(localized: "Implemented"), done, of: traces.count, fraction: Double(done) / Double(total))
        }
    }

    private func bar(_ title: String, _ n: Int, of total: Int, fraction: Double) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 90, alignment: .leading)
            Capsule().fill(Color.primary.opacity(0.08)).frame(height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(SpecStyle.fire).scaleEffect(x: fraction, anchor: .leading)
                        .animation(.easeOut(duration: 0.6), value: fraction)
                }
            Text("\(n)/\(total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
    }

    private func row(_ t: SpecTrace) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol(t.state)).foregroundStyle(color(t.state)).frame(width: 14)
            Text(t.id).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            Text(t.criterion.text).font(.caption).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                if t.tasks.isEmpty {
                    Text("no task").font(.caption2).foregroundStyle(.orange)
                }
                ForEach(t.tasks.prefix(4)) { task in
                    Text(task.id.hasPrefix("L") ? "•" : task.id)
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(task.done ? Color.green.opacity(0.18) : Color.primary.opacity(0.07), in: Capsule())
                        .help(task.title)
                }
            }
        }
        .padding(.leading, 4)
    }

    private func symbol(_ s: SpecTraceState) -> String {
        switch s {
        case .uncovered: "circle.dashed"
        case .planned: "circle"
        case .partial: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }

    private func color(_ s: SpecTraceState) -> Color {
        switch s {
        case .uncovered: .orange
        case .planned: .secondary
        case .partial: SpecStyle.flame
        case .done: .green
        }
    }
}

// MARK: New spec wizard

/// Idea → kind → way of working, one page at a time.
struct NewSpecWizard: View {
    struct Result {
        var name: String
        var idea: String
        var kind: SpecKind
        var guided: Bool
        var clarify: Bool
    }

    let hasAgent: Bool
    let onCreate: (Result) -> Void
    let onCancel: () -> Void

    @State private var page = 0
    @State private var name = ""
    @State private var idea = ""
    @State private var kind: SpecKind = .feature
    @State private var guided = true
    @State private var clarify = true
    @FocusState private var nameFocused: Bool

    private var nameOK: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "flame.fill").font(.title2).foregroundStyle(SpecStyle.fire)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New spec").font(.title3.bold())
                    Text(pageSubtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    ForEach(0..<3) { i in
                        Capsule().fill(i <= page ? AnyShapeStyle(SpecStyle.fire) : AnyShapeStyle(Color.primary.opacity(0.15)))
                            .frame(width: i == page ? 18 : 7, height: 7)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: page)
            }
            Group {
                switch page {
                case 0: ideaPage
                case 1: kindPage
                default: modePage
                }
            }
            .frame(minHeight: 230, alignment: .top)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            HStack {
                Text("Saved in \(SpecLibrary.specsDir)/").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                if page > 0 { Button("Back") { withAnimation { page -= 1 } } }
                if page < 2 {
                    Button("Next") { withAnimation { page += 1 } }
                        .keyboardShortcut(.defaultAction).disabled(!nameOK)
                } else {
                    Button(hasAgent ? (clarify ? String(localized: "Create and start the interview") : String(localized: "Create and write requirements"))
                                    : String(localized: "Create")) {
                        onCreate(Result(name: name, idea: idea, kind: kind, guided: guided, clarify: clarify))
                    }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!nameOK)
                }
            }
        }
        .padding(22)
        .frame(width: 540)
        .clipped()
        .onAppear { nameFocused = true }
    }

    private var pageSubtitle: String {
        switch page {
        case 0: String(localized: "What do you want to build?")
        case 1: String(localized: "What kind of change is it?")
        default: String(localized: "How do you want to work?")
        }
    }

    private var ideaPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name, e.g. “Password reset”", text: $name)
                .textFieldStyle(.roundedBorder).font(.title3).focused($nameFocused)
            Text("Describe the idea: what should happen, for whom, and what is out of scope. A few sentences are enough – the agent asks if something is unclear.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $idea)
                .font(.body).frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        }
    }

    private var kindPage: some View {
        VStack(spacing: 8) {
            ForEach(SpecKind.allCases) { k in
                choice(selected: kind == k, symbol: k.symbol, title: k.title, text: k.summary) { kind = k }
            }
        }
    }

    private var modePage: some View {
        VStack(alignment: .leading, spacing: 8) {
            choice(selected: guided, symbol: "wand.and.stars", title: String(localized: "Guided"),
                   text: String(localized: "One step at a time: Hearth says what comes next, checks each document and asks you to review it before you approve.")) { guided = true }
            choice(selected: !guided, symbol: "slider.horizontal.3", title: String(localized: "Free"),
                   text: String(localized: "All documents and actions at once; you decide the order. You can switch at any time.")) { guided = false }
            Toggle(isOn: $clarify) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Let the agent ask questions first")
                    Text("It looks at the code and asks up to five questions before it writes the requirements.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch).padding(.top, 6)
            if !hasAgent {
                Label("Start or select an agent session: it writes and implements the spec.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func choice(selected: Bool, symbol: String, title: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.title3)
                    .foregroundStyle(selected ? AnyShapeStyle(SpecStyle.fire) : AnyShapeStyle(Color.secondary))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(SpecStyle.fire) : AnyShapeStyle(Color.secondary.opacity(0.5)))
            }
            .padding(12)
            .background(selected ? SpecStyle.flame.opacity(0.08) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? AnyShapeStyle(SpecStyle.fire) : AnyShapeStyle(Color.primary.opacity(0.08)),
                                                                     lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
