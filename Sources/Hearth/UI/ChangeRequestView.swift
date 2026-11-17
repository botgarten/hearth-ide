import SwiftUI
import AppKit

// Merge requests (GitLab) / pull requests (GitHub) in the Git pane: list rows and the
// review screen with description, conversation, changed files with line comments,
// review and merge.

extension CRState {
    var tint: Color {
        switch self {
        case .open: .green
        case .merged: .purple
        case .closed: .red
        }
    }
    var symbol: String {
        switch self {
        case .open: "arrow.triangle.pull"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        }
    }
}

extension Date {
    var relativeText: String { formatted(.relative(presentation: .named)) }
}

struct ChangeRequestRow: View {
    let cr: CRSummary
    let provider: CIProvider
    var isCurrentBranch = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: cr.draft ? "pencil.circle" : cr.state.symbol)
                .foregroundStyle(cr.draft ? Color.secondary : cr.state.tint)
                .frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(cr.title).scaledFont(.callout, bold: true).lineLimit(2)
                    if cr.draft { Badge(text: String(localized: "Draft")) }
                }
                HStack(spacing: 4) {
                    Text("\(provider.changeRequestPrefix)\(cr.number)").scaledFont(.caption, mono: true)
                    Text("·")
                    Text(cr.author)
                    if let d = cr.updatedAt { Text("·"); Text(d.relativeText) }
                }
                .scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(cr.source).fontWeight(isCurrentBranch ? .bold : .regular)
                    Image(systemName: "arrow.right").font(.system(size: 8))
                    Text(cr.target)
                }
                .scaledFont(.caption2, mono: true).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if isCurrentBranch {
                Image(systemName: "location.fill").scaledFont(.caption2).foregroundStyle(Color.accentColor)
                    .help("Your current branch")
            }
        }
        .padding(.vertical, 3)
    }
}

/// The review screen of one merge/pull request.
struct ChangeRequestDetailView: View {
    @Environment(AppModel.self) private var model
    let root: String
    /// Back to the list (narrow layout), nil when the list is beside it.
    var onBack: (() -> Void)?
    var onCheckout: (String) -> Void

    enum Tab: String { case overview, files }
    @State var tab: Tab = .overview
    @State private var newComment = ""
    @State private var lineDraft: LineDraft?
    @State private var replyThread: String?
    @State private var replyText = ""
    @State private var showMerge = false
    @State private var mergeOptions = CRMergeOptions()
    @State private var showReview = false
    @State private var reviewVerdict: CRVerdict = .comment
    @State private var reviewText = ""
    @State private var jumpToFile: String?
    @State private var confirmApprove = false
    @State private var showWriteSetup = false

    struct LineDraft: Equatable {
        let path: String
        let lineID: Int
        let anchor: CRLineAnchor
        var text = ""
    }

    private var store: ChangeRequestsStore { model.changeRequests }
    private var provider: CIProvider { store.provider }

