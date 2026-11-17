import Foundation

// Merge requests (GitLab) and pull requests (GitHub): listing, reviewing, commenting and
// merging through the provider's API. Reading uses the read token, every write the
// separately approved write token (see CIAccounts).

enum CRState: String, CaseIterable, Identifiable, Sendable {
    case open, merged, closed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .open: String(localized: "Open")
        case .merged: String(localized: "Merged")
        case .closed: String(localized: "Closed")
        }
    }
}

struct CRSummary: Identifiable, Hashable, Sendable {
    let number: Int
    let title: String
    let author: String
    let source: String
    let target: String
    let state: CRState
    let draft: Bool
    let updatedAt: Date?
    let webURL: URL?
    /// The source branch lives in this repository (not a fork), so it can be deleted after merging.
    var sameRepository = true
    var id: Int { number }
}

/// Whether the provider would merge now, in words the pane can show.
enum CRMergeability: Hashable, Sendable {
    case ready
    /// Mergeable, but something deserves a look first (e.g. failing checks on GitHub).
    case warning(String)
    case conflict
    case checking
    case blocked(String)
    case notOpen

    var canMerge: Bool {
        switch self {
        case .ready, .warning: true
        default: false
        }
    }
}

/// The commits a line comment refers to (GitLab needs all three, GitHub the head).
struct CRDiffRefs: Hashable, Sendable {
    var base = ""
    var start = ""
    var head = ""
}

struct CRDetail: Sendable {
    var summary: CRSummary
    var body: String
    var mergeability: CRMergeability
    var refs: CRDiffRefs
    var approvedBy: [String] = []
    var changesRequestedBy: [String] = []
    /// GitLab's head pipeline status (CIStatus vocabulary), nil when unknown.
    var pipelineStatus: String?
}

/// A line in a change request's diff a comment belongs to.
struct CRLineAnchor: Hashable, Sendable {
    var path: String
    var oldPath: String
    var oldLine: Int?
    var newLine: Int?
}

struct CRComment: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case comment, approved, changesRequested, system }
    let id: String
    let author: String
    let body: String
    let createdAt: Date?
    var kind: Kind = .comment
    var anchor: CRLineAnchor?
    /// Thread to reply to (GitLab discussion id, GitHub root review comment id).
    var thread: String?
    /// The commented line is no longer part of the current diff.
    var outdated = false
}

struct CRFile: Identifiable, Hashable, Sendable {
    enum Status: String, Sendable { case added, removed, renamed, modified }
    let path: String
    let oldPath: String
    let status: Status
    /// Unified diff hunks ("@@ … @@" onwards), empty for binary or very large files.
    let diff: String
    let added: Int
    let removed: Int
    var id: String { path }

    var marker: String {
        switch status {
        case .added: "A"
        case .removed: "D"
        case .renamed: "R"
        case .modified: "M"
        }
    }

    static func counts(_ diff: String) -> (added: Int, removed: Int) {
        UnifiedDiff.parse(diff).reduce(into: (0, 0)) { acc, line in
            if line.kind == .added { acc.0 += 1 } else if line.kind == .removed { acc.1 += 1 }
        }
    }
}

enum CRVerdict: Sendable { case approve, requestChanges, comment }

enum CRMergeMethod: String, CaseIterable, Identifiable, Sendable {
    case merge, squash, rebase
    var id: String { rawValue }
    var title: String {
        switch self {
        case .merge: String(localized: "Merge commit")
        case .squash: String(localized: "Squash and merge")
        case .rebase: String(localized: "Rebase and merge")
        }
    }
}

struct CRMergeOptions: Sendable {
    var method: CRMergeMethod = .merge
    var deleteSourceBranch = false
}

