import SwiftUI
import AppKit

// MARK: Git

/// The Git pane. Narrow (beside the editor): one column, details open in place with a
/// back button. Wide (maximized, own window): a list on the left and the selected file,
/// merge/pull request, branch, commit or stash on the right.
struct GitView: View {
    @Environment(AppModel.self) private var model
    let root: String
    let snapshot: GitSnapshot

    enum Section: String, CaseIterable, Identifiable {
        case changes, requests, branches, history, stashes
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .changes: "plusminus.circle"
            case .requests: "arrow.triangle.pull"
            case .branches: "arrow.triangle.branch"
            case .history: "clock.arrow.circlepath"
            case .stashes: "tray.full"
            }
        }
    }

    struct SelectedChange: Equatable {
        let path: String
        let staged: Bool
    }

    /// From this width on, list and details sit side by side.
    static let wideWidth: CGFloat = 760

    @AppStorage("git.section") private var sectionRaw = Section.changes.rawValue
    @State private var branches: [Git.Branch] = []
    @State private var branchFilter = ""
    @State private var showRemote = false
    @State private var busy: String?
    @State private var pendingCheckout: Git.Branch?
    @State private var pendingDelete: Git.Branch?
    @State private var pendingDiscard: GitFileChange?
    @State private var newBranchBase: String?
    @State private var newBranchName = ""
    @State private var commitMessage = ""
    @State private var pendingMerge: Git.Branch?
    @State private var pendingStashDrop: GitStash?
    @State private var stashMessage: String?
    @State private var stashUntracked = true
    @State private var showChangeRequest = false

    @State private var selectedChange: SelectedChange?
    @State private var selectedBranch: String?
    @State private var selectedCommit: String?
    @State private var selectedStash: Int?
    @State private var detailText: String?
    @State private var loadedSelection = ""
    @State private var history: [Git.Commit] = []
    @State private var branchLog: [Git.Commit] = []

    private var section: Section { Section(rawValue: sectionRaw) ?? .changes }
    private var crs: ChangeRequestsStore { model.changeRequests }

    static func color(for marker: String) -> Color {
        switch marker {
        case "M": .orange
        case "A", "U": .green
        case "D", "!": .red
        case "R": .blue
        default: .secondary
        }
    }

    var body: some View {
        if !snapshot.isRepo {
            ContentUnavailableView("No Git repository", systemImage: "arrow.triangle.branch")
        } else {
            GeometryReader { geo in
                layout(wide: geo.size.width >= Self.wideWidth, width: geo.size.width)
            }
            .busyOverlay(busy != nil, label: busy)
            .task(id: "\(root)#\(model.workspace.settledRevision)") { await reloadBranches() }
            .task(id: "\(root)#\(model.workspace.settledRevision)#history") {
                history = await Git.log(in: root)
            }
            .task(id: root) { await crs.open(root: root) }
            // Merge/pull requests: load now and every 2 minutes while the pane is visible.
            .task(id: "\(root)#\(crs.remote?.origin.value ?? "")#\(crs.reader != nil)#\(crs.filter.rawValue)") {
                guard crs.root == root, crs.reader != nil else { return }
                while !Task.isCancelled {
                    await crs.refreshList()
                    try? await Task.sleep(for: .seconds(120))
                }
            }
            .task(id: detailKey) { await loadDetail() }
            .modifier(GitDialogs(view: self))
        }
    }

    // MARK: Layout

    @ViewBuilder
    private func layout(wide: Bool, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            toolbar(wide: wide)
            if snapshot.merging { mergeBanner }
            sectionBar(compact: width < 520)
            Divider()
            if wide {
                HStack(spacing: 0) {
                    list(wide: true)
                        .frame(width: min(420, max(300, width * 0.32)))
                    Divider()
                    detail(wide: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if narrowShowsDetail {
                detail(wide: false)
            } else {
                list(wide: false)
            }
        }
    }

    /// In the narrow layout a selection replaces the list (except local changes, which open in the editor).
    private var narrowShowsDetail: Bool {
        switch section {
        case .changes: false
        case .requests: crs.selected != nil
        case .branches: selectedBranch != nil
        case .history: selectedCommit != nil
        case .stashes: selectedStash != nil
        }
    }

    // MARK: Toolbar

    private var currentRequest: CRSummary? {
        crs.list.first { $0.state == .open && $0.source == snapshot.branch }
    }

    private func toolbar(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                branchMenu
                if wide { syncStatus }
                if let cr = currentRequest {
                    Button { openRequest(cr.number) } label: {
                        Badge(text: "\(crs.provider.changeRequestPrefix)\(cr.number)", symbol: "arrow.triangle.pull", tint: .green)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Open \(crs.provider.changeRequestName.lowercased()) for this branch: \(cr.title)"))
                }
                Spacer(minLength: 4)
                if wide { syncButtons(labels: true) }
            }
            if !wide {
                HStack(spacing: 8) {
                    syncStatus
                    Spacer(minLength: 4)
                    syncButtons(labels: false)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var branchMenu: some View {
        Menu {
            Button { startNewBranch(from: snapshot.branch) } label: { Label("New branch from the current state…", systemImage: "plus") }
            let recent = branches.filter { !$0.isRemote && !$0.isCurrent }.prefix(8)
            if !recent.isEmpty {
                Divider()
                Text("Switch to")
                ForEach(Array(recent)) { b in
                    Button(b.name) { pendingCheckout = b }
                }
            }
            Divider()
            Button { sectionRaw = Section.branches.rawValue } label: { Label("All branches…", systemImage: "list.bullet") }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.accentColor)
                Text(snapshot.branch).scaledFont(.body, bold: true, mono: true).lineLimit(1).truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Current branch")
    }

    @ViewBuilder
    private var syncStatus: some View {
        if let up = snapshot.upstream {
            HStack(spacing: 6) {
                Label("\(snapshot.ahead)", systemImage: "arrow.up").foregroundStyle(snapshot.ahead > 0 ? .primary : .secondary)
                Label("\(snapshot.behind)", systemImage: "arrow.down").foregroundStyle(snapshot.behind > 0 ? .orange : .secondary)
                Text(up).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .labelStyle(CompactLabel())
            .scaledFont(.caption, digits: true)
        } else {
            Text("No upstream").scaledFont(.caption).foregroundStyle(.secondary)
        }
    }

    private func syncButtons(labels: Bool) -> some View {
        HStack(spacing: 4) {
            toolbarButton(String(localized: "Fetch"), "arrow.triangle.2.circlepath", labels: labels) {
                Task { await run(String(localized: "Fetching in the sandbox…")) { await model.networkGit(.fetch, in: root) } }
            }
            toolbarButton(String(localized: "Pull"), "arrow.down.circle", labels: labels) {
                Task { await run(String(localized: "Pulling in the sandbox…")) { await model.pull(in: root) } }
            }
            .disabled(snapshot.upstream == nil)
            toolbarButton(String(localized: "Push"), "arrow.up.circle", labels: labels) { Task { await push() } }
                .disabled(snapshot.branch.isEmpty || snapshot.branch.hasPrefix("HEAD") || (snapshot.upstream != nil && snapshot.ahead == 0))
                .help(snapshot.upstream == nil ? "Publish this branch to origin" : "Upload \(snapshot.ahead) commit(s)")
            toolbarButton(crs.remote?.provider == .gitHub ? String(localized: "New PR") : String(localized: "New MR"),
                          "plus.bubble", labels: labels) { showChangeRequest = true }
                .help("Open a merge request (GitLab) or pull request (GitHub) for this branch")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func toolbarButton(_ title: String, _ symbol: String, labels: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if labels { Label(title, systemImage: symbol) } else { Image(systemName: symbol) }
        }
        .help(title)
    }

    private var mergeBanner: some View {
        HStack {
            Label("Merge in progress", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Resolve the conflicts in the files, stage them and commit – or abort.").foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Abort merge") { Task { await sandboxOp(String(localized: "Aborting merge…"), .mergeAbort) } }
        }
        .scaledFont(.caption).controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: Section bar

    private func count(_ s: Section) -> Int {
        switch s {
        case .changes: snapshot.changes.count
        case .requests: crs.filter == .open ? crs.list.count : 0
        case .branches: 0
        case .history: 0
        case .stashes: snapshot.stashes.count
        }
    }

    private func title(_ s: Section) -> String {
        switch s {
        case .changes: String(localized: "Changes")
        case .requests: crs.remote?.provider.changeRequestsName ?? String(localized: "Merge requests")
        case .branches: String(localized: "Branches")
        case .history: String(localized: "History")
        case .stashes: String(localized: "Stashes")
        }
    }

    private func sectionBar(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Section.allCases) { s in
                PaneTabButton(title: title(s), symbol: s.symbol, count: count(s), selected: section == s, compact: compact) {
                    withAnimation(.easeOut(duration: 0.12)) { sectionRaw = s.rawValue }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.bottom, 6)
    }

    // MARK: Lists

    @ViewBuilder
    private func list(wide: Bool) -> some View {
        switch section {
        case .changes: changesList(wide: wide)
        case .requests: requestsList
        case .branches: branchList
        case .history: historyList
        case .stashes: stashList
        }
    }

    private var stagedChanges: [GitFileChange] { snapshot.changes.filter(\.isStaged) }
    private var unstagedChanges: [GitFileChange] { snapshot.changes.filter(\.isUnstaged) }

    private func changesList(wide: Bool) -> some View {
        VStack(spacing: 0) {
            commitCard.padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if snapshot.changes.isEmpty {
                        emptyRow(String(localized: "Working tree clean"), symbol: "checkmark.circle")
                    }
                    if !stagedChanges.isEmpty {
                        groupHeader(String(localized: "Staged"), count: stagedChanges.count, actionTitle: String(localized: "Unstage all"), symbol: "minus.circle") {
                            Task { await run(String(localized: "Unstaging…")) { await Git.unstageAll(in: root) } }
                        }
                        ForEach(stagedChanges) { changeRow($0, staged: true, wide: wide) }
                    }
                    if !unstagedChanges.isEmpty {
                        groupHeader(String(localized: "Not staged"), count: unstagedChanges.count, actionTitle: String(localized: "Stage all"), symbol: "plus.circle") {
                            Task { await run(String(localized: "Staging…")) { await Git.stageAll(in: root) } }
                        }
                        ForEach(unstagedChanges) { changeRow($0, staged: false, wide: wide) }
                    }
                }
                .padding(6)
            }
        }
    }

    private func emptyRow(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).scaledFont(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 10)
    }

    private func groupHeader(_ title: String, count: Int, actionTitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title.uppercased()).scaledFont(.caption2, bold: true).foregroundStyle(.secondary)
            Text("\(count)").scaledFont(.caption2, digits: true).foregroundStyle(.secondary)
                .padding(.horizontal, 5).background(Color.primary.opacity(0.08), in: Capsule())
            Spacer()
            Button(action: action) { Label(actionTitle, systemImage: symbol).scaledFont(.caption) }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 2)
    }

    private func toggleStage(_ change: GitFileChange, staged: Bool) {
        Task {
            await run(staged ? String(localized: "Unstaging…") : String(localized: "Staging…")) {
                staged ? await Git.unstage([change.path], in: root) : await Git.stage([change.path], in: root)
            }
            if selectedChange?.path == change.path { selectedChange = SelectedChange(path: change.path, staged: !staged) }
        }
    }

    private func changeRow(_ change: GitFileChange, staged: Bool, wide: Bool) -> some View {
        let url = URL(fileURLWithPath: root).appendingPathComponent(change.path)
        let selected = wide ? selectedChange == SelectedChange(path: change.path, staged: staged)
                            : model.editor.file == url && model.editor.mode == .diff
        return HStack(spacing: 6) {
            Text(change.marker).scaledFont(.callout, bold: true, mono: true)
                .foregroundStyle(Self.color(for: change.marker)).frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent).lineLimit(1)
                let dir = (change.path as NSString).deletingLastPathComponent
                if !dir.isEmpty {
                    Text(dir).scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            LineCounts(added: change.added, removed: change.removed)
            Button { toggleStage(change, staged: staged) } label: { Image(systemName: staged ? "minus.circle" : "plus.circle") }
                .buttonStyle(.borderless)
                .help(staged ? "Unstage" : "Stage")
        }
        .interactiveRow(selected: selected) {
            if wide { selectedChange = SelectedChange(path: change.path, staged: staged) } else { model.editor.open(url, mode: .diff) }
        }
        .help("Click for diff")
        .contextMenu {
            Button { toggleStage(change, staged: staged) } label: {
                Label(staged ? "Unstage" : "Stage", systemImage: staged ? "minus.circle" : "plus.circle")
            }
            FileContextMenu(url: url, changed: true)
            Divider()
            Button(role: .destructive) { pendingDiscard = change } label: {
                Label("Discard changes…", systemImage: "arrow.uturn.backward")
            }
        }
    }

    private var commitCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Commit message", text: $commitMessage, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button { Task { await commit() } } label: {
                    Label(stagedChanges.isEmpty ? String(localized: "Commit") : String(localized: "Commit (\(stagedChanges.count))"),
                          systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(stagedChanges.isEmpty || !SandboxGitOperation.validMessage(commitMessage))
                .help(stagedChanges.isEmpty ? "Stage changes first" : "Commit the staged changes in the Git sandbox (hooks do not run)")
                Spacer()
                Button { stashMessage = "" } label: { Label("Stash", systemImage: "tray.and.arrow.down") }
                    .disabled(snapshot.changes.isEmpty)
                    .help("Put the uncommitted changes aside")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var requestsList: some View {
        if !crs.remoteChecked {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if crs.remote == nil {
            ContentUnavailableView("No GitLab or GitHub project", systemImage: "network.slash",
                                   description: Text("The repository has no GitLab or GitHub remote “origin”."))
        } else if crs.reader == nil {
            ScrollView {
                CITokenSetupView(remote: crs.remote, purpose: .changeRequests)
                    .frame(maxWidth: 560)
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { crs.filter }, set: { crs.filter = $0; crs.closeDetail() })) {
                        ForEach(CRState.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    if crs.loadingList { ProgressView().controlSize(.small) }
                    Button { Task { await crs.refreshList() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Reload")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                if let e = crs.listError {
                    Label(e, systemImage: "exclamationmark.triangle").scaledFont(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.bottom, 6)
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if crs.listLoaded && crs.list.isEmpty {
                            emptyRow(String(localized: "Nothing here"), symbol: "tray")
                        }
                        ForEach(crs.list) { cr in
                            ChangeRequestRow(cr: cr, provider: crs.provider, isCurrentBranch: cr.source == snapshot.branch)
                                .interactiveRow(selected: crs.selected == cr.number) { openRequest(cr.number) }
                                .contextMenu {
                                    if let url = cr.webURL {
                                        Button { NSWorkspace.shared.open(url) } label: {
                                            Label("Open in \(crs.provider.name)", systemImage: "arrow.up.forward.square")
                                        }
                                        Button { copy(url.absoluteString) } label: { Label("Copy link", systemImage: "link") }
                                    }
                                    Button { checkoutRequestBranch(cr.source) } label: { Label("Check out branch", systemImage: "arrow.down.to.line") }
                                }
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    private var visibleBranches: [Git.Branch] {
        let filter = branchFilter.lowercased()
        return branches.filter { $0.isRemote == showRemote && (filter.isEmpty || $0.name.lowercased().contains(filter)) }
    }

    private var branchList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("", selection: $showRemote) {
                    Text("Local").tag(false)
                    Text("Remote").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                SearchField(text: $branchFilter, prompt: "Filter")
                Button { startNewBranch(from: snapshot.branch) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("New branch from the current state")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if visibleBranches.isEmpty { emptyRow(String(localized: "No branches"), symbol: "arrow.triangle.branch") }
                    ForEach(visibleBranches) { branchRow($0) }
                }
                .padding(6)
            }
        }
    }

    private func branchRow(_ b: Git.Branch) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: b.isCurrent ? "checkmark.circle.fill" : (b.isRemote ? "cloud" : "arrow.triangle.branch"))
                .foregroundStyle(b.isCurrent ? Color.green : .secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(b.name).scaledFont(.callout, mono: true).fontWeight(b.isCurrent ? .bold : .regular).lineLimit(1)
                    if let track = b.track {
                        Text(track).scaledFont(.caption2).foregroundStyle(.orange)
                    }
                }
                Text("\(b.date) · \(b.subject)").scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .interactiveRow(selected: selectedBranch == b.id) { selectedBranch = b.id }
        .contextMenu { branchMenuItems(b) }
    }

    @ViewBuilder
    private func branchMenuItems(_ b: Git.Branch) -> some View {
        if !b.isCurrent {
            Button { pendingCheckout = b } label: { Label("Check out", systemImage: "arrow.right.circle") }
        }
        Button { startNewBranch(from: b.name) } label: { Label("New branch from here…", systemImage: "plus") }
        if !b.isCurrent {
            Button { pendingMerge = b } label: { Label("Merge into current branch…", systemImage: "arrow.triangle.merge") }
        }
        Button { copy(b.name); model.toast(String(localized: "Branch name copied")) } label: { Label("Copy name", systemImage: "doc.on.doc") }
        if !b.isRemote && !b.isCurrent {
            Divider()
            Button(role: .destructive) { pendingDelete = b } label: { Label("Delete…", systemImage: "trash") }
        }
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if history.isEmpty { emptyRow(String(localized: "No commits yet"), symbol: "clock") }
                ForEach(history) { c in
                    commitRow(c).interactiveRow(selected: selectedCommit == c.hash) { selectedCommit = c.hash }
                        .contextMenu {
                            Button { copy(c.hash) } label: { Label("Copy hash", systemImage: "doc.on.doc") }
                            Button { startNewBranch(from: c.hash) } label: { Label("New branch from here…", systemImage: "plus") }
                        }
                }
            }
            .padding(6)
        }
    }

    private func commitRow(_ c: Git.Commit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(c.subject).scaledFont(.callout).lineLimit(2)
            HStack(spacing: 4) {
                Text(c.hash).scaledFont(.caption, mono: true).foregroundStyle(Color.accentColor)
                Text("· \(c.author) · \(c.date)").scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var stashList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if snapshot.stashes.isEmpty { emptyRow(String(localized: "No stashes"), symbol: "tray") }
                ForEach(snapshot.stashes) { st in
                    HStack(spacing: 6) {
                        Image(systemName: "tray.full").foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(st.subject).scaledFont(.callout).lineLimit(2)
                            Text("stash@{\(st.index)}").scaledFont(.caption2, mono: true).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button { Task { await sandboxOp(String(localized: "Applying stash…"), .stashPop(st.index)) } } label: {
                            Image(systemName: "arrow.uturn.up.circle")
                        }
                        .buttonStyle(.borderless).help("Restore and remove this stash (pop)")
                    }
                    .interactiveRow(selected: selectedStash == st.index) { selectedStash = st.index }
                    .contextMenu { stashMenuItems(st) }
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private func stashMenuItems(_ st: GitStash) -> some View {
        Button { Task { await sandboxOp(String(localized: "Applying stash…"), .stashPop(st.index)) } } label: {
            Label("Pop (restore and remove)", systemImage: "arrow.uturn.up.circle")
        }
        Button { Task { await sandboxOp(String(localized: "Applying stash…"), .stashApply(st.index)) } } label: {
            Label("Apply (keep stash)", systemImage: "arrow.uturn.up")
        }
        Divider()
        Button(role: .destructive) { pendingStashDrop = st } label: { Label("Drop…", systemImage: "trash") }
    }

    // MARK: Details

    @ViewBuilder
    private func detail(wide: Bool) -> some View {
        switch section {
        case .changes: changeDetail
        case .requests:
            if crs.selected != nil {
                ChangeRequestDetailView(root: root, onBack: wide ? nil : { crs.closeDetail() },
                                        onCheckout: { checkoutRequestBranch($0) })
            } else {
                placeholder(String(localized: "Select a \(crs.provider.changeRequestName.lowercased())"), symbol: "arrow.triangle.pull",
                            note: String(localized: "Review the changes, comment on lines, approve and merge – without leaving Hearth."))
            }
        case .branches: branchDetail(wide: wide)
        case .history: commitDetail(wide: wide)
        case .stashes: stashDetail(wide: wide)
        }
    }

    private func placeholder(_ title: String, symbol: String, note: String? = nil) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let note { Text(note) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailHeader<Actions: View>(back: (() -> Void)?, @ViewBuilder title: () -> some View,
                                             @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let back {
                Button(action: back) { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless).scaledFont(.caption)
            }
            HStack(alignment: .center, spacing: 8) {
                title()
                Spacer(minLength: 8)
                actions()
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var changeDetail: some View {
        if let sel = selectedChange, let change = snapshot.changes.first(where: { $0.path == sel.path }) {
            let url = URL(fileURLWithPath: root).appendingPathComponent(change.path)
            VStack(spacing: 0) {
                detailHeader(back: nil) {
                    HStack(spacing: 8) {
                        Text(change.marker).scaledFont(.title3, bold: true, mono: true).foregroundStyle(Self.color(for: change.marker))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent).scaledFont(.headline)
                            Text(change.path).scaledFont(.caption, mono: true).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                        }
                        LineCounts(added: change.added, removed: change.removed)
                    }
                } actions: {
                    Button { toggleStage(change, staged: sel.staged) } label: {
                        Label(sel.staged ? "Unstage" : "Stage", systemImage: sel.staged ? "minus.circle" : "plus.circle")
                    }
                    Button(role: .destructive) { pendingDiscard = change } label: { Label("Discard…", systemImage: "arrow.uturn.backward") }
                    Button { model.editor.open(url, mode: .file) } label: { Label("Open", systemImage: "doc.text") }
                        .help("Open in editor")
                }
                DiffScrollView(text: detailText)
            }
        } else {
            placeholder(snapshot.changes.isEmpty ? String(localized: "Working tree clean") : String(localized: "Select a file"),
                        symbol: snapshot.changes.isEmpty ? "checkmark.circle" : "doc.text.magnifyingglass",
                        note: snapshot.changes.isEmpty ? nil : String(localized: "Its changes appear here."))
        }
    }

    @ViewBuilder
    private func branchDetail(wide: Bool) -> some View {
        if let b = branches.first(where: { $0.id == selectedBranch }) {
            VStack(spacing: 0) {
                detailHeader(back: wide ? nil : { selectedBranch = nil }) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: b.isRemote ? "cloud" : "arrow.triangle.branch").foregroundStyle(Color.accentColor)
                            Text(b.name).scaledFont(.headline, mono: true).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            if b.isCurrent { Badge(text: String(localized: "current"), tint: .green) }
                        }
                        HStack(spacing: 6) {
                            if let up = b.upstream, !up.isEmpty { Text("→ \(up)").scaledFont(.caption, mono: true) }
                            if let t = b.track { Text(t).scaledFont(.caption).foregroundStyle(.orange) }
                        }
                        .foregroundStyle(.secondary)
                    }
                } actions: {
                    if !b.isCurrent {
                        Button { pendingCheckout = b } label: { Label("Check out", systemImage: "arrow.right.circle") }
                        Button { pendingMerge = b } label: { Label("Merge…", systemImage: "arrow.triangle.merge") }
                            .help("Merge into \(snapshot.branch)")
                    }
                    Menu {
                        branchMenuItems(b)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuIndicator(.hidden).fixedSize()
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        Text("Latest commits").scaledFont(.caption2, bold: true).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.top, 6)
                        ForEach(branchLog) { c in
                            commitRow(c).interactiveRow {
                                selectedCommit = c.hash
                                sectionRaw = Section.history.rawValue
                            }
                        }
                    }
                    .padding(8)
                }
            }
        } else {
            placeholder(String(localized: "Select a branch"), symbol: "arrow.triangle.branch",
                        note: String(localized: "Its latest commits and actions appear here."))
        }
    }

    @ViewBuilder
    private func commitDetail(wide: Bool) -> some View {
        if let hash = selectedCommit {
            let c = history.first { $0.hash == hash }
            VStack(spacing: 0) {
                detailHeader(back: wide ? nil : { selectedCommit = nil }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c?.subject ?? hash).scaledFont(.headline).lineLimit(2).textSelection(.enabled)
                        if let c {
                            Text("\(c.hash) · \(c.author) · \(c.date)").scaledFont(.caption, mono: true).foregroundStyle(.secondary)
                        }
                    }
                } actions: {
                    Button { copy(hash) } label: { Label("Copy hash", systemImage: "doc.on.doc") }
                }
                DiffScrollView(text: detailText)
            }
        } else {
            placeholder(String(localized: "Select a commit"), symbol: "clock.arrow.circlepath")
        }
    }

    @ViewBuilder
    private func stashDetail(wide: Bool) -> some View {
        if let index = selectedStash, let st = snapshot.stashes.first(where: { $0.index == index }) {
            VStack(spacing: 0) {
                detailHeader(back: wide ? nil : { selectedStash = nil }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(st.subject).scaledFont(.headline).lineLimit(2)
                        Text("stash@{\(st.index)}").scaledFont(.caption, mono: true).foregroundStyle(.secondary)
                    }
                } actions: {
                    Button { Task { await sandboxOp(String(localized: "Applying stash…"), .stashPop(st.index)) } } label: {
                        Label("Pop", systemImage: "arrow.uturn.up.circle")
                    }
                    .help("Restore and remove this stash (pop)")
                    Button { Task { await sandboxOp(String(localized: "Applying stash…"), .stashApply(st.index)) } } label: {
                        Label("Apply", systemImage: "arrow.uturn.up")
                    }
                    .help("Apply (keep stash)")
                    Button(role: .destructive) { pendingStashDrop = st } label: { Image(systemName: "trash") }
                        .help("Drop…")
                }
                DiffScrollView(text: detailText)
            }
        } else {
            placeholder(String(localized: "Select a stash"), symbol: "tray.full")
        }
    }

    /// What the detail column shows, so its text reloads when the selection or the files change.
    private var detailKey: String { "\(root)#\(model.workspace.settledRevision)#\(detailSelection)" }

    private var detailSelection: String {
        switch section {
        case .changes: selectedChange.map { "c:\($0.path)#\($0.staged)" } ?? ""
        case .branches: "b:\(selectedBranch ?? "")"
        case .history: "h:\(selectedCommit ?? "")"
        case .stashes: "s:\(selectedStash.map(String.init) ?? "")"
        case .requests: ""
        }
    }

    /// A new selection shows a spinner; new file contents for the same selection replace the old diff quietly.
    private func loadDetail() async {
        let selection = detailSelection
        if selection != loadedSelection { detailText = nil }
        defer { if !Task.isCancelled { loadedSelection = selection } }
        switch section {
        case .changes:
            guard let sel = selectedChange, let change = snapshot.changes.first(where: { $0.path == sel.path }) else { return }
            detailText = await Git.diff(path: change.path, in: root, untracked: change.code == "??")
        case .history:
            guard let hash = selectedCommit else { return }
            detailText = await Git.show(commit: hash, in: root)
        case .stashes:
            guard let index = selectedStash else { return }
            detailText = await Git.stashDiff(index, in: root)
        case .branches:
            guard let b = branches.first(where: { $0.id == selectedBranch }) else { branchLog = []; return }
            branchLog = await Git.log(b.name, limit: 40, in: root)
        case .requests:
            break
        }
    }

    // MARK: Actions

    fileprivate var checkoutTitle: String {
        String(localized: "Switch to “\(pendingCheckout?.localName ?? "")”?")
    }

    fileprivate func isPresent<T>(_ binding: Binding<T?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
    }

    private func startNewBranch(from base: String) {
        newBranchName = ""
        newBranchBase = base
    }

    private func openRequest(_ number: Int) {
        sectionRaw = Section.requests.rawValue
        Task { await crs.select(number) }
    }

    /// Checks out the source branch of a merge/pull request (fetching first if it isn't known yet).
    private func checkoutRequestBranch(_ source: String) {
        guard source != snapshot.branch else {
            model.toast(String(localized: "You are already on \(source)"))
            return
        }
        Task {
            func find() -> Git.Branch? {
                branches.first { !$0.isRemote && $0.name == source } ?? branches.first { $0.isRemote && $0.localName == source }
            }
            if find() == nil {
                await run(String(localized: "Fetching in the sandbox…")) { await model.networkGit(.fetch, in: root) }
            }
            if let b = find() { pendingCheckout = b } else {
                model.banner = String(localized: "The branch “\(source)” was not found on origin.")
            }
        }
    }

    private func reloadBranches() async {
        branches = await Git.branches(in: root)
    }

    fileprivate func run(_ label: String, _ op: () async -> Git.OpResult) async {
        busy = label
        let result = await op()
        busy = nil
        report(result)
        model.workspace.refreshNow()
        await reloadBranches()
    }

    fileprivate func sandboxOp(_ label: String, _ op: SandboxGitOperation) async {
        await run(label) { await model.networkGit(op, in: root) }
    }

    private func commit() async {
        let message = commitMessage
        busy = String(localized: "Committing…")
        let result = await model.networkGit(.commit(message: message), in: root)
        busy = nil
        if result.ok { commitMessage = "" }
        report(result)
        model.workspace.refreshNow()
        await reloadBranches()
    }

    private func push() async {
        let name = snapshot.branch
        await sandboxOp(String(localized: "Pushing \(name)…"), .push(branch: name, setUpstream: snapshot.upstream == nil))
    }

    private func report(_ result: Git.OpResult) {
        if result.ok {
            model.toast(result.output.lastNonEmptyLines(1).isEmpty ? String(localized: "Done") : result.output.lastNonEmptyLines(1))
        } else {
            model.banner = "Git: " + result.output.lastNonEmptyLines(4)
        }
    }

    fileprivate func discard(_ change: GitFileChange) async {
        await run(String(localized: "Discarding \(change.path)…")) {
            if change.code == "??" { return await Git.mutate(["clean", "-f", "--", change.path], in: root) }
            return await Git.mutate(["restore", "--staged", "--worktree", "--source=HEAD", "--", change.path], in: root)
        }
        if selectedChange?.path == change.path { selectedChange = nil }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: Dialogs

    /// Confirmations and sheets, apart from `body` so the type checker stays fast.
    private struct GitDialogs: ViewModifier {
        let view: GitView
        func body(content: Content) -> some View { view.dialogs(content) }
    }

    fileprivate func dialogs(_ content: some View) -> some View {
        content
            .confirmationDialog(checkoutTitle, isPresented: isPresent($pendingCheckout), presenting: pendingCheckout) { b in
                Button("Switch") { Task { await run(String(localized: "Switching to \(b.localName)…")) { await Git.checkout(b, in: root) } } }
            } message: { _ in
                Text(snapshot.changes.isEmpty
                     ? "The agent then works on this branch."
                     : "There are \(snapshot.changes.count) uncommitted changes. Git carries them over unless they conflict – otherwise the switch is cancelled.")
            }
            .confirmationDialog(String(localized: "Delete branch “\(pendingDelete?.name ?? "")”?"),
                                isPresented: isPresent($pendingDelete), presenting: pendingDelete) { b in
                Button("Delete", role: .destructive) {
                    Task { await run(String(localized: "Deleting \(b.name)…")) { await Git.mutate(["branch", "-d", b.name], in: root) } }
                }
            } message: { _ in Text("Only possible once the branch is merged (git branch -d).") }
            .confirmationDialog(String(localized: "Discard the changes to “\(pendingDiscard?.path ?? "")”?"),
                                isPresented: isPresent($pendingDiscard), presenting: pendingDiscard) { c in
                Button("Discard", role: .destructive) { Task { await discard(c) } }
            } message: { _ in Text("This cannot be undone.") }
            .modifier(MoreDialogs(view: self))
    }

    private struct MoreDialogs: ViewModifier {
        let view: GitView
        func body(content: Content) -> some View { view.moreDialogs(content) }
    }

    fileprivate func moreDialogs(_ content: some View) -> some View {
        content
            .confirmationDialog(String(localized: "Merge “\(pendingMerge?.name ?? "")” into “\(snapshot.branch)”?"),
                                isPresented: isPresent($pendingMerge), presenting: pendingMerge) { b in
                Button("Merge") { Task { await sandboxOp(String(localized: "Merging \(b.name)…"), .merge(branch: b.name)) } }
            } message: { _ in
                Text(snapshot.changes.isEmpty ? "Runs in the Git sandbox. Conflicts stay in the files; “Abort merge” undoes it."
                     : "There are uncommitted changes. Git refuses the merge if they conflict with it.")
            }
            .confirmationDialog(String(localized: "Drop stash “\(pendingStashDrop?.subject ?? "")”?"),
                                isPresented: isPresent($pendingStashDrop), presenting: pendingStashDrop) { st in
                Button("Drop", role: .destructive) {
                    if selectedStash == st.index { selectedStash = nil }
                    Task { await sandboxOp(String(localized: "Dropping stash…"), .stashDrop(st.index)) }
                }
            } message: { _ in Text("This cannot be undone.") }
            .alert("Stash changes", isPresented: Binding(get: { stashMessage != nil }, set: { if !$0 { stashMessage = nil } })) {
                TextField("Message (optional)", text: Binding(get: { stashMessage ?? "" }, set: { stashMessage = $0 }))
                Button("Stash") {
                    let message = stashMessage ?? ""
                    Task { await sandboxOp(String(localized: "Stashing…"), .stash(message: message, includeUntracked: stashUntracked)) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Saves the uncommitted changes (including new files) and restores a clean working tree.") }
            .sheet(isPresented: $showChangeRequest) {
                ChangeRequestSheet(root: root, snapshot: snapshot, branches: branches) { url in
                    crs.filter = .open
                    Task {
                        await crs.refreshList()
                        if let n = Int(url.lastPathComponent) { openRequest(n) }
                    }
                }
            }
            .alert("New branch", isPresented: isPresent($newBranchBase)) {
                TextField("feature/…", text: $newBranchName)
                Button("Create & switch") {
                    let base = newBranchBase ?? "HEAD"
                    let name = newBranchName.trimmingCharacters(in: .whitespaces)
                    Task { await run(String(localized: "Creating \(name)…")) { await Git.mutate(["switch", "-c", name, base], in: root) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Base: \(newBranchBase ?? "")")
            }
    }
}

/// Icon and number close together (ahead/behind counters).
private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) { configuration.icon; configuration.title }
    }
}

/// Opens a merge request (GitLab) or pull request (GitHub) for the current branch through the
/// provider's API, with the separate write token approved for that server.
struct ChangeRequestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let root: String
    let snapshot: GitSnapshot
    let branches: [Git.Branch]
    var onCreated: (URL) -> Void = { _ in }
    @State private var title = ""
    @State private var text = ""
    @State private var target = ""
    @State private var draft = false
    @State private var remote: CIRemote?
    @State private var checked = false
    @State private var sending = false
    @State private var error: String?

    private var targets: [String] {
        let names = branches.filter(\.isRemote).map(\.localName).filter { $0 != snapshot.branch && $0 != "HEAD" }
        return Array(Set(names)).sorted()
    }
    private var published: Bool { snapshot.upstream != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(remote.map { $0.provider == .gitHub ? String(localized: "New pull request") : String(localized: "New merge request") }
                 ?? String(localized: "New merge/pull request")).font(.title3.bold())
            if checked, remote == nil {
                Text("The remote “origin” is not a GitLab or GitHub repository.").foregroundStyle(.red)
            } else {
                HStack(spacing: 6) {
                    Text(snapshot.branch).scaledFont(.callout, mono: true)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Picker("", selection: $target) {
                        ForEach(targets, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                CommentEditor(text: $text, placeholder: String(localized: "Description (optional, Markdown)"), minHeight: 120)
                Toggle("Draft", isOn: $draft)
                if !published || snapshot.ahead > 0 {
                    Label(published ? "There are commits not pushed yet. Push first, they will be missing otherwise."
                                    : "This branch is not on the server yet. Push it first.", systemImage: "exclamationmark.triangle")
                        .scaledFont(.caption).foregroundStyle(.orange)
                }
            }
            if let error { Text(error).scaledFont(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(sending ? String(localized: "Creating…") : String(localized: "Create")) { Task { await create() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(sending || remote == nil || !published || title.trimmingCharacters(in: .whitespaces).isEmpty
                              || !ChangeRequest.valid(target) || !ChangeRequest.valid(snapshot.branch))
            }
        }
        .padding(20).frame(width: 520)
        .task {
            remote = await CIRemote.of(repo: root)
            checked = true
            if let r = remote { await model.ci.load(for: r.origin) }
            target = ["main", "master", "develop"].first(where: targets.contains) ?? targets.first ?? ""
            title = snapshot.recentCommits.first.map { String($0.drop { $0 != " " }.dropFirst()) } ?? ""
        }
    }

    private func create() async {
        guard let r = remote else { return }
        guard let api = model.ci.api(for: r, writing: true) else {
            error = String(localized: "Please approve separate write access for this \(r.provider.name) server first (CI/CD pane).")
            return
        }
        sending = true
        error = nil
        do {
            let url = try await api.createChangeRequest(ChangeRequest(
                title: title.trimmingCharacters(in: .whitespaces), description: text, source: snapshot.branch, target: target, draft: draft))
            model.toast(String(localized: "Created: \(url.absoluteString)"))
            onCreated(url)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        sending = false
    }
}
