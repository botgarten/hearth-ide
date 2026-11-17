import Foundation
import Testing
@testable import Hearth

/// Merge requests (GitLab) and pull requests (GitHub): diff parsing, comment placement and
/// the requests sent to the provider.
@Suite(.serialized)
struct ChangeRequestTests {
    static let gitHub = CIRemote.parse("git@github.com:octo/app.git")!
    static let gitLab = CIRemote.parse("git@gitlab.example.test:group/project.git")!

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeForge.self]
        return URLSession(configuration: config, delegate: NoRedirectTransport(), delegateQueue: nil)
    }

    private func github(writing: Bool = false) -> (GitHubAPI, URLSession) {
        let s = session()
        let c = CICredential(origin: Self.gitHub.origin, token: "gh-token", allowsWrites: writing)
        return (GitHubAPI(remote: Self.gitHub, credential: c, session: s, logSession: s), s)
    }

    private func gitlab(writing: Bool = false) -> (GitLabAPI, URLSession) {
        let s = session()
        let c = CICredential(origin: Self.gitLab.origin, token: "gl-token", allowsWrites: writing)
        return (GitLabAPI(remote: Self.gitLab, credential: c, session: s), s)
    }

    // MARK: Diff

    @Test func hunksAreNumbered() throws {
        let lines = UnifiedDiff.parse("@@ -10,3 +10,4 @@ func x()\n a\n-b\n+B\n+C\n c\n\\ No newline at end of file\n")
        #expect(lines.map(\.kind) == [.hunk, .context, .removed, .added, .added, .context, .note])
        #expect(lines[1].oldLine == 10 && lines[1].newLine == 10 && lines[1].text == "a")
        #expect(lines[2].oldLine == 11 && lines[2].newLine == nil)
        #expect(lines[3].newLine == 11 && lines[4].newLine == 12)
        #expect(lines[5].oldLine == 12 && lines[5].newLine == 13)
        let h = try need(UnifiedDiff.hunkHeader("@@ -1 +1,2 @@"))
        #expect(h.old == 1 && h.oldCount == 1 && h.new == 1 && h.newCount == 2)
        #expect(UnifiedDiff.hunkHeader("@@ nonsense @@") == nil)
    }

    @Test func gitHeadersStayMetaEvenWhenTheyLookLikeChanges() {
        let text = """
        diff --git a/x b/x
        index 1..2 100644
        --- a/x
        +++ b/x
        @@ -1,1 +1,1 @@
        -old
        +new
        diff --git a/y b/y
        --- a/y
        +++ b/y
        @@ -0,0 +1 @@
        +hi
        """
        let lines = UnifiedDiff.parse(text)
        #expect(lines.filter { $0.kind == .added }.map(\.text) == ["new", "hi"])
        #expect(lines.filter { $0.kind == .removed }.map(\.text) == ["old"])
        #expect(lines.filter { $0.kind == .meta }.count == 7)
        #expect(CRFile.counts(text) == (2, 1))
    }

    @Test func lineCommentsFindTheirLine() {
        let lines = UnifiedDiff.parse("@@ -1,2 +1,2 @@\n-a\n+A\n b\n")
        let onNew = CRComment(id: "1", author: "x", body: "new", createdAt: nil,
                              anchor: CRLineAnchor(path: "f", oldPath: "f", newLine: 1), thread: "t1")
        let reply = CRComment(id: "2", author: "y", body: "reply", createdAt: nil,
                              anchor: CRLineAnchor(path: "f", oldPath: "f", newLine: 1), thread: "t1")
        let onOld = CRComment(id: "3", author: "x", body: "old", createdAt: nil,
                              anchor: CRLineAnchor(path: "f", oldPath: "f", oldLine: 1))
        let gone = CRComment(id: "4", author: "x", body: "gone", createdAt: nil,
                             anchor: CRLineAnchor(path: "f", oldPath: "f", newLine: 99))
        let threads = ChangeRequestsStore.threads([onNew, reply, onOld, gone], in: lines)
        #expect(threads[2]?.map { $0.map(\.id) } == [["1", "2"]], "Added line with its reply")
        #expect(threads[1]?.map { $0.map(\.id) } == [["3"]], "Removed line")
        #expect(threads.values.flatMap { $0 }.flatMap { $0 }.count == 3, "A comment on a line outside the diff was placed")
    }

    @Test func historyIsReadFromTheRepository() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let log = await Git.log(limit: 3, in: repo)
        #expect(log.count == 3 && log.allSatisfy { !$0.hash.isEmpty && !$0.subject.isEmpty })
        #expect(await Git.log("--all", in: repo).isEmpty, "Options passed as ref")
    }

    // MARK: GitHub

    @Test func gitHubPullRequestsAreReadWithTheReadToken() async throws {
        FakeForge.reset()
        let (api, s) = github()
        defer { s.invalidateAndCancel() }
        let open = try await api.changeRequests(state: .open)
        #expect(open.map(\.number) == [5])
        #expect(open[0].source == "feature/x" && open[0].target == "main" && open[0].author == "mona" && open[0].sameRepository)
        let merged = try await api.changeRequests(state: .merged)
        #expect(merged.map(\.number) == [4], "Closed-unmerged PRs listed as merged")

        let detail = try await api.changeRequest(5)
        #expect(detail.mergeability == .warning(String(localized: "Some checks are failing")))
        #expect(detail.approvedBy == ["hubot"] && detail.changesRequestedBy.isEmpty)
        #expect(detail.refs.head == "headsha")

        let files = try await api.changeRequestFiles(5)
        #expect(files.map(\.status) == [.modified, .renamed] && files[1].oldPath == "old.swift")

        let comments = try await api.changeRequestComments(5)
        #expect(comments.map(\.id) == ["i1", "r2", "c3", "c4"])
        #expect(comments[1].kind == .approved)
        #expect(comments[2].anchor == CRLineAnchor(path: "a.swift", oldPath: "a.swift", newLine: 3) && comments[2].thread == "3")
        #expect(comments[3].thread == "3" && comments[3].outdated, "Reply not grouped or outdated line not marked")
        #expect(FakeForge.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func gitHubWritesNeedTheWriteTokenAndPinTheReviewedCommit() async throws {
        FakeForge.reset()
        let (reader, s1) = github()
        defer { s1.invalidateAndCancel() }
        await #expect(throws: GitHubAPI.APIError.readOnly) {
            try await reader.addComment(5, body: "hi", at: nil, refs: CRDiffRefs())
        }
        #expect(FakeForge.requests.isEmpty)

        let (api, s2) = github(writing: true)
        defer { s2.invalidateAndCancel() }
        try await api.addComment(5, body: "nice", at: CRLineAnchor(path: "a.swift", oldPath: "a.swift", oldLine: 7),
                                 refs: CRDiffRefs(base: "b", start: "b", head: "headsha"))
        #expect(FakeForge.requests.last?.url?.path == "/repos/octo/app/pulls/5/comments")
        let body = try need(FakeForge.lastJSON)
        #expect(body["side"]?.string == "LEFT" && body["line"]?.double == 7 && body["commit_id"]?.string == "headsha")

        try await api.review(5, verdict: .requestChanges, body: "please fix")
        #expect(FakeForge.lastJSON?["event"]?.string == "REQUEST_CHANGES")

        let detail = try await reader.changeRequest(5)
        try await api.merge(5, options: CRMergeOptions(method: .squash, deleteSourceBranch: true), detail: detail)
        let merge = try need(FakeForge.requests.first { $0.httpMethod == "PUT" })
        #expect(merge.url?.path == "/repos/octo/app/pulls/5/merge")
        #expect(FakeForge.bodies[merge.url!.path]?["sha"]?.string == "headsha")
        #expect(FakeForge.bodies[merge.url!.path]?["merge_method"]?.string == "squash")
        let delete = try need(FakeForge.requests.last)
        #expect(delete.httpMethod == "DELETE" && delete.url?.path == "/repos/octo/app/git/refs/heads/feature/x")
    }

    @Test func gitHubForkBranchesAreNeverDeleted() async throws {
        FakeForge.reset()
        let (api, s) = github(writing: true)
        defer { s.invalidateAndCancel() }
        var summary = CRSummary(number: 5, title: "", author: "", source: "feature/x", target: "main", state: .open,
                                draft: false, updatedAt: nil, webURL: nil)
        summary.sameRepository = false
        let detail = CRDetail(summary: summary, body: "", mergeability: .ready, refs: CRDiffRefs(head: "headsha"))
        try await api.merge(5, options: CRMergeOptions(deleteSourceBranch: true), detail: detail)
        #expect(!FakeForge.requests.contains { $0.httpMethod == "DELETE" })
    }

    // MARK: GitLab

    @Test func gitLabMergeRequestsAndLineComments() async throws {
        FakeForge.reset()
        let (reader, s1) = gitlab()
        defer { s1.invalidateAndCancel() }
        let list = try await reader.changeRequests(state: .open)
        #expect(list.map(\.number) == [12] && list[0].draft)
        #expect(FakeForge.requests.last?.url?.query?.contains("state=opened") == true)

        let detail = try await reader.changeRequest(12)
        #expect(detail.mergeability == .blocked(String(localized: "Approvals missing")))
        #expect(detail.pipelineStatus == "running" && detail.approvedBy == ["alice"])
        #expect(detail.refs == CRDiffRefs(base: "base", start: "start", head: "head"))

        let files = try await reader.changeRequestFiles(12)
        #expect(files.count == 1 && files[0].added == 1 && files[0].removed == 1, "Fallback to /changes or counting failed")

        let comments = try await reader.changeRequestComments(12)
        #expect(comments.map(\.kind) == [.comment, .approved, .comment])
        #expect(comments[0].thread == nil && comments[2].thread == "abcdef0123")
        #expect(comments[2].anchor == CRLineAnchor(path: "a.rb", oldPath: "a.rb", oldLine: 4, newLine: 5))

        let (api, s2) = gitlab(writing: true)
        defer { s2.invalidateAndCancel() }
        try await api.addComment(12, body: "why?", at: CRLineAnchor(path: "a.rb", oldPath: "a.rb", newLine: 5), refs: detail.refs)
        #expect(FakeForge.requests.last?.url?.path == "/api/v4/projects/group%2Fproject/merge_requests/12/discussions"
                || FakeForge.requests.last?.url?.path == "/api/v4/projects/group/project/merge_requests/12/discussions")
        let position = try need(FakeForge.lastJSON?["position"])
        #expect(position["head_sha"]?.string == "head" && position["start_sha"]?.string == "start" && position["new_line"]?.double == 5)
        #expect(position["old_line"] == nil)

        await #expect(throws: GitLabAPI.APIError.self) { try await api.reply(12, thread: "../../x", body: "hi") }

        try await api.merge(12, options: CRMergeOptions(method: .squash, deleteSourceBranch: true), detail: detail)
        #expect(FakeForge.requests.last?.httpMethod == "PUT")
        #expect(FakeForge.lastJSON?["sha"]?.string == "head" && FakeForge.lastJSON?["squash"] == .bool(true)
                && FakeForge.lastJSON?["should_remove_source_branch"] == .bool(true))
    }

    @Test func providerErrorsTalkAboutChangeRequests() {
        let gh = CRError.describe(GitHubAPI.APIError.http(403, "{}"), provider: .gitHub, writing: false)
        #expect(gh.contains("Pull requests"))
        let conflict = CRError.describe(GitHubAPI.APIError.http(405, #"{"message":"Pull Request is not mergeable"}"#),
                                        provider: .gitHub, writing: true)
        #expect(conflict.contains("Pull Request is not mergeable"))
    }

    // MARK: Store

    @MainActor
    @Test func storeLoadsTheSelectedRequestAndMapsDiffs() async throws {
        FakeForge.reset()
        let s = session()
        defer { s.invalidateAndCancel() }
        let store = ChangeRequestsStore(.init(
            detectRemote: { _ in Self.gitHub },
            loadCredentials: { _ in },
            client: { remote, writing in
                GitHubAPI(remote: remote, credential: CICredential(origin: remote.origin, token: "gh-token", allowsWrites: writing),
                          session: s, logSession: s)
            }))
        await store.open(root: "/r")
        await store.refreshList()
        #expect(store.list.map(\.number) == [5] && store.listError == nil)
        await store.select(5)
        #expect(store.detail?.summary.number == 5 && store.files.count == 2)
        #expect(store.diffLines["a.swift"]?.contains { $0.kind == .added } == true)
        #expect(store.lineComments["a.swift"]?.count == 1, "The outdated comment belongs in the conversation")
        #expect(store.conversation.map(\.id) == ["i1", "r2", "c4"])
        let error = await store.perform("x") { api, n, d in try await api.review(n, verdict: .approve, body: "") }
        #expect(error == nil)
        #expect(FakeForge.requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/repos/octo/app/pulls/5/reviews" })
    }
}