/// The change request operations the Git pane uses, for GitLab and GitHub alike.
protocol ChangeRequestClient: Sendable {
    var remote: CIRemote { get }
    func changeRequests(state: CRState) async throws -> [CRSummary]
    func changeRequest(_ number: Int) async throws -> CRDetail
    func changeRequestFiles(_ number: Int) async throws -> [CRFile]
    func changeRequestComments(_ number: Int) async throws -> [CRComment]
    /// A general comment, or one on a diff line when `anchor` is set.
    func addComment(_ number: Int, body: String, at anchor: CRLineAnchor?, refs: CRDiffRefs) async throws
    func reply(_ number: Int, thread: String, body: String) async throws
    func review(_ number: Int, verdict: CRVerdict, body: String) async throws
    func merge(_ number: Int, options: CRMergeOptions, detail: CRDetail) async throws
}

extension CIProvider {
    /// What a change request is called there.
    var changeRequestName: String { self == .gitLab ? String(localized: "Merge request") : String(localized: "Pull request") }
    var changeRequestsName: String { self == .gitLab ? String(localized: "Merge requests") : String(localized: "Pull requests") }
    var changeRequestPrefix: String { self == .gitLab ? "!" : "#" }
    /// GitLab has no "request changes" review through the API.
    var supportsRequestChanges: Bool { self == .gitHub }
    var mergeMethods: [CRMergeMethod] { self == .gitHub ? CRMergeMethod.allCases : [.merge, .squash] }
}

extension CIRemote {
    func changeRequestClient(_ credential: CICredential) -> any ChangeRequestClient {
        switch provider {
        case .gitLab: GitLabAPI(remote: self, credential: credential)
        case .gitHub: GitHubAPI(remote: self, credential: credential)
        }
    }
}

enum CRError {
    /// Provider errors in terms of change requests (the CI messages talk about pipelines).
    static func describe(_ error: Error, provider: CIProvider, writing: Bool) -> String {
        if let e = error as? GitHubAPI.APIError {
            switch e {
            case .http(403, _), .http(404, _):
                return writing
                    ? String(localized: "GitHub refused (403/404). The write token needs “Pull requests: Read and write” – and “Contents: Read and write” to merge.")
                    : String(localized: "GitHub refused (403/404). The read token needs “Pull requests: Read-only” for this repository.")
            case .http(405, let body), .http(409, let body):
                return String(localized: "GitHub cannot merge this pull request: \(GitHubAPI.message(body))")
            case .http(422, let body):
                return String(localized: "GitHub rejects the request: \(GitHubAPI.message(body))")
            case .readOnly:
                return String(localized: "For this, approve a separate write token with “Pull requests: Read and write” for this server.")
            default: break
            }
        }
        if let e = error as? GitLabAPI.APIError {
            switch e {
            case .http(403, _):
                return String(localized: "GitLab refused (403). This needs a token with the “api” scope and at least Developer access.")
            case .http(405, _), .http(406, _), .http(409, _), .http(422, _):
                if case .http(_, let body) = e { return String(localized: "GitLab cannot do this right now: \(GitHubAPI.message(body))") }
            case .readOnly:
                return String(localized: "For this, approve a separate write token with the “api” scope for this server.")
            default: break
            }
        }
        return error.localizedDescription
    }
}

// MARK: Unified diff

struct DiffLine: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case meta, hunk, context, added, removed, note }
    let id: Int
    let kind: Kind
    /// The line without its +/-/space prefix (the full line for meta and hunk lines).
    let text: String
    var oldLine: Int?
    var newLine: Int?
}

