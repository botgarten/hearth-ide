import Foundation
import Testing
@testable import Hearth

/// Commit messages written by an agent: what goes into the prompt and what comes out.
@Suite(.serialized)
struct CommitMessageTests {
    private func repo(inHome: Bool = false) throws -> (URL, ([String]) throws -> Void) {
        // Sandboxes only run in folders inside the home folder.
        let dir = inHome ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hearth-msg-test-" + UUID().uuidString)
            : try temporaryFolder("hearth-msg")
        if inHome { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-c", "user.email=t@example.test", "-c", "user.name=Tess"] + args
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            try require(p.terminationStatus == 0, "git \(args.joined(separator: " ")) failed")
        }
        try git(["init", "-q", "-b", "main"])
        return (dir, git)
    }

    @Test func stagedChangesAreDescribedWhenThereAreAny() async throws {
        let (dir, git) = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "one\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "Add a"])
        try "one\ntwo\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git(["add", "a.txt"])

        let staged = [GitFileChange(path: "a.txt", code: "M "), GitFileChange(path: "b.txt", code: "??")]
        let input = try #require(await CommitMessageGenerator.input(in: dir.path, changes: staged))
        #expect(input.stagedOnly)
        #expect(input.diff.contains("+two"))
        #expect(!input.files.contains("b.txt"), "Unstaged files stay out when something is staged")
        #expect(input.recentSubjects == ["Add a"])

        // Nothing staged: every change, new files included.
        try git(["reset", "-q"])
        let all = [GitFileChange(path: "a.txt", code: " M"), GitFileChange(path: "b.txt", code: "??")]
        let everything = try #require(await CommitMessageGenerator.input(in: dir.path, changes: all))
        #expect(!everything.stagedOnly)
        #expect(everything.diff.contains("+two") && everything.diff.contains("+new"))
        #expect(everything.files.contains("b.txt (new)"))
    }

    @Test func lockfilesStayInTheFileListButOutOfTheDiff() async throws {
        let (dir, git) = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "one\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "{}\n".write(to: dir.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", "Init"])
        try "one\ntwo\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "{\"pins\":[]}\n".write(to: dir.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        try "x=1\n".write(to: dir.appendingPathComponent("app.min.js"), atomically: true, encoding: .utf8)
        let changes = [GitFileChange(path: "a.txt", code: " M"), GitFileChange(path: "Package.resolved", code: " M"),
                       GitFileChange(path: "app.min.js", code: "??")]
        let input = try #require(await CommitMessageGenerator.input(in: dir.path, changes: changes))
        #expect(input.diff.contains("+two"))
        #expect(!input.diff.contains("pins") && !input.diff.contains("x=1"))
        #expect(input.files.contains("Package.resolved") && input.files.contains("app.min.js (new)"))
        #expect(CommitMessageGenerator.isNoise("Sub/yarn.lock") && !CommitMessageGenerator.isNoise("lock.swift"))
    }

    @Test func theFirstCommitHasNoHeadToCompareWith() async throws {
        let (dir, _) = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "hello\n".write(to: dir.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)
        let input = try #require(await CommitMessageGenerator.input(in: dir.path, changes: [GitFileChange(path: "readme.md", code: "??")]))
        #expect(input.diff.contains("+hello"))
        #expect(input.recentSubjects.isEmpty)
        #expect(await CommitMessageGenerator.input(in: dir.path, changes: []) == nil)
    }

    @Test func promptCarriesStyleFilesAndATruncationNote() {
        let input = CommitMessageGenerator.Input(files: " a.txt | 2 +-", diff: "diff --git a/a.txt b/a.txt\n+x",
                                                 recentSubjects: ["Git pane: review MRs"], truncated: true, stagedOnly: true)
        let prompt = CommitMessageGenerator.prompt(input)
        #expect(prompt.contains("- Git pane: review MRs"))
        #expect(prompt.contains("Changed files (staged):\n a.txt | 2 +-"))
        #expect(prompt.contains("Diff (cut off, too long):\ndiff --git"))
    }

    @Test func agentsRunWithoutToolsAndClaudeReadsStdin() {
        let claude = CommitMessageGenerator.arguments(for: .claude, prompt: "P")
        #expect(claude.stdin == "P" && claude.args.contains("--print") && claude.args.contains("--tools="))
        #expect(!claude.args.contains("P"))
        // Cheap one-shot: small model, no MCP servers, short system prompt.
        #expect(claude.args.contains("--strict-mcp-config"))
        #expect(claude.args.firstIndex(of: "--model").map { claude.args[$0 + 1] } == CommitMessageGenerator.claudeModel)
        #expect(claude.args.contains("--system-prompt"))
        let codex = CommitMessageGenerator.arguments(for: .codex, prompt: "P")
        #expect(codex.args.first == "exec" && codex.args.last == "P" && codex.args.contains("read-only"))
        #expect(CommitMessageGenerator.arguments(for: .gemini, prompt: "P").args == ["--prompt", "P"])
    }

    @Test func answersAreCleanedUp() {
        #expect(CommitMessageGenerator.clean("Add login form\n") == "Add login form")
        #expect(CommitMessageGenerator.clean("Here is the commit message:\n```\nFix crash\n\nBody line\n```\n")
                == "Fix crash\n\nBody line")
        #expect(CommitMessageGenerator.clean("\"Update README\"") == "Update README")
        #expect(CommitMessageGenerator.clean("\u{1B}[1mRename x\u{1B}[0m") == "Rename x")
        #expect(CommitMessageGenerator.clean("Commit message:\nTidy up") == "Tidy up")
    }

    /// Calls the real agent in its sandbox. Opt-in: HEARTH_LIVE_AGENT=claude (or codex, gemini).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEARTH_LIVE_AGENT"] != nil))
    func liveAgentWritesAMessage() async throws {
        let kind = try #require(AgentKind(rawValue: ProcessInfo.processInfo.environment["HEARTH_LIVE_AGENT"] ?? ""))
        let (dir, git) = try repo(inHome: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "func greet() { print(\"hi\") }\n".write(to: dir.appendingPathComponent("greet.swift"), atomically: true, encoding: .utf8)
        try git(["add", "greet.swift"])
        let message = try await CommitMessageGenerator.generate(with: kind, in: dir.path,
                                                                changes: [GitFileChange(path: "greet.swift", code: "A ")])
        print("Generated message:\n\(message)")
        #expect(!message.isEmpty && !message.contains("```"))
    }
}
