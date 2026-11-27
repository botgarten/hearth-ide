import Foundation
import CoreServices
import Testing
@testable import Hearth

/// Agent hooks: Kiro-compatible files, trust, and when the engine fires.
@MainActor
struct AgentHooksTests {
    private func tempRoot() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func trust() -> HookTrust {
        let suite = "hooks-test-\(UUID().uuidString)"
        return HookTrust(defaults: UserDefaults(suiteName: suite)!)
    }

    final class Fake {
        var runs: [HookRunInfo] = []
        var sent: [(String, String)] = []
        var commands: [String] = []
        var exitCode: Int32 = 0
    }

    private func engine(_ fake: Fake, trust: HookTrust) -> AgentHooksEngine {
        AgentHooksEngine(deps: .init(runs: { fake.runs }, send: { fake.sent.append(($0, $1)) },
                                     runCommand: { _, command, _ in
                                         await MainActor.run { fake.commands.append(command) }
                                         return .init(exitCode: await MainActor.run { fake.exitCode }, output: "boom")
                                     }), trust: trust)
    }

    @Test func readsKiroFilesAndTheOlderFormat() throws {
        let root = try tempRoot()
        let kiro = URL(fileURLWithPath: root).appendingPathComponent(".kiro/hooks")
        try FileManager.default.createDirectory(at: kiro, withIntermediateDirectories: true)
        try #"""
        {"version": "v1", "hooks": [
          {"name": "Lint on save", "trigger": "PostFileSave", "matcher": "\\.(ts|tsx)$",
           "action": {"type": "command", "command": "npx eslint --fix", "timeout": 30}},
          {"name": "Before tools", "trigger": "PreToolUse", "action": {"type": "agent", "prompt": "x"}},
          {"name": "Review", "trigger": "Stop", "enabled": false, "action": {"type": "agent", "prompt": "Review it"}}
        ]}
        """#.write(to: kiro.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)
        try #"{"name": "Docs", "when": {"type": "fileEdited", "patterns": ["src/**/*.ts"]}, "then": {"type": "askAgent", "prompt": "Update docs"}}"#
            .write(to: kiro.appendingPathComponent("docs.kiro.hook"), atomically: true, encoding: .utf8)
        try "not json".write(to: kiro.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)

        let set = HookLibrary.load(root: root)
        #expect(set.problems.map(\.file) == [".kiro/hooks/broken.json"])
        let byName = Dictionary(uniqueKeysWithValues: set.hooks.map { ($0.name, $0) })
        let lint = try #require(byName["Lint on save"])
        #expect(lint.trigger == .fileSave && lint.action == .command("npx eslint --fix", timeout: 30))
        #expect(lint.matches(path: "web/app.tsx") && !lint.matches(path: "web/app.css"))
        #expect(byName["Before tools"]?.isSupported == false)
        #expect(byName["Review"]?.enabled == false && byName["Review"]?.trigger == .agentStop)
        let docs = try #require(byName["Docs"])
        #expect(docs.trigger == .fileSave && docs.action == .agent(prompt: "Update docs"))
        #expect(docs.matches(path: "src/a/b.ts") && docs.matches(path: "src/b.ts") && !docs.matches(path: "lib/b.ts"))
    }

    @Test func globsBecomeRegularExpressions() throws {
        func m(_ glob: String, _ path: String) -> Bool {
            let re = try! NSRegularExpression(pattern: HookLibrary.globToRegex(glob))
            return re.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
        }
        #expect(m("*.swift", "Sources/A.swift") && !m("*.swift", "A.swifty"))
        #expect(m("**/*.{ts,tsx}", "a/b/c.tsx") && m("**/*.{ts,tsx}", "c.ts"))
        #expect(!m("src/*.ts", "src/a/b.ts"))
    }

    @Test func createToggleAndDeleteKeepTheFileValid() throws {
        let root = try tempRoot()
        let file = try HookLibrary.create(name: "Tests", description: nil, trigger: .fileSave, matcher: #"\.swift$"#,
                                          action: .agent(prompt: "Update tests"), root: root)
        #expect(file == ".hearth/hooks/tests.json")
        var hook = try #require(HookLibrary.load(root: root).hooks.first)
        #expect(hook.matcher == #"\.swift$"# && hook.enabled)
        try HookLibrary.setEnabled(false, hook: hook, root: root)
        hook = try #require(HookLibrary.load(root: root).hooks.first)
        #expect(!hook.enabled)
        try HookLibrary.delete(hook, root: root)
        #expect(HookLibrary.load(root: root).hooks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root + "/" + file))
    }

    @Test func onlyAllowedContentRuns() throws {
        let root = try tempRoot()
        let fake = Fake()
        let e = engine(fake, trust: trust())
        let file = try HookLibrary.create(name: "Review", description: nil, trigger: .agentStop, matcher: nil,
                                          action: .agent(prompt: "Review"), root: root)
        e.reload(root)
        let hook = try #require(e.hooks(for: root).hooks.first)
        #expect(!e.isTrusted(hook, root: root))
        e.allow(file: file, root: root)
        #expect(e.isTrusted(hook, root: root))
        // The agent rewrites the file: no longer allowed.
        try #"{"version":"v1","hooks":[{"name":"Review","trigger":"Stop","action":{"type":"command","command":"curl evil"}}]}"#
            .write(toFile: root + "/" + file, atomically: true, encoding: .utf8)
        e.reload(root)
        #expect(!e.isTrusted(try #require(e.hooks(for: root).hooks.first), root: root))
    }

    @Test func fileHooksFireAfterTheTurnWithItsFilesAndHookTurnsNeverLoop() throws {
        let root = try tempRoot()
        let fake = Fake()
        let e = engine(fake, trust: trust())
        let tests = try HookLibrary.create(name: "Tests", description: nil, trigger: .fileSave, matcher: #"\.swift$"#,
                                           action: .agent(prompt: "Update tests"), root: root)
        let review = try HookLibrary.create(name: "Review", description: nil, trigger: .agentStop, matcher: nil,
                                            action: .agent(prompt: "Review"), root: root)
        e.allow(file: tests, root: root)
        e.allow(file: review, root: root)

        var now = Date()
        func step(_ status: AgentStatus, seconds: Double = 0.5) {
            now = now.addingTimeInterval(seconds)
            fake.runs = [HookRunInfo(id: "r1", directory: root, status: status, isRunning: true)]
            e.tick(now: now)
        }
        step(.idle)
        // Edits outside a turn (the user) don't count.
        e.filesChanged(root: root, [("A.swift", .saved)], now: now)
        step(.running)
        e.filesChanged(root: root, [("B.swift", .saved), ("notes.md", .saved), (".git/index", .saved)], now: now)
        step(.done)
        e.filesChanged(root: root, [("C.swift", .created)], now: now)   // late event, still this turn; but created ≠ saved
        #expect(fake.sent.isEmpty)
        step(.done, seconds: 2)
        // One prompt at a time (hook files in name order: review, then tests).
        #expect(fake.sent.count == 1 && fake.sent[0].0 == "r1" && fake.sent[0].1.contains("Review"))

        // The hook's turn changes files and ends: no new hooks, but the queued review goes out.
        step(.running)
        e.filesChanged(root: root, [("BTests.swift", .saved)], now: now)
        step(.done)
        step(.done, seconds: 2)
        #expect(fake.sent.count == 2)
        // The tests hook gets only the matching file the agent saved in its own turn.
        let testsPrompt = fake.sent[1].1
        #expect(testsPrompt.contains("Update tests") && testsPrompt.contains("`B.swift`"))
        #expect(!testsPrompt.contains("notes.md") && !testsPrompt.contains("A.swift") && !testsPrompt.contains("C.swift") && !testsPrompt.contains("BTests"))
        step(.running)
        step(.done)
        step(.done, seconds: 2)
        step(.done, seconds: 2)
        #expect(fake.sent.count == 2)
    }

    @Test func failingCommandsHandTheirOutputToTheAgent() async throws {
        let root = try tempRoot()
        let fake = Fake()
        fake.exitCode = 1
        let e = engine(fake, trust: trust())
        let file = try HookLibrary.create(name: "Lint", description: nil, trigger: .fileSave, matcher: nil,
                                          action: .command("npm run lint", timeout: nil), root: root)
        e.allow(file: file, root: root)
        var now = Date()
        fake.runs = [HookRunInfo(id: "r1", directory: root, status: .running, isRunning: true)]
        e.tick(now: now)
        e.filesChanged(root: root, [("a.ts", .saved)], now: now)
        fake.runs[0].status = .done
        now += 0.5; e.tick(now: now)
        now += 2; e.tick(now: now)
        for _ in 0..<100 where fake.sent.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            now += 0.5; e.tick(now: now)
        }
        #expect(fake.commands == ["npm run lint"])
        #expect(fake.sent.count == 1 && fake.sent[0].1.contains("npm run lint") && fake.sent[0].1.contains("boom"))
    }

    @Test func eventFlagsMapToChanges() {
        let file = UInt32(kFSEventStreamEventFlagItemIsFile)
        #expect(FileChangeKind.classify(flags: file | UInt32(kFSEventStreamEventFlagItemModified), exists: true) == .saved)
        #expect(FileChangeKind.classify(flags: file | UInt32(kFSEventStreamEventFlagItemCreated), exists: true) == .created)
        #expect(FileChangeKind.classify(flags: file | UInt32(kFSEventStreamEventFlagItemRemoved), exists: false) == .deleted)
        #expect(FileChangeKind.classify(flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated), exists: true) == nil)
        #expect(AgentHooksEngine.ignored("node_modules/x/y.js") && !AgentHooksEngine.ignored("src/app.ts"))
    }
}