enum UnifiedDiff {
    /// Parses `git diff` output or bare hunks (GitLab/GitHub API) into numbered lines.
    static func parse(_ text: String) -> [DiffLine] {
        var out: [DiffLine] = []
        var old = 0, new = 0, oldLeft = 0, newLeft = 0
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, raw) in lines.enumerated() {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            if i == lines.count - 1, line.isEmpty { break }
            if line.hasPrefix("@@"), let h = hunkHeader(line) {
                old = h.old; new = h.new; oldLeft = h.oldCount; newLeft = h.newCount
                out.append(DiffLine(id: out.count, kind: .hunk, text: line))
                continue
            }
            let inHunk = oldLeft > 0 || newLeft > 0
            if line.hasPrefix("\\") {
                out.append(DiffLine(id: out.count, kind: .note, text: line))
            } else if inHunk, line.hasPrefix("+") {
                out.append(DiffLine(id: out.count, kind: .added, text: String(line.dropFirst()), newLine: new))
                new += 1; newLeft -= 1
            } else if inHunk, line.hasPrefix("-") {
                out.append(DiffLine(id: out.count, kind: .removed, text: String(line.dropFirst()), oldLine: old))
                old += 1; oldLeft -= 1
            } else if inHunk, line.hasPrefix(" ") || line.isEmpty {
                out.append(DiffLine(id: out.count, kind: .context, text: String(line.dropFirst()), oldLine: old, newLine: new))
                old += 1; new += 1; oldLeft -= 1; newLeft -= 1
            } else {
                oldLeft = 0; newLeft = 0
                out.append(DiffLine(id: out.count, kind: .meta, text: line))
            }
        }
        return out
    }

    /// "@@ -12,5 +12,7 @@ func x()" → (12, 5, 12, 7); a missing count means 1.
    static func hunkHeader(_ line: String) -> (old: Int, oldCount: Int, new: Int, newCount: Int)? {
        guard let m = line.range(of: #"^@@ -\d+(,\d+)? \+\d+(,\d+)? @@"#, options: .regularExpression) else { return nil }
        // "-12,5 +12,7"
        let ranges = line[m].dropFirst(3).dropLast(3).split(separator: " ")
        func pair(_ s: Substring) -> (Int, Int)? {
            let p = s.dropFirst().split(separator: ",")
            guard let start = p.first.flatMap({ Int($0) }) else { return nil }
            return (start, p.count > 1 ? Int(p[1]) ?? 1 : 1)
        }
        guard ranges.count == 2, let o = pair(ranges[0]), let n = pair(ranges[1]) else { return nil }
        return (o.0, o.1, n.0, n.1)
    }
}

// MARK: GitLab

extension GitLabAPI: ChangeRequestClient {
    static func state(_ s: String?) -> CRState {
        switch s {
        case "merged": .merged
        case "closed", "locked": .closed
        default: .open
        }
    }

    static func summary(_ j: JSON) -> CRSummary? {
        guard let iid = j["iid"]?.double.map(Int.init) else { return nil }
        return CRSummary(number: iid, title: j["title"]?.string ?? "", author: j["author"]?["username"]?.string ?? "",
                         source: j["source_branch"]?.string ?? "", target: j["target_branch"]?.string ?? "",
                         state: state(j["state"]?.string),
                         draft: j["draft"] == .bool(true) || j["work_in_progress"] == .bool(true),
                         updatedAt: j["updated_at"]?.string.flatMap(ISO8601.date),
                         webURL: j["web_url"]?.string.flatMap(URL.init(string:)),
                         sameRepository: j["source_project_id"] == nil || j["source_project_id"] == j["target_project_id"])
    }

    static func mergeability(_ j: JSON, state: CRState) -> CRMergeability {
        guard state == .open else { return .notOpen }
        switch j["detailed_merge_status"]?.string {
        case "mergeable": return .ready
        case "conflict": return .conflict
        case "checking", "unchecked", "preparing", "approvals_syncing": return .checking
        case "draft_status": return .blocked(String(localized: "Marked as draft"))
        case "not_approved": return .blocked(String(localized: "Approvals missing"))
        case "discussions_not_resolved": return .blocked(String(localized: "Unresolved threads"))
        case "ci_must_pass", "status_checks_must_pass": return .blocked(String(localized: "Pipeline must succeed first"))
        case "ci_still_running": return .blocked(String(localized: "Pipeline still running"))
        case "need_rebase": return .blocked(String(localized: "Needs a rebase onto the target branch"))
        case "requested_changes": return .blocked(String(localized: "Changes were requested"))
        case .some(let other): return .blocked(other.replacingOccurrences(of: "_", with: " "))
        case nil:
            if j["has_conflicts"] == .bool(true) { return .conflict }
            switch j["merge_status"]?.string {
            case "can_be_merged": return .ready
            case "cannot_be_merged": return .conflict
            default: return .checking
            }
        }
    }

