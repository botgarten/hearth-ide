import Foundation
import Testing
@testable import Hearth

/// CI/CD loading and the workspace's settled revision: what reloads when an agent writes files.
@MainActor
struct LoadingTests {
    static let gitLab = CIRemote.parse("git@gitlab.example.test:group/project.git")!
    static let gitHub = CIRemote.parse("git@github.com:octo/app.git")!

    /// Records requests; returns the pipelines set in `next`.
    final class FakeCI: CIClient, @unchecked Sendable {
        let remote: CIRemote
        var next: [CIPipeline] = []
        var fail = false
        private(set) var refs: [String?] = []
        init(_ remote: CIRemote) { self.remote = remote }
        func pipelines(ref: String?) async throws -> [CIPipeline] {
            refs.append(ref)
            if fail { throw SandboxCommandError("offline") }
            return next
        }
        func jobs(pipeline: Int) async throws -> [CIJob] { [] }
        func log(job: Int) async throws -> String { "" }
        func retry(pipeline: Int) async throws {}
        func cancel(pipeline: Int) async throws {}
        func retry(job: Int) async throws {}
        func play(job: Int) async throws {}
        func workflows() async throws -> [CIWorkflow] { [] }
        func run(ref: String, workflow: CIWorkflow?) async throws {}
    }

    static func pipeline(_ id: Int, _ status: String) -> CIPipeline {
        CIPipeline(id: id, iid: id, ref: "main", sha: "abc", status: status, source: "push", createdAt: nil, webURL: nil)
    }

    final class Box: @unchecked Sendable { var remote: CIRemote?; var detections = 0 }

    static func store(_ box: Box, client: FakeCI) -> PipelinesStore {
        PipelinesStore(.init(detectRemote: { _ in box.detections += 1; return box.remote },
                             loadCredentials: { _ in },
                             client: { $0.origin == client.remote.origin ? client : nil }))
    }

    @Test func fileChangesKeepPipelinesUnlessTheRemoteChanges() async {
        let box = Box(); box.remote = Self.gitLab
        let client = FakeCI(Self.gitLab)
        client.next = [Self.pipeline(1, "success")]
        let store = Self.store(box, client: client)

        await store.open(root: "/r")
        #expect(store.remoteChecked && store.remote?.path == "group/project")
        await store.refresh(branch: "main")
        #expect(store.pipelines.count == 1 && client.refs == ["main"])

        // An agent writes files: the remote is checked again, nothing is cleared or reloaded.
        await store.recheckRemote()
        #expect(store.pipelines.count == 1 && store.remoteChecked && client.refs.count == 1)

        // The remote really changed: results of the old one go away.
        box.remote = Self.gitHub
        await store.recheckRemote()
        #expect(store.remote?.provider == .gitHub && store.pipelines.isEmpty && store.api == nil)
    }

    @Test func refreshKeepsTheListOnErrorsAndFollowsTheBranchFilter() async {
        let box = Box(); box.remote = Self.gitLab
        let client = FakeCI(Self.gitLab)
        client.next = [Self.pipeline(1, "running")]
        let store = Self.store(box, client: client)
        await store.open(root: "/r")
        await store.refresh(branch: "feature")
        store.onlyCurrentBranch = false
        client.fail = true
        await store.refresh(branch: "feature")
        #expect(client.refs == ["feature", nil])
        #expect(store.pipelines.count == 1 && store.error == "offline")
    }

    @Test func pollingIsFasterWhileSomethingRuns() async {
        #expect(PipelinesStore.pollInterval([Self.pipeline(1, "success")]) == .seconds(60))
        #expect(PipelinesStore.pollInterval([Self.pipeline(1, "success"), Self.pipeline(2, "pending")]) == .seconds(15))

        let box = Box(); box.remote = Self.gitLab
        let client = FakeCI(Self.gitLab)
        client.next = [Self.pipeline(1, "running")]
        let store = Self.store(box, client: client)
        await store.open(root: "/r")
        var waits: [Duration] = []
        await store.poll(branch: "main") { d in
            waits.append(d)
            if waits.count == 2 { throw CancellationError() }
        }
        #expect(waits == [.seconds(15), .seconds(15)] && client.refs.count == 2)
    }

    @Test func settledRevisionWaitsForQuietButNotForever() async throws {
        let ws = WorkspaceState()
        ws.settleDelay = .milliseconds(80)
        ws.maxSettleDelay = .milliseconds(300)

        ws.revision += 1
        ws.revision += 1
        #expect(ws.settledRevision == 0, "Settled before changes paused")
        // Bounded by turns, not wall-clock time: other tests may hold the main actor for
        // seconds on a slow CI runner, and every turn gives the settle task a chance to run.
        for _ in 0..<250 where ws.settledRevision != 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ws.settledRevision == 2)

        // An agent that keeps writing faster than the quiet period: only the upper bound can
        // settle it. Without it the loop would run out of turns.
        ws.settleDelay = .seconds(3)
        ws.maxSettleDelay = .milliseconds(200)
        for _ in 0..<250 where ws.settledRevision < 3 {
            ws.revision += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ws.settledRevision >= 3, "Never settled while writing")

        // An explicit refresh applies at once.
        ws.refreshNow()
        #expect(ws.settledRevision == ws.revision)
    }

    @Test func sessionIDsCannotBecomeOptions() {
        for ok in ["0b6f7c2e-9a1d-4c3e-8f00-1234567890ab", "thread_abc.1", "ses_01J:x"] {
            #expect(AgentHost.validSessionID(ok), "\(ok) rejected")
        }
        for bad in ["", "--dangerously-skip-permissions", "-x", "a b", "a;rm", String(repeating: "a", count: 200), "a\nb"] {
            #expect(!AgentHost.validSessionID(bad), "\(bad) accepted")
        }
    }
}
