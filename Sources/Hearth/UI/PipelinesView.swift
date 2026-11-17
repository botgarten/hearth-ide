import SwiftUI
import AppKit

/// CI/CD of the workspace repository: GitLab pipelines or GitHub Actions workflow runs.
struct PipelinesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var scale
    let root: String

    private let log = State(initialValue: JobLog?.none)
    private let showList = State(initialValue: Set<Int>())     // pipelines shown as list instead of graph
    private let bigGraph = State(initialValue: CIPipeline?.none)
    private let confirmPlay = State(initialValue: CIJob?.none)
    private let confirmRun = State(initialValue: false)
    private let writingToken = State(initialValue: false)
    private let configureToken = State(initialValue: false)
    private let confirmWorkflow = State(initialValue: CIWorkflow?.none)

    struct JobLog: Identifiable {
        let id = UUID()
        let job: CIJob
        var text: String?
    }

    private var store: PipelinesStore { model.pipelines }
    private var provider: CIProvider { store.remote?.provider ?? .gitLab }
    private var api: (any CIClient)? { store.root == root ? store.api : nil }

    var body: some View {
        Group {
            if !(store.remoteChecked && store.root == root) {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.remote == nil {
                ContentUnavailableView("No CI project", systemImage: "network.slash",
                                       description: Text("The repository has no GitLab or GitHub remote “origin”."))
            } else if api == nil || configureToken.wrappedValue {
                tokenSetup
            } else {
                content
            }
        }
        // A new folder: start over. File changes (an agent at work) only re-check the remote,
        // once they have settled; polling picks up new runs on its own.
        .task(id: root) { await store.open(root: root) }
        .task(id: "\(root)#\(model.workspace.settledRevision)") {
            if store.root == root { await store.recheckRemote() }
        }
        // Poll while visible: every 15 s if something runs, otherwise every 60 s.
        .task(id: "\(root)#\(store.remote?.origin.value ?? "")#\(api != nil)#\(store.onlyCurrentBranch)#\(model.workspace.gitSnapshot.branch)") {
            guard api != nil else { return }
            await store.poll(branch: model.workspace.gitSnapshot.branch)
        }
        .modifier(Dialogs(view: self))
    }

    /// Sheets and confirmations, apart from `body` so the type checker stays fast.
    private struct Dialogs: ViewModifier {
        let view: PipelinesView
        func body(content: Content) -> some View { view.dialogs(content) }
    }

    fileprivate func dialogs(_ content: some View) -> some View {
        sheets(content)
            .confirmationDialog(String(localized: "Start the manual job “\(confirmPlay.wrappedValue?.name ?? "")”?"),
                                isPresented: Binding(get: { confirmPlay.wrappedValue != nil }, set: { if !$0 { confirmPlay.wrappedValue = nil } }),
                                presenting: confirmPlay.wrappedValue) { job in
                Button("Start") { act(String(localized: "Job “\(job.name)” started")) { try await $0.play(job: job.id) } }
            } message: { job in
                Text("Stage “\(job.stage)”. Manual jobs are often deployments or other actions with effects outside the repository.")
            }
            .confirmationDialog("Start a new pipeline for “\(model.workspace.gitSnapshot.branch)”?", isPresented: confirmRun.projectedValue) {
                Button("Start pipeline") {
                    let ref = model.workspace.gitSnapshot.branch
                    act(String(localized: "Pipeline for \(ref) started")) { try await $0.run(ref: ref, workflow: nil) }
                }
            } message: {
                Text("This runs what is on GitLab (origin/\(model.workspace.gitSnapshot.branch)), not your local, unpushed changes.")
            }
            .modifier(WorkflowDialog(view: self))
    }

    private struct WorkflowDialog: ViewModifier {
        let view: PipelinesView
        func body(content: Content) -> some View { view.workflowDialog(content) }
    }

    fileprivate func workflowDialog(_ content: some View) -> some View {
        content.confirmationDialog(String(localized: "Start the workflow “\(confirmWorkflow.wrappedValue?.name ?? "")” for “\(model.workspace.gitSnapshot.branch)”?"),
                                   isPresented: Binding(get: { confirmWorkflow.wrappedValue != nil }, set: { if !$0 { confirmWorkflow.wrappedValue = nil } }),
                                   presenting: confirmWorkflow.wrappedValue) { workflow in
            Button("Start workflow") {
                let ref = model.workspace.gitSnapshot.branch
                act(String(localized: "Workflow “\(workflow.name)” started for \(ref)")) { try await $0.run(ref: ref, workflow: workflow) }
            }
        } message: { workflow in
            Text("\(workflow.path)\n\nThis runs what is on GitHub (origin/\(model.workspace.gitSnapshot.branch)), not your local, unpushed changes. The workflow needs a “workflow_dispatch” trigger.")
        }
    }

    fileprivate func sheets(_ content: some View) -> some View {
        content
            .sheet(item: log.projectedValue) { l in jobLogSheet(l) }
            .sheet(item: bigGraph.projectedValue) { p in bigGraphSheet(p) }
    }

    // MARK: Token setup

    private var tokenSetup: some View {
        CITokenSetupView(remote: store.remote, purpose: .pipelines, writing: writingToken.wrappedValue,
                         backTitle: api != nil ? String(localized: "Back to pipelines") : nil,
                         onBack: { configureToken.wrappedValue = false },
                         onSaved: { configureToken.wrappedValue = false },
                         onRevoke: { store.clearResults() })
            .id(writingToken.wrappedValue)
    }

    // MARK: Pipelines

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let e = store.error {
                Label(e, systemImage: "exclamationmark.triangle").scaledFont(.caption).foregroundStyle(.orange)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.pipelines.isEmpty && !store.loading && store.error == nil {
                ContentUnavailableView("No pipelines", systemImage: "checklist",
                                       description: Text(store.onlyCurrentBranch
                                                         ? "There is no pipeline for “\(model.workspace.gitSnapshot.branch)” yet."
                                                         : "This project has no pipeline yet."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(store.pipelines) { pipelineRow($0) }
                    }
                    .padding(8)
                }
            }
        }
        .busyOverlay(store.loading && store.pipelines.isEmpty, label: String(localized: "Loading pipelines…"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: provider == .gitLab ? "point.3.filled.connected.trianglepath.dotted" : "bolt.horizontal.circle")
                .foregroundStyle(provider == .gitLab ? Color.orange : Color.accentColor)
            Text(store.remote?.path ?? "").scaledFont(.callout, bold: true).lineLimit(1).truncationMode(.head)
            Spacer()
            Button { configureToken.wrappedValue = true } label: { Image(systemName: "key") }
                .buttonStyle(.borderless).help("Set up access for this \(provider.name) server")
            Picker("", selection: Binding(get: { store.onlyCurrentBranch }, set: { store.onlyCurrentBranch = $0 })) {
                Text(model.workspace.gitSnapshot.branch.isEmpty ? "Branch" : model.workspace.gitSnapshot.branch).tag(true)
                Text("All").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if provider == .gitLab {
                Button { confirmRun.wrappedValue = true } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .disabled(model.workspace.gitSnapshot.branch.isEmpty)
                    .help("Start a new pipeline for the current branch")
            } else {
                Menu {
                    if store.workflows.isEmpty {
                        Text("No active workflows found").disabled(true)
                    }
                    ForEach(store.workflows) { w in
                        Button(w.name) { confirmWorkflow.wrappedValue = w }
                    }
                } label: { Image(systemName: "play.fill") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(model.workspace.gitSnapshot.branch.isEmpty)
                    .help("Start a workflow for the current branch")
                    .task(id: "\(root)#\(api != nil)") { await store.loadWorkflows() }
            }
            Button { Task { await store.refresh(branch: model.workspace.gitSnapshot.branch) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help(store.lastRefresh.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "Refresh")
            if let r = store.remote {
                Button { NSWorkspace.shared.open(r.pipelinesPage) } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless).help(r.provider == .gitLab ? "Open pipelines in GitLab" : "Open Actions in GitHub")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func color(_ s: String) -> Color {
        switch s {
        case "success": .green
        case "failed": .red
        case "running": .blue
        case "canceled", "canceling", "skipped": .secondary
        case "manual": .purple
        default: .orange
        }
    }

    private func pipelineRow(_ p: CIPipeline) -> some View {
        let open = store.expanded.contains(p.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 9 * scale, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.secondary)
                Image(systemName: CIStatus.symbol(p.status)).foregroundStyle(color(p.status))
                    .symbolEffect(.pulse, isActive: p.status == "running")
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        if let name = p.name { Text(name).scaledFont(.callout, bold: true).lineLimit(1) }
                        Text("#\(p.iid)").scaledFont(.callout, bold: true, digits: true)
                        Text(p.ref).scaledFont(.callout, mono: true).lineLimit(1)
                        Text(String(p.sha.prefix(8))).scaledFont(.caption, mono: true).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Text(CIStatus.label(p.status)).foregroundStyle(color(p.status))
                        if let d = p.createdAt { Text("· \(d.formatted(.relative(presentation: .named)))") }
                        if !p.source.isEmpty { Text("· \(p.source)") }
                    }
                    .scaledFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .interactiveRow {
                withAnimation(.easeOut(duration: 0.15)) {
                    if open { store.expanded.remove(p.id) } else { store.expanded.insert(p.id) }
                }
                if !open { Task { await store.loadJobs(p.id) } }
            }
            .contextMenu {
                if let url = p.webURL {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open in \(provider.name)", systemImage: "arrow.up.forward.square") }
                }
                if p.status == "failed" || p.status == "canceled" {
                    Button { act(String(localized: "Retrying \(provider.runName) #\(p.iid)")) { try await $0.retry(pipeline: p.id) } } label: {
                        Label("Retry failed jobs", systemImage: "arrow.clockwise")
                    }
                }
                if CIStatus.isActive(p.status) {
                    Button(role: .destructive) { act(String(localized: "Cancelling \(provider.runName) #\(p.iid)")) { try await $0.cancel(pipeline: p.id) } } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p.sha, forType: .string)
                    model.toast(String(localized: "Commit SHA copied"))
                } label: { Label("Copy commit SHA", systemImage: "doc.on.doc") }
            }
            if open { stages(p).padding(.leading, 24) }
        }
    }

    @ViewBuilder
    private func stages(_ p: CIPipeline) -> some View {
        if let list = store.jobs[p.id] {
            let asList = showList.wrappedValue.contains(p.id)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("", selection: Binding(get: { asList }, set: { list in
                        if list { showList.wrappedValue.insert(p.id) } else { showList.wrappedValue.remove(p.id) }
                    })) {
                        Label("Diagram", systemImage: "point.3.filled.connected.trianglepath.dotted").tag(false)
                        Label("List", systemImage: "list.bullet").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    if !asList {
                        Button { bigGraph.wrappedValue = p } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .buttonStyle(.borderless).help("Show the diagram large")
                    }
                }
                if asList {
                    let order = list.reduce(into: [String]()) { if !$0.contains($1.stage) { $0.append($1.stage) } }
                    ForEach(order, id: \.self) { stage in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stage).scaledFont(.caption, bold: true).foregroundStyle(.secondary)
                            ForEach(list.filter { $0.stage == stage }) { jobRow($0) }
                        }
                    }
                } else {
                    PipelineGraph(jobs: list, onSelect: openLog, onRetry: retryJob, onPlay: { confirmPlay.wrappedValue = $0 })
                        .frame(height: graphHeight(list))
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        } else {
            HStack { ProgressView().controlSize(.small); Text("Loading jobs…").scaledFont(.caption) }
        }
    }

    private func jobRow(_ j: CIJob) -> some View {
        HStack(spacing: 6) {
            Image(systemName: CIStatus.symbol(j.status)).foregroundStyle(color(j.status))
            Text(j.name).scaledFont(.callout).lineLimit(1)
            if j.allowFailure && j.status == "failed" {
                Text("allowed").scaledFont(.caption2).foregroundStyle(.orange)
            }
            Spacer()
            if let d = j.duration {
                Text(d < 60 ? "\(Int(d)) s" : "\(Int(d) / 60) min \(Int(d) % 60) s")
                    .scaledFont(.caption2, digits: true).foregroundStyle(.secondary)
            }
            if j.status == "manual" {
                CircleAction(symbol: "play.fill", tint: .purple, help: String(localized: "Start manual job")) { confirmPlay.wrappedValue = j }
            } else if j.status == "failed" || j.status == "canceled" {
                CircleAction(symbol: "arrow.clockwise", tint: .orange, help: String(localized: "Retry job")) { retryJob(j) }
            }
        }
        .interactiveRow { openLog(j) }
        .help("Click for the job log")
        .contextMenu {
            Button { openLog(j) } label: { Label("Show log", systemImage: "doc.text") }
            if let url = j.webURL {
                Button { NSWorkspace.shared.open(url) } label: { Label("Open in \(provider.name)", systemImage: "arrow.up.forward.square") }
            }
            if j.status == "manual" {
                Button { confirmPlay.wrappedValue = j } label: { Label("Start manually…", systemImage: "play.fill") }
            }
            if PipelineGraph.retryable(j) {
                Button { retryJob(j) } label: { Label("Retry job", systemImage: "arrow.clockwise") }
            }
        }
    }

    private func graphHeight(_ jobs: [CIJob]) -> CGFloat {
        let perStage = Dictionary(grouping: jobs, by: \.stage).values.map(\.count).max() ?? 1
        return min(CGFloat(perStage) * 40 * scale + 70 * scale, 420)
    }

    private func retryJob(_ j: CIJob) {
        act(String(localized: "Retrying job “\(j.name)”")) { try await $0.retry(job: j.id) }
    }

    private func bigGraphSheet(_ p: CIPipeline) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: CIStatus.symbol(p.status)).foregroundStyle(PipelineGraph.color(p.status))
                Text("\(p.name ?? provider.runName) #\(p.iid)").font(.headline)
                Text(p.ref).font(.callout.monospaced()).foregroundStyle(.secondary)
                Text(CIStatus.label(p.status)).foregroundStyle(PipelineGraph.color(p.status))
                Spacer()
                if let url = p.webURL { Button("Open in \(provider.name)") { NSWorkspace.shared.open(url) } }
                Button("Close") { bigGraph.wrappedValue = nil }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            PipelineGraph(jobs: store.jobs[p.id] ?? [], large: true, onSelect: { job in
                bigGraph.wrappedValue = nil
                Task { try? await Task.sleep(for: .milliseconds(300)); openLog(job) }
            }, onRetry: retryJob, onPlay: { job in
                bigGraph.wrappedValue = nil
                Task { try? await Task.sleep(for: .milliseconds(300)); confirmPlay.wrappedValue = job }
            })
        }
        .frame(minWidth: 900, minHeight: 500)
    }

    // MARK: Job log

    private func jobLogSheet(_ l: JobLog) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: CIStatus.symbol(l.job.status)).foregroundStyle(color(l.job.status))
                Text(l.job.name).font(.headline)
                Text(l.job.stage).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let url = l.job.webURL {
                    Button("Open in \(provider.name)") { NSWorkspace.shared.open(url) }
                }
                Button("Close") { log.wrappedValue = nil }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            if let text = l.text {
                CodeEditor(text: .constant(text), language: .shell, editable: false,
                           highlightLine: text.split(separator: "\n", omittingEmptySubsequences: false).count)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 900, height: 600)
    }

    private func openLog(_ job: CIJob) {
        log.wrappedValue = JobLog(job: job, text: nil)
        guard let api else { return }
        Task {
            do {
                // Provider-specific markers are removed by the client; keep the tail of huge logs.
                let clean = try await api.log(job: job.id)
                let lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
                let text = lines.count > 3000 ? String(localized: "… (\(lines.count - 3000) lines trimmed)\n") + lines.suffix(3000).joined(separator: "\n") : clean
                log.wrappedValue?.text = text.isEmpty ? String(localized: "(empty log)") : text
            } catch {
                log.wrappedValue?.text = String(localized: "The log could not be loaded: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Loading & actions

    private func act(_ message: String, _ action: @escaping (any CIClient) async throws -> Void) {
        guard store.root == root, let r = store.remote, let api = model.ci.api(for: r, writing: true) else {
            writingToken.wrappedValue = true
            configureToken.wrappedValue = true
            model.banner = String(localized: "Please approve separate write access for this \(provider.name) server.")
            return
        }
        Task {
            do {
                try await action(api)
                model.toast(message)
                try? await Task.sleep(for: .seconds(1))
                await store.refresh(branch: model.workspace.gitSnapshot.branch)
            } catch {
                model.banner = error.localizedDescription
            }
        }
    }
}