    private func mr(_ number: Int) -> String { "/projects/\(project)/merge_requests/\(number)" }

    func changeRequests(state: CRState) async throws -> [CRSummary] {
        let s = state == .open ? "opened" : state.rawValue
        let data = try await request("GET", "/projects/\(project)/merge_requests", query: [
            URLQueryItem(name: "state", value: s), URLQueryItem(name: "per_page", value: "50"),
            URLQueryItem(name: "order_by", value: "updated_at")])
        return (JSON.parse(data)?.array ?? []).compactMap(Self.summary)
    }

    func changeRequest(_ number: Int) async throws -> CRDetail {
        let j = JSON.parse(try await request("GET", mr(number))) ?? .null
        guard let summary = Self.summary(j) else { throw APIError.http(502, "no merge request in response") }
        var detail = CRDetail(summary: summary, body: j["description"]?.string ?? "",
                              mergeability: Self.mergeability(j, state: summary.state),
                              refs: CRDiffRefs(base: j["diff_refs"]?["base_sha"]?.string ?? "",
                                               start: j["diff_refs"]?["start_sha"]?.string ?? "",
                                               head: j["diff_refs"]?["head_sha"]?.string ?? j["sha"]?.string ?? ""),
                              pipelineStatus: j["head_pipeline"]?["status"]?.string ?? j["pipeline"]?["status"]?.string)
        // Approvals are optional (older servers, missing rights): the rest still shows.
        if let a = try? await request("GET", mr(number) + "/approvals"), let aj = JSON.parse(a) {
            detail.approvedBy = aj["approved_by"]?.array.compactMap { $0["user"]?["username"]?.string } ?? []
        }
        return detail
    }

    func changeRequestFiles(_ number: Int) async throws -> [CRFile] {
        let list: [JSON]
        do {
            let data = try await request("GET", mr(number) + "/diffs", query: [URLQueryItem(name: "per_page", value: "100")])
            list = JSON.parse(data)?.array ?? []
        } catch APIError.http(404, _) {
            // Before GitLab 15.7: the older endpoint with all changes at once.
            list = JSON.parse(try await request("GET", mr(number) + "/changes"))?["changes"]?.array ?? []
        }
        return list.map { f in
            let diff = f["diff"]?.string ?? ""
            let counts = CRFile.counts(diff)
            let status: CRFile.Status = f["new_file"] == .bool(true) ? .added : f["deleted_file"] == .bool(true) ? .removed
                : f["renamed_file"] == .bool(true) ? .renamed : .modified
            let path = f["new_path"]?.string ?? ""
            return CRFile(path: path, oldPath: f["old_path"]?.string ?? path, status: status, diff: diff,
                          added: counts.added, removed: counts.removed)
        }
    }

    func changeRequestComments(_ number: Int) async throws -> [CRComment] {
        let data = try await request("GET", mr(number) + "/discussions", query: [URLQueryItem(name: "per_page", value: "100")])
        return (JSON.parse(data)?.array ?? []).flatMap { d -> [CRComment] in
            let thread = d["individual_note"] == .bool(true) ? nil : d["id"]?.string
            return d["notes"]?.array.compactMap { n in
                guard let id = n["id"]?.double.map(Int.init) else { return nil }
                let p = n["position"]
                let anchor = p.flatMap { p -> CRLineAnchor? in
                    guard let path = p["new_path"]?.string ?? p["old_path"]?.string else { return nil }
                    return CRLineAnchor(path: path, oldPath: p["old_path"]?.string ?? path,
                                        oldLine: p["old_line"]?.double.map(Int.init), newLine: p["new_line"]?.double.map(Int.init))
                }
                let system = n["system"] == .bool(true)
                let body = n["body"]?.string ?? ""
                let kind: CRComment.Kind = !system ? .comment : body == "approved this merge request" ? .approved : .system
                return CRComment(id: "\(id)", author: n["author"]?["username"]?.string ?? "", body: body,
                                 createdAt: n["created_at"]?.string.flatMap(ISO8601.date), kind: kind,
                                 anchor: anchor, thread: system ? nil : thread)
            } ?? []
        }
    }