    var body: some View {
        VStack(spacing: 0) {
            if let detail = store.detail {
                header(detail)
                Divider()
                tabBar(detail)
                Divider()
                Group {
                    switch tab {
                    case .overview: overview(detail)
                    case .files: filesView(detail)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if detail.summary.state == .open {
                    Divider()
                    actionBar(detail)
                }
            } else if let error = store.detailError {
                VStack(spacing: 10) {
                    backButton
                    ContentUnavailableView {
                        Label("Could not load", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("Try again") { Task { await store.reloadDetail() } }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .busyOverlay(store.busy != nil, label: store.busy)
        .sheet(isPresented: $showWriteSetup) {
            VStack(alignment: .trailing, spacing: 0) {
                CITokenSetupView(remote: store.remote, purpose: .changeRequests, writing: true,
                                 onSaved: { showWriteSetup = false })
                Button("Close") { showWriteSetup = false }.keyboardShortcut(.cancelAction).padding([.horizontal, .bottom], 14)
            }
            .frame(width: 520, height: 420)
        }
    }

    @ViewBuilder
    private var backButton: some View {
        if let onBack {
            HStack {
                Button(action: onBack) { Label(provider.changeRequestsName, systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 8)
        }
    }

    // MARK: Header

    private func header(_ d: CRDetail) -> some View {
        let s = d.summary
        return VStack(alignment: .leading, spacing: 8) {
            if let onBack {
                Button(action: onBack) { Label(provider.changeRequestsName, systemImage: "chevron.left") }
                    .buttonStyle(.borderless).scaledFont(.caption)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(s.title).scaledFont(.title3, bold: true).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(provider.changeRequestPrefix)\(s.number)").scaledFont(.title3, mono: true).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { Task { await store.reloadDetail() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload")
                    .disabled(store.loadingDetail)
                if let url = s.webURL {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.borderless).help("Open in \(provider.name)")
                }
            }
            HStack(spacing: 6) {
                Badge(text: s.draft && s.state == .open ? String(localized: "Draft") : s.state.title,
                      symbol: s.state.symbol, tint: s.draft && s.state == .open ? .secondary : s.state.tint)
                Text(s.author).scaledFont(.caption, bold: true)
                Text("wants to merge").scaledFont(.caption).foregroundStyle(.secondary)
                branchChip(s.source)
                Image(systemName: "arrow.right").scaledFont(.caption2).foregroundStyle(.secondary)
                branchChip(s.target)
                if let u = s.updatedAt {
                    Text("· \(u.relativeText)").scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            statusStrip(d)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func branchChip(_ name: String) -> some View {
        Text(name).scaledFont(.caption, mono: true)
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            .textSelection(.enabled)
    }

    private func statusStrip(_ d: CRDetail) -> some View {
        FlowRow {
            mergeBadge(d.mergeability)
            if let p = d.pipelineStatus {
                Badge(text: String(localized: "Pipeline \(CIStatus.label(p))"), symbol: CIStatus.symbol(p), tint: pipelineTint(p))
            }
            if !d.approvedBy.isEmpty {
                Badge(text: String(localized: "Approved by \(d.approvedBy.joined(separator: ", "))"), symbol: "checkmark.seal.fill", tint: .green)
            }
            if !d.changesRequestedBy.isEmpty {
                Badge(text: String(localized: "Changes requested by \(d.changesRequestedBy.joined(separator: ", "))"),
                      symbol: "exclamationmark.bubble.fill", tint: .orange)
            }
        }
    }

    private func pipelineTint(_ s: String) -> Color {
        switch s {
        case "success": .green
        case "failed": .red
        case "running", "pending": .blue
        default: .secondary
        }
    }

    @ViewBuilder
    private func mergeBadge(_ m: CRMergeability) -> some View {
        switch m {
        case .ready: Badge(text: String(localized: "Ready to merge"), symbol: "checkmark.circle.fill", tint: .green)
        case .warning(let w): Badge(text: w, symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .conflict: Badge(text: String(localized: "Merge conflicts"), symbol: "xmark.octagon.fill", tint: .red)
        case .checking: Badge(text: String(localized: "Checking mergeability…"), symbol: "hourglass", tint: .secondary)
        case .blocked(let why): Badge(text: why, symbol: "lock.fill", tint: .orange)
        case .notOpen: EmptyView()
        }
    }

    // MARK: Tabs

    private func tabBar(_ d: CRDetail) -> some View {
        let added = store.files.reduce(0) { $0 + $1.added }, removed = store.files.reduce(0) { $0 + $1.removed }
        return HStack(spacing: 2) {
            PaneTabButton(title: String(localized: "Overview"), symbol: "text.bubble",
                      count: store.comments.filter { $0.kind != .system }.count, selected: tab == .overview) { tab = .overview }
            PaneTabButton(title: String(localized: "Files"), symbol: "doc.on.doc",
                      count: store.files.count, selected: tab == .files) { tab = .files }
            Spacer()
            if tab == .files { LineCounts(added: added, removed: removed) }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    // MARK: Overview

    private func overview(_ d: CRDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    card {
                        commentHeader(author: d.summary.author, date: nil, kind: .comment, note: String(localized: "Description"))
                        if d.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("No description").scaledFont(.callout).italic().foregroundStyle(.secondary)
                        } else {
                            MarkdownBlocks(text: d.body)
                        }
                    }
                    if store.comments.isEmpty {
                        Text("No comments yet").scaledFont(.callout).foregroundStyle(.secondary).padding(.leading, 4)
                    }
                    ForEach(timeline) { entry in
                        timelineEntry(entry)
                    }
                    composer.id("composer")
                }
                .padding(14)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: store.comments.count) { _, _ in
                withAnimation { proxy.scrollTo("composer", anchor: .bottom) }
            }
        }
    }

    private struct TimelineEntry: Identifiable {
        let id: String
        let comments: [CRComment]
    }

    /// Comments in time order; replies of a line comment thread stay together.
    private var timeline: [TimelineEntry] {
        var out: [TimelineEntry] = []
        var seen: [String: Int] = [:]
        for c in store.comments {
            if c.anchor != nil, let t = c.thread {
                if let i = seen[t] { out[i] = TimelineEntry(id: out[i].id, comments: out[i].comments + [c]); continue }
                seen[t] = out.count
            }
            out.append(TimelineEntry(id: c.id, comments: [c]))
        }
        return out
    }

    @ViewBuilder
    private func timelineEntry(_ entry: TimelineEntry) -> some View {
        let first = entry.comments[0]
        if first.kind == .system {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.tertiary)
                Text(first.author).scaledFont(.caption, bold: true)
                Text(first.body).scaledFont(.caption).lineLimit(2)
                if let d = first.createdAt { Text(d.relativeText).scaledFont(.caption2).foregroundStyle(.tertiary) }
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
        } else {
            card(accent: first.kind == .approved ? .green : first.kind == .changesRequested ? .orange : nil) {
                if let a = first.anchor {
                    Button {
                        tab = .files
                        jumpToFile = a.path
                    } label: {
                        Label(a.newLine.map { "\(a.path):\($0)" } ?? a.oldLine.map { "\(a.path):\($0)" } ?? a.path,
                              systemImage: first.outdated ? "clock.arrow.circlepath" : "text.alignleft")
                            .scaledFont(.caption, mono: true)
                    }
                    .buttonStyle(.link)
                    .help(first.outdated ? "This line has changed since the comment" : "Show in the changed files")
                }
                ThreadView(comments: entry.comments, canReply: first.thread != nil,
                           replying: replyBinding(first.thread), replyText: $replyText) {
                    if let t = first.thread { reply(t) }
                }
            }
        }
    }

    private func replyBinding(_ thread: String?) -> Binding<Bool> {
        Binding(get: { thread != nil && replyThread == thread },
                set: { open in
                    if open { replyThread = thread; replyText = "" } else if replyThread == thread { replyThread = nil }
                })
    }

    private var composer: some View {
        card {
            Text("Add a comment").scaledFont(.caption, bold: true).foregroundStyle(.secondary)
            CommentEditor(text: $newComment, placeholder: String(localized: "Write a comment (Markdown)…"), minHeight: 70) {
                postComment()
            }
            HStack {
                Text("⌘↩ to send").scaledFont(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Comment") { postComment() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
    }

    private func card<Content: View>(accent: Color? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder((accent ?? Color.primary).opacity(accent == nil ? 0.08 : 0.5)))
    }

    private func commentHeader(author: String, date: Date?, kind: CRComment.Kind, note: String? = nil) -> some View {
        CommentHeader(author: author, date: date, kind: kind, note: note)
    }

    // MARK: Files

    private func filesView(_ d: CRDetail) -> some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 760
            HStack(spacing: 0) {
                if wide {
                    fileList.frame(width: min(300, geo.size.width * 0.28))
                    Divider()
                }
                diffs(d, showJumpMenu: !wide)
            }
        }
    }

    private var fileList: some View {
        let comments = store.lineComments
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(store.files) { f in
                    HStack(spacing: 6) {
                        Text(f.marker).scaledFont(.caption, bold: true, mono: true)
                            .foregroundStyle(GitView.color(for: f.marker)).frame(width: 12)
                        VStack(alignment: .leading, spacing: 0) {
                            Text((f.path as NSString).lastPathComponent).scaledFont(.callout).lineLimit(1)
                            let dir = (f.path as NSString).deletingLastPathComponent
                            if !dir.isEmpty {
                                Text(dir).scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        }
                        Spacer(minLength: 4)
                        if let n = comments[f.path]?.count, n > 0 {
                            Label("\(n)", systemImage: "bubble.left.fill").scaledFont(.caption2).foregroundStyle(Color.accentColor)
                        }
                        LineCounts(added: f.added, removed: f.removed)
                    }
                    .interactiveRow(selected: jumpToFile == f.path) { jumpToFile = f.path }
                    .help(f.path)
                }
            }
            .padding(6)
        }
    }

    private func diffs(_ d: CRDetail, showJumpMenu: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if showJumpMenu, !store.files.isEmpty {
                        Menu {
                            ForEach(store.files) { f in Button(f.path) { jumpToFile = f.path } }
                        } label: { Label("Jump to file", systemImage: "list.bullet") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    if store.files.isEmpty {
                        Text("No changed files").scaledFont(.callout).foregroundStyle(.secondary).padding()
                    }
                    ForEach(store.files) { f in
                        Section {
                            fileDiff(f, d)
                        } header: {
                            fileHeader(f)
                        }
                        .id(f.path)
                    }
                }
                .padding(10)
            }
            .onChange(of: jumpToFile) { _, path in
                guard let path else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(path, anchor: .top) }
            }
            .task(id: tab) {
                if let path = jumpToFile {
                    try? await Task.sleep(for: .milliseconds(80))
                    proxy.scrollTo(path, anchor: .top)
                }
            }
        }
    }

    private func fileHeader(_ f: CRFile) -> some View {
        HStack(spacing: 6) {
            Text(f.marker).scaledFont(.caption, bold: true, mono: true).foregroundStyle(GitView.color(for: f.marker))
            if f.status == .renamed {
                Text("\(f.oldPath) → \(f.path)").scaledFont(.callout, bold: true, mono: true).lineLimit(1).truncationMode(.head)
            } else {
                Text(f.path).scaledFont(.callout, bold: true, mono: true).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            LineCounts(added: f.added, removed: f.removed)
            Button {
                let url = URL(fileURLWithPath: root).appendingPathComponent(f.path)
                if FileManager.default.fileExists(atPath: url.path) { model.editor.open(url, mode: .file) }
                else { model.toast(String(localized: "The file is not in your working copy")) }
            } label: { Image(systemName: "doc.text") }
                .buttonStyle(.borderless).help("Open the local file in the editor")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.bar, in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }

    @ViewBuilder
    private func fileDiff(_ f: CRFile, _ d: CRDetail) -> some View {
        let lines = store.diffLines[f.path] ?? []
        Group {
            if lines.isEmpty {
                Text(f.diff.isEmpty ? String(localized: "No text diff (binary or too large)") : String(localized: "No changes"))
                    .scaledFont(.caption).foregroundStyle(.secondary).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let threads = ChangeRequestsStore.threads(store.lineComments[f.path] ?? [], in: lines)
                DiffLinesView(lines: lines, onComment: d.summary.state == .open ? { line in startLineComment(f, line) } : nil) { line in
                    lineExtras(f, line, threads[line.id] ?? [])
                }
            }
        }
        .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.1)))
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func lineExtras(_ f: CRFile, _ line: DiffLine, _ threads: [[CRComment]]) -> some View {
        let drafting = lineDraft?.path == f.path && lineDraft?.lineID == line.id
        if !threads.isEmpty || drafting {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(threads, id: \.first!.id) { thread in
                    let t = thread.first?.thread
                    ThreadView(comments: thread, canReply: t != nil && store.detail?.summary.state == .open,
                               replying: replyBinding(t), replyText: $replyText) {
                        if let t { reply(t) }
                    }
                    .padding(10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                }
                if drafting { lineComposer }
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.04))
            .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: 2) }
        }
    }

    private var lineComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            CommentEditor(text: Binding(get: { lineDraft?.text ?? "" }, set: { lineDraft?.text = $0 }),
                          placeholder: String(localized: "Comment on this line…"), minHeight: 56, autofocus: true) {
                postLineComment()
            }
            HStack {
                Spacer()
                Button("Cancel") { lineDraft = nil }
                Button("Comment") { postLineComment() }
                    .buttonStyle(.borderedProminent)
                    .disabled((lineDraft?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.5)))
    }

    // MARK: Actions

    private func actionBar(_ d: CRDetail) -> some View {
        ViewThatFits(in: .horizontal) {
            actionButtons(d, labels: true)
            actionButtons(d, labels: false)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private func actionLabel(_ title: String, _ symbol: String, _ labels: Bool) -> some View {
        Group {
            if labels { Label(title, systemImage: symbol) } else { Image(systemName: symbol) }
        }
        .help(title)
    }

    private func actionButtons(_ d: CRDetail, labels: Bool) -> some View {
        HStack(spacing: 8) {
            Button { onCheckout(d.summary.source) } label: { actionLabel(String(localized: "Check out"), "arrow.down.to.line", labels) }
                .disabled(!d.summary.sameRepository)
            Spacer(minLength: 8)
            if store.writer == nil {
                Button { showWriteSetup = true } label: { actionLabel(String(localized: "Set up write access…"), "key", labels) }
            }
            Button { reviewVerdict = .comment; reviewText = ""; showReview = true } label: {
                actionLabel(String(localized: "Review…"), "text.bubble", labels)
            }
            .popover(isPresented: $showReview, arrowEdge: .top) { reviewPopover }
            Button { confirmApprove = true } label: { actionLabel(String(localized: "Approve"), "checkmark.seal", labels) }
                .confirmationDialog(String(localized: "Approve \(provider.changeRequestPrefix)\(d.summary.number)?"),
                                    isPresented: $confirmApprove) {
                    Button("Approve") { review(.approve, body: "") }
                }
            Button { mergeOptions = CRMergeOptions(); showMerge = true } label: {
                Label(String(localized: "Merge…"), systemImage: "arrow.triangle.merge")
            }
            .buttonStyle(.borderedProminent)
            .tint(d.mergeability.canMerge ? .green : nil)
            .popover(isPresented: $showMerge, arrowEdge: .top) { mergePopover(d) }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private var reviewPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Submit review").scaledFont(.headline)
            Picker("", selection: $reviewVerdict) {
                Text("Comment").tag(CRVerdict.comment)
                Text("Approve").tag(CRVerdict.approve)
                if provider.supportsRequestChanges { Text("Request changes").tag(CRVerdict.requestChanges) }
            }
            .pickerStyle(.radioGroup).labelsHidden()
            CommentEditor(text: $reviewText, placeholder: String(localized: "Summary (Markdown, optional for approving)"), minHeight: 90) {
                submitReview()
            }
            HStack {
                Spacer()
                Button("Cancel") { showReview = false }.keyboardShortcut(.cancelAction)
                Button("Submit") { submitReview() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(reviewVerdict != .approve && reviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16).frame(width: 400)
    }

    private func mergePopover(_ d: CRDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge \(provider.changeRequestPrefix)\(d.summary.number)").scaledFont(.headline)
            HStack(spacing: 4) {
                branchChip(d.summary.source)
                Image(systemName: "arrow.right").scaledFont(.caption2)
                branchChip(d.summary.target)
            }
            mergeBadge(d.mergeability)
            Picker("Method", selection: $mergeOptions.method) {
                ForEach(provider.mergeMethods) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Toggle("Delete the source branch afterwards", isOn: $mergeOptions.deleteSourceBranch)
                .disabled(!d.summary.sameRepository)
            if !d.mergeability.canMerge {
                Text("The server reports that this cannot be merged right now. You can still try – it decides.")
                    .scaledFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Only the reviewed state (\(String(d.refs.head.prefix(8)))) is merged; if the branch moved on, the server refuses.")
                .scaledFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { showMerge = false }.keyboardShortcut(.cancelAction)
                Button("Merge") { merge() }
                    .buttonStyle(.borderedProminent).tint(.green).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 380)
    }

    private func startLineComment(_ f: CRFile, _ line: DiffLine) {
        guard line.kind == .added || line.kind == .removed || line.kind == .context else { return }
        let anchor = CRLineAnchor(path: f.path, oldPath: f.oldPath,
                                  oldLine: line.kind == .added ? nil : line.oldLine,
                                  newLine: line.kind == .removed ? nil : line.newLine)
        lineDraft = LineDraft(path: f.path, lineID: line.id, anchor: anchor)
    }

    private func perform(_ label: String, success: String, _ op: @escaping (any ChangeRequestClient, Int, CRDetail) async throws -> Void,
                         then: @escaping () -> Void = {}) {
        guard store.writer != nil else { showWriteSetup = true; return }
        Task {
            if let error = await store.perform(label, op) {
                model.banner = error
            } else {
                model.toast(success)
                then()
            }
        }
    }

    private func postComment() {
        let body = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        perform(String(localized: "Sending comment…"), success: String(localized: "Comment added")) { api, n, d in
            try await api.addComment(n, body: body, at: nil, refs: d.refs)
        } then: { newComment = "" }
    }

    private func postLineComment() {
        guard let draft = lineDraft else { return }
        let body = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        perform(String(localized: "Sending comment…"), success: String(localized: "Comment added")) { api, n, d in
            try await api.addComment(n, body: body, at: draft.anchor, refs: d.refs)
        } then: { lineDraft = nil }
    }

    private func reply(_ thread: String) {
        let body = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        perform(String(localized: "Sending reply…"), success: String(localized: "Reply added")) { api, n, _ in
            try await api.reply(n, thread: thread, body: body)
        } then: { replyThread = nil; replyText = "" }
    }

    private func review(_ verdict: CRVerdict, body: String) {
        let success = switch verdict {
        case .approve: String(localized: "Approved")
        case .requestChanges: String(localized: "Changes requested")
        case .comment: String(localized: "Review submitted")
        }
        perform(String(localized: "Submitting review…"), success: success) { api, n, _ in
            try await api.review(n, verdict: verdict, body: body)
        } then: { showReview = false }
    }

    private func submitReview() {
        guard reviewVerdict == .approve || !reviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        review(reviewVerdict, body: reviewText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func merge() {
        let options = mergeOptions
        showMerge = false
        perform(String(localized: "Merging…"), success: String(localized: "Merged")) { api, n, d in
            try await api.merge(n, options: options, detail: d)
        } then: { model.workspace.refreshNow() }
    }
}

// MARK: Building blocks

/// A tab in a pane's own tab row; `compact` shows only the symbol (narrow panes).
struct PaneTabButton: View {
    let title: String
    let symbol: String
    let count: Int
    let selected: Bool
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                if !compact { Text(title).lineLimit(1) }
                if count > 0 {
                    Text("\(count)").scaledFont(.caption2, digits: true)
                        .padding(.horizontal, 5).background(Color.primary.opacity(0.1), in: Capsule())
                }
            }
            .scaledFont(.callout, bold: selected)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

struct CommentHeader: View {
    let author: String
    let date: Date?
    let kind: CRComment.Kind
    var note: String?

    var body: some View {
        HStack(spacing: 6) {
            Avatar(name: author)
            Text(author).scaledFont(.callout, bold: true)
            switch kind {
            case .approved: Badge(text: String(localized: "approved"), symbol: "checkmark.seal.fill", tint: .green)
            case .changesRequested: Badge(text: String(localized: "requested changes"), symbol: "exclamationmark.bubble.fill", tint: .orange)
            default: EmptyView()
            }
            if let note { Text(note).scaledFont(.caption).foregroundStyle(.secondary) }
            if let date { Text(date.relativeText).scaledFont(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
    }
}

/// Initials in a coloured circle; the colour follows the name.
struct Avatar: View {
    let name: String
    var body: some View {
        let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Color(hue: hue, saturation: 0.5, brightness: 0.75), in: Circle())
    }
}

/// One comment thread with an optional inline reply box.
struct ThreadView: View {
    let comments: [CRComment]
    let canReply: Bool
    @Binding var replying: Bool
    @Binding var replyText: String
    let onReply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(comments) { c in
                VStack(alignment: .leading, spacing: 5) {
                    CommentHeader(author: c.author, date: c.createdAt, kind: c.kind)
                    if !c.body.isEmpty {
                        MarkdownBlocks(text: c.body).padding(.leading, 26)
                    }
                }
            }
            if canReply {
                if replying {
                    CommentEditor(text: $replyText, placeholder: String(localized: "Reply…"), minHeight: 50, autofocus: true, onSubmit: onReply)
                    HStack {
                        Spacer()
                        Button("Cancel") { replying = false }
                        Button("Reply", action: onReply).buttonStyle(.borderedProminent)
                            .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .controlSize(.small)
                } else {
                    Button { replying = true } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                        .buttonStyle(.borderless).scaledFont(.caption)
                }
            }
        }
    }
}

/// Multi-line text field for comments; ⌘↩ sends.
struct CommentEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 60
    var autofocus = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .focused($focused)
            .frame(minHeight: minHeight, maxHeight: max(minHeight, 240))
            .fixedSize(horizontal: false, vertical: true)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.15)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(.system(size: 13)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                }
            }
            .background {
                Button("", action: onSubmit).keyboardShortcut(.return, modifiers: .command).hidden()
            }
            .onAppear { if autofocus { focused = true } }
    }
}

/// Lays children out left to right and wraps to the next row when space runs out.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if size.width == 0 && size.height == 0 { continue }
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > maxWidth, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].items.isEmpty ? 0 : spacing
            rows[rows.count - 1].items.append(i)
            rows[rows.count - 1].width += size.width + gap
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