/// api.github.com and a GitLab server, recording every request and JSON body.
private final class FakeForge: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var recordedBodies: [String: JSON] = [:]
    nonisolated(unsafe) private static var last: JSON?
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static var bodies: [String: JSON] { lock.withLock { recordedBodies } }
    static var lastJSON: JSON? { lock.withLock { last } }
    static func reset() { lock.withLock { recorded = []; recordedBodies = [:]; last = nil } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body: Data? = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while case let n = stream.read(&buffer, maxLength: buffer.count), n > 0 { data.append(contentsOf: buffer.prefix(n)) }
            stream.close()
            body = data
        }
        let url = request.url!
        Self.lock.withLock {
            Self.recorded.append(request)
            if let b = body, let j = JSON.parse(b) { Self.last = j; Self.recordedBodies[url.path] = j }
        }
        func reply(_ code: Int, _ text: String) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        let method = request.httpMethod ?? "GET"
        if url.host == "api.github.com" {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer gh-token" else { return reply(401, "{}") }
            return github(method, url, reply)
        }
        if url.host == "gitlab.example.test" {
            guard request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "gl-token" else { return reply(401, "{}") }
            return gitlab(method, request.url!.absoluteString, reply)
        }
        reply(404, "{}")
    }

    private func github(_ method: String, _ url: URL, _ reply: (Int, String) -> Void) {
        let pr5 = """
        {"number":5,"title":"Add x","user":{"login":"mona"},"state":"open","draft":false,"updated_at":"2026-11-01T07:00:00Z",
         "html_url":"https://github.com/octo/app/pull/5","body":"Body","mergeable":true,"mergeable_state":"unstable",
         "head":{"ref":"feature/x","sha":"headsha","repo":{"full_name":"octo/app"}},"base":{"ref":"main","sha":"basesha"}}
        """
        switch (method, url.path) {
        case ("GET", "/repos/octo/app/pulls"):
            if url.query?.contains("state=open") == true { return reply(200, "[\(pr5)]") }
            reply(200, """
            [{"number":4,"title":"Old","user":{"login":"a"},"state":"closed","merged_at":"2026-10-01T00:00:00Z","head":{"ref":"x"},"base":{"ref":"main"}},
             {"number":3,"title":"Rejected","user":{"login":"a"},"state":"closed","merged_at":null,"head":{"ref":"y"},"base":{"ref":"main"}}]
            """)
        case ("GET", "/repos/octo/app/pulls/5"): reply(200, pr5)
        case ("GET", "/repos/octo/app/pulls/5/reviews"):
            reply(200, """
            [{"id":2,"user":{"login":"hubot"},"state":"APPROVED","body":"LGTM","submitted_at":"2026-11-01T08:00:00Z"},
             {"id":9,"user":{"login":"x"},"state":"COMMENTED","body":"","submitted_at":"2026-11-01T08:01:00Z"}]
            """)
        case ("GET", "/repos/octo/app/pulls/5/files"):
            reply(200, """
            [{"filename":"a.swift","status":"modified","additions":1,"deletions":1,"patch":"@@ -1,3 +1,3 @@\\n a\\n-b\\n+B\\n c"},
             {"filename":"new.swift","previous_filename":"old.swift","status":"renamed","additions":0,"deletions":0}]
            """)
        case ("GET", "/repos/octo/app/issues/5/comments"):
            reply(200, #"[{"id":1,"user":{"login":"mona"},"body":"First","created_at":"2026-11-01T07:30:00Z"}]"#)
        case ("GET", "/repos/octo/app/pulls/5/comments"):
            reply(200, """
            [{"id":3,"user":{"login":"hubot"},"body":"Here","path":"a.swift","line":3,"side":"RIGHT","created_at":"2026-11-01T08:30:00Z"},
             {"id":4,"in_reply_to_id":3,"user":{"login":"mona"},"body":"Done","path":"a.swift","line":null,"side":"RIGHT","created_at":"2026-11-01T09:00:00Z"}]
            """)
        case ("POST", _), ("PUT", _), ("DELETE", _): reply(200, "{}")
        default: reply(404, "{}")
        }
    }

    private func gitlab(_ method: String, _ full: String, _ reply: (Int, String) -> Void) {
        let base = "https://gitlab.example.test/api/v4/projects/group%2Fproject/merge_requests"
        let path = full.components(separatedBy: "?")[0]
        switch (method, path) {
        case ("GET", base):
            reply(200, #"[{"iid":12,"title":"Draft: thing","author":{"username":"bob"},"source_branch":"feat","target_branch":"main","state":"opened","draft":true}]"#)
        case ("GET", base + "/12"):
            reply(200, """
            {"iid":12,"title":"thing","author":{"username":"bob"},"source_branch":"feat","target_branch":"main","state":"opened",
             "detailed_merge_status":"not_approved","diff_refs":{"base_sha":"base","start_sha":"start","head_sha":"head"},
             "head_pipeline":{"status":"running"},"description":"Desc"}
            """)
        case ("GET", base + "/12/approvals"):
            reply(200, #"{"approved_by":[{"user":{"username":"alice"}}]}"#)
        case ("GET", base + "/12/diffs"): reply(404, #"{"message":"404 Not found"}"#)
        case ("GET", base + "/12/changes"):
            reply(200, #"{"changes":[{"old_path":"a.rb","new_path":"a.rb","diff":"@@ -4,1 +4,1 @@\n-x\n+y\n"}]}"#)
        case ("GET", base + "/12/discussions"):
            reply(200, """
            [{"id":"aaaaaaaa11","individual_note":true,"notes":[{"id":1,"body":"hello","author":{"username":"bob"},"system":false}]},
             {"id":"bbbbbbbb22","individual_note":true,"notes":[{"id":2,"body":"approved this merge request","author":{"username":"alice"},"system":true}]},
             {"id":"abcdef0123","individual_note":false,"notes":[{"id":3,"body":"why","author":{"username":"alice"},"system":false,
               "position":{"old_path":"a.rb","new_path":"a.rb","old_line":4,"new_line":5}}]}]
            """)
        case ("POST", _), ("PUT", _): reply(201, "{}")
        default: reply(404, "{}")
        }
    }

    override func stopLoading() {}
}