    func addComment(_ number: Int, body: String, at anchor: CRLineAnchor?, refs: CRDiffRefs) async throws {
        guard let anchor else {
            _ = try await request("POST", mr(number) + "/notes", body: ["body": body])
            return
        }
        var position: [String: Any] = ["position_type": "text", "base_sha": refs.base, "start_sha": refs.start,
                                       "head_sha": refs.head, "new_path": anchor.path, "old_path": anchor.oldPath]
        if let l = anchor.newLine { position["new_line"] = l }
        if let l = anchor.oldLine { position["old_line"] = l }
        _ = try await request("POST", mr(number) + "/discussions", body: ["body": body, "position": position])
    }

    func reply(_ number: Int, thread: String, body: String) async throws {
        guard thread.range(of: #"^[0-9a-f]{8,64}$"#, options: .regularExpression) != nil else { throw APIError.http(422, "invalid thread") }
        _ = try await request("POST", mr(number) + "/discussions/\(thread)/notes", body: ["body": body])
    }

    func review(_ number: Int, verdict: CRVerdict, body: String) async throws {
        switch verdict {
        case .approve:
            _ = try await request("POST", mr(number) + "/approve")
        case .requestChanges:
            throw APIError.http(422, String(localized: "GitLab has no “request changes” through the API. Leave a comment instead."))
        case .comment:
            break
        }
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try await request("POST", mr(number) + "/notes", body: ["body": body])
        }
    }

    func merge(_ number: Int, options: CRMergeOptions, detail: CRDetail) async throws {
        var body: [String: Any] = ["squash": options.method == .squash,
                                   "should_remove_source_branch": options.deleteSourceBranch]
        // Only merges what was reviewed: GitLab refuses if the branch moved on in the meantime.
        if !detail.refs.head.isEmpty { body["sha"] = detail.refs.head }
        _ = try await request("PUT", mr(number) + "/merge", body: body)
    }
}

// MARK: GitHub

extension GitHubAPI: ChangeRequestClient {
    /// The "message" of a GitHub/GitLab error body, else the body itself (shortened).
    static func message(_ body: String) -> String {
        if let j = JSON.parse(Data(body.utf8)) {
            if let m = j["message"]?.string { return m }
            if let m = j["message"]?.array.compactMap(\.string).first { return m }
            if let e = j["error"]?.string { return e }
        }
        return String(body.prefix(160))
    }

    static func summary(_ j: JSON, repo: String) -> CRSummary? {
        guard let n = j["number"]?.double.map(Int.init) else { return nil }
        let merged = j["merged_at"]?.string != nil || j["merged"] == .bool(true)
        let state: CRState = j["state"]?.string == "open" ? .open : merged ? .merged : .closed
        let headRepo = j["head"]?["repo"]?["full_name"]?.string
        return CRSummary(number: n, title: j["title"]?.string ?? "", author: j["user"]?["login"]?.string ?? "",
                         source: j["head"]?["ref"]?.string ?? "", target: j["base"]?["ref"]?.string ?? "",
                         state: state, draft: j["draft"] == .bool(true),
                         updatedAt: j["updated_at"]?.string.flatMap(ISO8601.date),
                         webURL: j["html_url"]?.string.flatMap(URL.init(string:)),
                         sameRepository: headRepo.map { $0.lowercased() == repo.lowercased() } ?? false)
    }

