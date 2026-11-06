import Foundation
import Testing
@testable import Hearth

/// Runs real commands through nono (Vendor/nono, see scripts/fetch-nono.sh) and checks
/// that the kernel sandbox enforces what SandboxPolicy promises. Skipped without nono.
enum VendoredNono {
    static let path: String? = {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = repo.appendingPathComponent("Vendor/nono/\(SandboxManager.nonoVersion)/nono").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()
}

@Suite(.serialized, .enabled(if: VendoredNono.path != nil, "nono not found: run scripts/fetch-nono.sh"))
struct LiveSandboxTests {

    /// Runs `script` in a sandbox for `purpose` inside a fresh project below home.
    private func run(_ purpose: SandboxPurpose, _ script: String, project: URL) async throws -> (SandboxCommandState, String) {
        let runner = NonoCommandRunner(root: project.path, purpose: purpose)
        let id = try await runner.start(SandboxCommandRequest(command: script, cwd: project.path, timeout: .seconds(60)))
        var state = SandboxCommandState.running
        for _ in 0..<600 {
            state = try await runner.state(of: id)
            if !state.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let output = try await runner.output(of: id, from: 0, limit: 1 << 20).text
        await runner.remove(id)
        return (state, output)
    }

    private func project() throws -> (URL, URL) {
        // Sandboxes only work below home; the support folder (runs, agent homes) goes to a temp folder.
        let support = try temporaryFolder("hearth-live-support")
        setenv("HEARTH_SUPPORT_DIR", support.path, 1)
        setenv("HEARTH_NONO_BIN", VendoredNono.path ?? "", 1)
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hearth-live-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)
        return (dir, support)
    }

    @Test(arguments: ["build", "git-local", "git-network"])
    func projectIsWritableButHooksAreNot(_ name: String) async throws {
        let purpose: SandboxPurpose = name == "build" ? .build : name == "git-local" ? .gitLocal : .gitNetwork
        let (dir, support) = try project()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: support) }
        let (state, output) = try await run(purpose, """
            echo ok > written.txt && echo wrote-project
            echo bad > .git/hooks/post-merge 2>/dev/null && echo wrote-hook
            ls "$HOME/.ssh" >/dev/null 2>&1 && echo read-ssh
            ls "$HOME/Library/Keychains" >/dev/null 2>&1 && echo read-keychain
            true
            """, project: dir)
        try require(state == .exited(0), "\(name): sandbox did not run: \(state) \(output)")
        try require(output.contains("wrote-project"), "\(name): project not writable: \(output)")
        try require(!output.contains("wrote-hook"), "\(name): .git/hooks writable")
        let sshExists = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.ssh")
        if sshExists {
            // Positive control: the Git network step is the one sandbox that may read SSH keys.
            try require(output.contains("read-ssh") == (purpose == .gitNetwork), "\(name): ~/.ssh access wrong: \(output)")
        }
        if purpose != .gitNetwork {
            try require(!output.contains("read-keychain"), "\(name): keychain readable")
        }
    }

    /// The agent calls `hearth-journal` from inside its sandbox; the line must land in the run folder.
    @Test func agentCanWriteTheJournalFromInsideTheSandbox() async throws {
        let (dir, support) = try project()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: support) }
        let runDir = support.appendingPathComponent("runs/journal-live")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let bin = try JournalSupport.install(runDirectory: runDir)
        let policy = SandboxPolicy.make(.agent(.claude), SandboxManager.context(runDirectory: runDir, directory: dir.path, settings: .load()))
        let profile = runDir.appendingPathComponent("nono-profile.json")
        try policy.profileData.write(to: profile)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: VendoredNono.path ?? "")
        p.arguments = ["run", "--silent", "--profile", profile.path, "--allow-cwd", "--no-diagnostics", "--",
                       "/bin/sh", "-c", "hearth-journal step s1 --title 'from sandbox' --status running"]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = bin.path + ":/usr/bin:/bin"
        env["HEARTH_JOURNAL"] = JournalSupport.url(runDirectory: runDir).path
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        var reader = JournalReader()
        let changed = reader.poll(url: JournalSupport.url(runDirectory: runDir))
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        try require(changed && reader.journal.node("s1")?.title == "from sandbox", "journal not written: \(output)")
    }
}
