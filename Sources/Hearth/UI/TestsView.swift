import SwiftUI

struct TestsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var scale
    let root: String

    private let report = State(initialValue: TestReport?.none)
    private let onlyFailures = State(initialValue: false)
    private let filter = State(initialValue: "")
    private let expandedSuites = State(initialValue: Set<String>())
    private let expandedCases = State(initialValue: Set<String>())

    static var runPrompt: String { String(localized: """
    Run this project's tests (e.g. `mvn -q verify`, `./gradlew test` or \
    `go test -coverprofile=coverage.out ./...`) and make sure JUnit XML reports or \
    coverage files are written. Then briefly summarise what fails.
    """) }

    var body: some View {
        VStack(spacing: 0) {
            if let r = report.wrappedValue {
                if r.isEmpty { empty } else { content(r) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(root)#\(model.workspace.settledRevision)") { await reload() }
        .onChange(of: model.workspace.testFocus) { _, focus in reveal(focus) }
        .onAppear { reveal(model.workspace.testFocus) }
    }

    /// A test picked in Search Everywhere: filter to it and open its suite and details.
    private func reveal(_ focus: WorkspaceState.TestFocus?) {
        guard let focus else { return }
        filter.wrappedValue = focus.name
        onlyFailures.wrappedValue = false
        if let suite = report.wrappedValue?.suites.first(where: { $0.cases.contains { $0.id == focus.id } }) {
            // Expanded = "toggled" XOR "has failures" (failing suites start open).
            if suite.failed > 0 { expandedSuites.wrappedValue.remove(suite.id) } else { expandedSuites.wrappedValue.insert(suite.id) }
        }
        expandedCases.wrappedValue.insert(focus.id)
        // Keep the request until the report is there (the pane may have just been opened).
        if report.wrappedValue != nil { model.workspace.testFocus = nil }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No test results", systemImage: "checkmark.seal")
        } description: {
            Text("Looks for JUnit XML (Surefire, Gradle, Jest, pytest …), JaCoCo, Cobertura, lcov and Go cover profiles.")
        } actions: {
            Button("Let the agent run the tests") { model.ask(Self.runPrompt) }
                .buttonStyle(.borderedProminent)
            Button("Rescan") { Task { await reload() } }
        }
    }

    private func content(_ r: TestReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                summary(r)
                HStack(spacing: 6) {
                    Toggle("Failures only", isOn: onlyFailures.projectedValue).toggleStyle(.checkbox).scaledFont(.caption)
                    SearchField(text: filter.projectedValue, prompt: "Test filtern")
                }
                ForEach(visibleSuites(r)) { suite in suiteView(suite) }
            }
            .padding(8)
        }
    }

    // MARK: Summary

    private func summary(_ r: TestReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: r.failed > 0 ? "xmark.octagon.fill" : "checkmark.seal.fill")
                    .scaledFont(.title2).foregroundStyle(r.failed > 0 ? .red : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.cases.isEmpty ? "Coverage only" : "\(r.passed)/\(r.passed + r.failed) passed")
                        .scaledFont(.headline)
                    if let d = r.newest {
                        Text("As of \(d.formatted(.relative(presentation: .named)))").scaledFont(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Rescan")
                Button("Let the agent run them") { model.ask(Self.runPrompt) }
                    .controlSize(.small).help("The agent runs the tests in the sandbox")
            }
            if !r.cases.isEmpty {
                HStack(spacing: 12) {
                    stat("\(r.passed)", "passed", .green)
                    stat("\(r.failed)", "failed", r.failed > 0 ? .red : .secondary)
                    stat("\(r.skipped)", String(localized: "skipped"), .secondary)
                }
            }
            ForEach(r.coverage, id: \.source) { c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Coverage").scaledFont(.caption, bold: true)
                        Text(c.source).scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Text(String(format: "%.1f %%", c.percent)).scaledFont(.caption, bold: true, digits: true)
                    }
                    ProgressView(value: c.percent, total: 100)
                        .tint(c.percent >= 80 ? .green : (c.percent >= 50 ? .orange : .red))
                }
                .help("\(c.covered) of \(c.total) lines/statements covered")
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(value).scaledFont(.callout, bold: true, digits: true).foregroundStyle(color)
            Text(label).scaledFont(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Suites & cases

    private func visibleSuites(_ r: TestReport) -> [TestSuite] {
        let q = filter.wrappedValue.lowercased()
        return r.suites.compactMap { suite in
            var s = suite
            s.cases = suite.cases.filter { c in
                (!onlyFailures.wrappedValue || c.outcome == .failed || c.outcome == .error)
                    && (q.isEmpty || c.name.lowercased().contains(q) || suite.name.lowercased().contains(q))
            }
            return s.cases.isEmpty ? nil : s
        }
    }

    private func suiteView(_ suite: TestSuite) -> some View {
        // Failing suites start expanded so failures are visible immediately.
        let expanded = expandedSuites.wrappedValue.contains(suite.id) != (suite.failed > 0)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(.secondary)
                Image(systemName: suite.failed > 0 ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(suite.failed > 0 ? .red : .green)
                Text(shortName(suite.name)).lineLimit(1).truncationMode(.head)
                Spacer()
                Text(suite.failed > 0 ? "\(suite.failed) ✗" : "\(suite.cases.count)")
                    .scaledFont(.caption, digits: true).foregroundStyle(suite.failed > 0 ? .red : .secondary)
            }
            .interactiveRow {
                withAnimation(.easeOut(duration: 0.15)) { toggle(expandedSuites, suite.id) }
            }
            .help(suite.name)
            .contextMenu {
                Button { model.editor.open(URL(fileURLWithPath: root).appendingPathComponent(suite.file)) } label: {
                    Label("Show report file", systemImage: "doc.text")
                }
            }
            if expanded {
                ForEach(suite.cases) { caseRow($0).padding(.leading, 16) }
            }
        }
    }

    private func caseRow(_ c: TestCase) -> some View {
        let failed = c.outcome == .failed || c.outcome == .error
        let open = expandedCases.wrappedValue.contains(c.id)
        let location = Self.location(in: c)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon(c.outcome)).foregroundStyle(color(c.outcome)).frame(width: 14)
                Text(c.name).scaledFont(.callout).lineLimit(1)
                Spacer()
                if c.time > 0 {
                    Text(c.time < 1 ? "\(Int(c.time * 1000)) ms" : String(format: "%.1f s", c.time))
                        .scaledFont(.caption2, digits: true).foregroundStyle(.secondary)
                }
            }
            .interactiveRow {
                if failed { withAnimation(.easeOut(duration: 0.15)) { toggle(expandedCases, c.id) } }
                else if let loc = location { Task { await model.editor.reveal(fileName: loc.file, line: loc.line) } }
            }
            .contextMenu {
                if let loc = location {
                    Button { Task { await model.editor.reveal(fileName: loc.file, line: loc.line) } } label: {
                        Label("Go to \(loc.file):\(loc.line.map(String.init) ?? "?")", systemImage: "arrow.right.doc.on.clipboard")
                    }
                }
                if failed {
                    Button { model.ask(fixPrompt(c)) } label: { Label("Agent: fix the test", systemImage: "wand.and.stars") }
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(c.className).\(c.name)", forType: .string)
                    model.toast(String(localized: "Test name copied"))
                } label: { Label("Copy name", systemImage: "doc.on.doc") }
            }
            if failed && open {
                VStack(alignment: .leading, spacing: 6) {
                    if let m = c.message { Text(m).scaledFont(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if let d = c.details {
                        ScrollView(.horizontal) {
                            Text(d.split(separator: "\n").prefix(12).joined(separator: "\n"))
                                .font(.system(size: 10 * scale, design: .monospaced)).textSelection(.enabled)
                        }
                        .frame(maxHeight: 140)
                    }
                    HStack {
                        if let loc = location {
                            Button("Go to location") { Task { await model.editor.reveal(fileName: loc.file, line: loc.line) } }
                        }
                        Button("Agent: fix") { model.ask(fixPrompt(c)) }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 20)
            }
        }
    }

    // MARK: Helpers

    /// Reloads keep the current results on screen (no overlay); the first load shows a spinner.
    private func reload() async {
        let found = await TestReports.load(root: root)
        guard !Task.isCancelled else { return }
        report.wrappedValue = found
        reveal(model.workspace.testFocus)
    }

    private func toggle(_ set: State<Set<String>>, _ id: String) {
        if set.wrappedValue.contains(id) { set.wrappedValue.remove(id) } else { set.wrappedValue.insert(id) }
    }

    private func shortName(_ name: String) -> String {
        name.split(separator: ".").last.map(String.init) ?? name
    }

    private func fixPrompt(_ c: TestCase) -> String {
        var p = String(localized: "The test `\(c.className).\(c.name)` fails")
        if let m = c.message { p += ": \(m)" }
        p += String(localized: ". Find the cause, fix it and run the test again.")
        return p
    }

    private func icon(_ o: TestCase.Outcome) -> String {
        switch o {
        case .passed: "checkmark.circle"
        case .failed: "xmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .skipped: "minus.circle"
        }
    }

    private func color(_ o: TestCase.Outcome) -> Color {
        switch o {
        case .passed: .green
        case .failed, .error: .red
        case .skipped: .secondary
        }
    }

    /// Finds the first "File.ext:line" reference in a failure trace, else guesses the test file.
    static func location(in c: TestCase) -> (file: String, line: Int?)? {
        let text = (c.details ?? "") + "\n" + (c.message ?? "")
        let pattern = #"([A-Za-z0-9_\-]+\.(?:java|kt|go|ts|tsx|js|jsx|py|swift|rb|cs)):(\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let f = Range(m.range(at: 1), in: text), let l = Range(m.range(at: 2), in: text) {
            return (String(text[f]), Int(text[l]))
        }
        let cls = c.className.split(separator: ".").last.map(String.init) ?? ""
        return cls.isEmpty ? nil : (cls + ".java", nil)
    }
}