    static func mergeability(_ j: JSON, state: CRState) -> CRMergeability {
        guard state == .open else { return .notOpen }
        if j["draft"] == .bool(true) { return .blocked(String(localized: "Marked as draft")) }
        switch j["mergeable_state"]?.string {
        case "clean", "has_hooks": return .ready
        case "unstable": return .warning(String(localized: "Some checks are failing"))
        case "dirty": return .conflict
        case "blocked": return .blocked(String(localized: "Required reviews or checks are missing"))
        case "behind": return .blocked(String(localized: "Branch is behind the target branch"))
        case "draft": return .blocked(String(localized: "Marked as draft"))
        default:
            switch j["mergeable"] {
            case .bool(true): return .ready
            case .bool(false): return .conflict
            default: return .checking
            }
        }
    }

    private func pr(_ number: Int) -> String { "/repos/\(repo)/pulls/\(number)" }

    func changeRequests(state: CRState) async throws -> [CRSummary] {
        // GitHub only knows open/closed; merged ones are closed ones with a merge date.
        let data = try await request("GET", "/repos/\(repo)/pulls", query: [
            URLQueryItem(name: "state", value: state == .open ? "open" : "closed"),
            URLQueryItem(name: "sort", value: "updated"), URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "per_page", value: "50")])
        return (JSON.parse(data)?.array ?? []).compactMap { Self.summary($0, repo: repo) }.filter { $0.state == state }
    }

    func changeRequest(_ number: Int) async throws -> CRDetail {
        let j = JSON.parse(try await request("GET", pr(number))) ?? .null
        guard let summary = Self.summary(j, repo: repo) else { throw APIError.http(502, "no pull request in response") }
        var detail = CRDetail(summary: summary, body: j["body"]?.string ?? "",
                              mergeability: Self.mergeability(j, state: summary.state),
                              refs: CRDiffRefs(base: j["base"]?["sha"]?.string ?? "", start: j["base"]?["sha"]?.string ?? "",
                                               head: j["head"]?["sha"]?.string ?? ""))
        if let r = try? await request("GET", pr(number) + "/reviews", query: [URLQueryItem(name: "per_page", value: "100")]) {
            let verdicts = Self.latestVerdicts(JSON.parse(r)?.array ?? [])
            detail.approvedBy = verdicts.filter { $0.value == "APPROVED" }.map(\.key).sorted()
            detail.changesRequestedBy = verdicts.filter { $0.value == "CHANGES_REQUESTED" }.map(\.key).sorted()
        }
        return detail
    }

    /// Each reviewer's latest approving / change-requesting / dismissed review.
    static func latestVerdicts(_ reviews: [JSON]) -> [String: String] {
        var out: [String: String] = [:]
        for r in reviews {
            guard let user = r["user"]?["login"]?.string, let state = r["state"]?.string,
                  ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains(state) else { continue }
            out[user] = state
        }
        return out
    }

    func changeRequestFiles(_ number: Int) async throws -> [CRFile] {
        let data = try await request("GET", pr(number) + "/files", query: [URLQueryItem(name: "per_page", value: "100")])
        return (JSON.parse(data)?.array ?? []).compactMap { f in
            guard let path = f["filename"]?.string else { return nil }
            let status: CRFile.Status = switch f["status"]?.string {
            case "added": .added
            case "removed": .removed
            case "renamed": .renamed
            default: .modified
            }
            return CRFile(path: path, oldPath: f["previous_filename"]?.string ?? path, status: status,
                          diff: f["patch"]?.string ?? "",
                          added: f["additions"]?.double.map(Int.init) ?? 0, removed: f["deletions"]?.double.map(Int.init) ?? 0)
        }
    }

    func changeRequestComments(_ number: Int) async throws -> [CRComment] {
        let page = [URLQueryItem(name: "per_page", value: "100")]
        async let issueData = request("GET", "/repos/\(repo)/issues/\(number)/comments", query: page)
        async let reviewData = request("GET", pr(number) + "/reviews", query: page)
        async let lineData = request("GET", pr(number) + "/comments", query: page)
        var out: [CRComment] = []
        for c in JSON.parse(try await issueData)?.array ?? [] {
            guard let id = c["id"]?.double.map(Int.init) else { continue }
            out.append(CRComment(id: "i\(id)", author: c["user"]?["login"]?.string ?? "", body: c["body"]?.string ?? "",
                                 createdAt: c["created_at"]?.string.flatMap(ISO8601.date)))
        }
        for r in JSON.parse(try await reviewData)?.array ?? [] {
            guard let id = r["id"]?.double.map(Int.init) else { continue }
            let body = r["body"]?.string ?? ""
            let kind: CRComment.Kind = switch r["state"]?.string {
            case "APPROVED": .approved
            case "CHANGES_REQUESTED": .changesRequested
            default: .comment
            }
            // Plain "commented" reviews without text only wrap line comments, which show on their own.
            if kind == .comment && body.isEmpty { continue }
            out.append(CRComment(id: "r\(id)", author: r["user"]?["login"]?.string ?? "", body: body,
                                 createdAt: r["submitted_at"]?.string.flatMap(ISO8601.date), kind: kind))
        }
        for c in JSON.parse(try await lineData)?.array ?? [] {
            guard let id = c["id"]?.double.map(Int.init), let path = c["path"]?.string else { continue }
            let line = c["line"]?.double.map(Int.init)
            let left = c["side"]?.string == "LEFT"
            let root = c["in_reply_to_id"]?.double.map(Int.init) ?? id
            out.append(CRComment(id: "c\(id)", author: c["user"]?["login"]?.string ?? "", body: c["body"]?.string ?? "",
                                 createdAt: c["created_at"]?.string.flatMap(ISO8601.date),
                                 anchor: CRLineAnchor(path: path, oldPath: path, oldLine: left ? line : nil, newLine: left ? nil : line),
                                 thread: "\(root)", outdated: line == nil))
        }
        return out.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    func addComment(_ number: Int, body: String, at anchor: CRLineAnchor?, refs: CRDiffRefs) async throws {
        guard let anchor else {
            _ = try await request("POST", "/repos/\(repo)/issues/\(number)/comments", body: ["body": body])
            return
        }
        let right = anchor.newLine != nil
        guard let line = anchor.newLine ?? anchor.oldLine else { throw APIError.http(422, "no line") }
        _ = try await request("POST", pr(number) + "/comments", body: [
            "body": body, "commit_id": refs.head, "path": anchor.path, "line": line, "side": right ? "RIGHT" : "LEFT"])
    }

    func reply(_ number: Int, thread: String, body: String) async throws {
        guard let id = Int(thread) else { throw APIError.http(422, "invalid thread") }
        _ = try await request("POST", pr(number) + "/comments/\(id)/replies", body: ["body": body])
    }

    func review(_ number: Int, verdict: CRVerdict, body: String) async throws {
        let event = switch verdict {
        case .approve: "APPROVE"
        case .requestChanges: "REQUEST_CHANGES"
        case .comment: "COMMENT"
        }
        _ = try await request("POST", pr(number) + "/reviews", body: ["event": event, "body": body])
    }

    func merge(_ number: Int, options: CRMergeOptions, detail: CRDetail) async throws {
        var body: [String: Any] = ["merge_method": options.method.rawValue]
        // Only merges what was reviewed: GitHub refuses if the branch moved on in the meantime.
        if !detail.refs.head.isEmpty { body["sha"] = detail.refs.head }
        _ = try await request("PUT", pr(number) + "/merge", body: body)
        let branch = detail.summary.source
        guard options.deleteSourceBranch, detail.summary.sameRepository, ChangeRequest.valid(branch) else { return }
        let encoded = branch.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? String($0)
        }.joined(separator: "/")
        _ = try await request("DELETE", "/repos/\(repo)/git/refs/heads/\(encoded)")
    }
}
