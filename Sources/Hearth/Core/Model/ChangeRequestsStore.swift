import Foundation
import Observation

/// Merge/pull requests of the workspace repository for the Git pane: the list, the one
/// being reviewed (description, files, comments) and the actions on it.
/// The view only draws it; everything here runs with fakes in the tests.
@MainActor
@Observable
final class ChangeRequestsStore {
    struct Dependencies {
        var detectRemote: (String) async -> CIRemote?
        var loadCredentials: (CIOrigin) async -> Void
        /// A client with the read (false) or the separate write (true) token, nil until approved.
        var client: (CIRemote, Bool) -> (any ChangeRequestClient)?
    }

    private(set) var root = ""
    private(set) var remote: CIRemote?
    private(set) var remoteChecked = false

    var filter: CRState = .open
    private(set) var list: [CRSummary] = []
    private(set) var listLoaded = false
    private(set) var loadingList = false
    var listError: String?

    private(set) var selected: Int?
    private(set) var detail: CRDetail?
    private(set) var files: [CRFile] = []
    private(set) var comments: [CRComment] = []
    /// Parsed diff per file path (parsed once per load, not on every redraw).
    private(set) var diffLines: [String: [DiffLine]] = [:]
    private(set) var loadingDetail = false
    var detailError: String?
    /// The running write action ("Merging…"), nil when idle.
    private(set) var busy: String?

    @ObservationIgnored private let deps: Dependencies

    init(_ deps: Dependencies) { self.deps = deps }

    var reader: (any ChangeRequestClient)? { remote.flatMap { deps.client($0, false) } }
    var writer: (any ChangeRequestClient)? { remote.flatMap { deps.client($0, true) } }
    var provider: CIProvider { remote?.provider ?? .gitLab }

    /// Line comments of the open change request per file path.
    var lineComments: [String: [CRComment]] {
        Dictionary(grouping: comments.filter { $0.anchor != nil && !$0.outdated }, by: { $0.anchor!.path })
    }

    /// Line comment threads of one file, keyed by the id of the diff line they belong to.
    /// Comments whose line is not in the diff (any more) are left out.
    nonisolated static func threads(_ comments: [CRComment], in lines: [DiffLine]) -> [Int: [[CRComment]]] {
        var byLine: [Int: [CRComment]] = [:]
        for c in comments {
            guard let a = c.anchor, let line = lines.first(where: { l in
                if let n = a.newLine { return l.newLine == n && l.kind != .removed }
                if let o = a.oldLine { return l.oldLine == o && l.kind == .removed }
                return false
            }) else { continue }
            byLine[line.id, default: []].append(c)
        }
        return byLine.mapValues { list in
            var order: [String] = []
            var groups: [String: [CRComment]] = [:]
            for c in list {
                let key = c.thread ?? c.id
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(c)
            }
            return order.compactMap { groups[$0] }
        }
    }

    /// Comments shown in the conversation: general ones, reviews, and line comments whose line is gone.
    var conversation: [CRComment] { comments.filter { $0.anchor == nil || $0.outdated } }

    func open(root: String) async {
        guard root != self.root || !remoteChecked else { return }
        self.root = root
        remoteChecked = false
        remote = nil
        clear()
        let detected = await deps.detectRemote(root)
        guard !Task.isCancelled, self.root == root else { return }
        if let detected { await deps.loadCredentials(detected.origin) }
        guard !Task.isCancelled, self.root == root else { return }
        remote = detected
        remoteChecked = true
    }

    func clear() {
        list = []
        listLoaded = false
        listError = nil
        closeDetail()
    }

    func refreshList() async {
        guard let api = reader else { return }
        let root = root, filter = filter
        loadingList = true
        defer { loadingList = false }
        do {
            let result = try await api.changeRequests(state: filter)
            guard !Task.isCancelled, self.root == root, self.filter == filter else { return }
            list = result
            listLoaded = true
            listError = nil
        } catch {
            guard !Task.isCancelled else { return }
            listError = CRError.describe(error, provider: api.remote.provider, writing: false)
        }
    }

    func select(_ number: Int?) async {
        guard number != selected || detail == nil else { return }
        selected = number
        detail = nil
        files = []
        comments = []
        diffLines = [:]
        detailError = nil
        guard number != nil else { return }
        await reloadDetail()
    }

    func closeDetail() {
        selected = nil
        detail = nil
        files = []
        comments = []
        diffLines = [:]
        detailError = nil
    }

    func reloadDetail() async {
        guard let api = reader, let number = selected else { return }
        loadingDetail = true
        defer { loadingDetail = false }
        do {
            async let d = api.changeRequest(number)
            async let f = api.changeRequestFiles(number)
            async let c = api.changeRequestComments(number)
            let (detail, files, comments) = try await (d, f, c)
            guard !Task.isCancelled, selected == number else { return }
            self.detail = detail
            self.files = files
            self.comments = comments
            diffLines = Dictionary(files.map { ($0.path, UnifiedDiff.parse($0.diff)) }, uniquingKeysWith: { a, _ in a })
            detailError = nil
            // Keep the list entry in step (title, draft, state may have changed).
            if let i = list.firstIndex(where: { $0.number == number }) { list[i] = detail.summary }
        } catch {
            guard !Task.isCancelled, selected == number else { return }
            detailError = CRError.describe(error, provider: api.remote.provider, writing: false)
        }
    }

    /// Runs a write action on the open change request with the write token, then reloads it.
    /// Returns nil on success, else the message to show.
    @discardableResult
    func perform(_ label: String, _ op: @escaping (any ChangeRequestClient, Int, CRDetail) async throws -> Void) async -> String? {
        guard let detail, let number = selected else { return String(localized: "Nothing selected.") }
        guard let api = writer else {
            return String(localized: "Please approve separate write access for this \(provider.name) server first.")
        }
        busy = label
        defer { busy = nil }
        do {
            try await op(api, number, detail)
        } catch {
            return CRError.describe(error, provider: api.remote.provider, writing: true)
        }
        await reloadDetail()
        if detail.summary.state != self.detail?.summary.state { await refreshList() }
        return nil
    }

    /// Developer aid (snapshots): shows the given data without a server.
    func showSample(remote: CIRemote, list: [CRSummary], detail: CRDetail, files: [CRFile], comments: [CRComment]) {
        root = "sample"
        self.remote = remote
        remoteChecked = true
        self.list = list
        listLoaded = true
        selected = detail.summary.number
        self.detail = detail
        self.files = files
        self.comments = comments
        diffLines = Dictionary(files.map { ($0.path, UnifiedDiff.parse($0.diff)) }, uniquingKeysWith: { a, _ in a })
    }
}
