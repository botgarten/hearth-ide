import Foundation

/// Git network operations. A pull is split in two: `fetch` runs in the network sandbox
/// (SSH keys, keychain), the fast-forward (`merge`) in a plain sandbox without them, so
/// filters or other repository-controlled commands never run next to the user's keys.
enum SandboxGitOperation: Sendable {
    case fetch, fetchUpstream, fastForward, clone(String)
    /// Local, user-triggered writes (sandbox without network and keys).
    case commit(message: String), merge(branch: String), mergeAbort
    case stash(message: String, includeUntracked: Bool), stashApply(Int), stashPop(Int), stashDrop(Int)
    /// Uploads the branch; `setUpstream` for a branch without upstream. Never forced.
    case push(branch: String, setUpstream: Bool)

    var name: String {
        switch self {
        case .fetch, .fetchUpstream: "fetch"
        case .fastForward, .merge: "merge"
        case .mergeAbort: "merge-abort"
        case .clone: "clone"
        case .commit: "commit"
        case .stash, .stashApply, .stashPop, .stashDrop: "stash"
        case .push: "push"
        }
    }

    /// Needs the network sandbox (SSH keys, keychain, port 22).
    var needsNetwork: Bool {
        switch self {
        case .fetch, .fetchUpstream, .clone, .push: true
        default: false
        }
    }

    /// Branch or ref names from the UI: plain refname characters, never an option.
    static func validRef(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200, !value.hasPrefix("-"), !value.hasPrefix("/"), !value.hasSuffix("/"),
              !value.contains(".."), !value.contains("@{"), !value.hasSuffix(".lock"), !value.hasSuffix(".") else { return false }
        return value.range(of: #"^[A-Za-z0-9._/+#@-]+$"#, options: .regularExpression) != nil
    }

    static func validMessage(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && value.count <= 10_000 && !value.unicodeScalars.contains("\0")
    }

    /// Prefix for local writes: no hooks, no filters from the config, no signing, no pager.
    private static func localPrefix(identity: Bool) -> [String] {
        var p = ["/usr/bin/env", "-u", "GIT_EDITOR", "GIT_TERMINAL_PROMPT=0", "GIT_EDITOR=true",
                 "/usr/bin/git", "--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                 "-c", "diff.external=", "-c", "submodule.recurse=false", "-c", "commit.gpgsign=false",
                 "-c", "tag.gpgsign=false"]
        if identity {
            let id = globalIdentity
            if let name = id.name { p += ["-c", "user.name=" + name] }
            if let email = id.email { p += ["-c", "user.email=" + email] }
        }
        return p
    }

    /// Commits need an author; it comes from ~/.gitconfig, never from the repository.
    static let globalIdentity: (name: String?, email: String?) = {
        func read(_ key: String) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["config", "--global", "--get", key]
            p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return (read("user.name"), read("user.email"))
    }()

    /// Only fixed operations, never an arbitrary command supplied by a repository.
    /// `repoOverrides`: neutralised repository config keys (see Git.networkSandboxOverrides).
    func command(repoOverrides: [String] = []) throws -> String {
        let args: [String]
        switch self {
        case .commit(let message):
            guard Self.validMessage(message) else { throw SandboxCommandError(String(localized: "The commit message is empty or invalid.")) }
            guard Self.globalIdentity.name != nil, Self.globalIdentity.email != nil else {
                throw SandboxCommandError(String(localized: "Git needs your name and email: git config --global user.name / user.email."))
            }
            return (Self.localPrefix(identity: true) + ["commit", "--no-verify", "--no-gpg-sign", "-m", message])
                .map(Self.quote).joined(separator: " ")
        case .merge(let branch):
            guard Self.validRef(branch) else { throw SandboxCommandError(String(localized: "Invalid branch name.")) }
            return (Self.localPrefix(identity: true) + ["merge", "--no-edit", "--no-verify", "--no-gpg-sign", "--no-stat", branch])
                .map(Self.quote).joined(separator: " ")
        case .mergeAbort:
            return (Self.localPrefix(identity: false) + ["merge", "--abort"]).map(Self.quote).joined(separator: " ")
        case .stash(let message, let untracked):
            guard message.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), message.count <= 200 else {
                throw SandboxCommandError(String(localized: "Invalid stash message."))
            }
            var a = ["stash", "push"] + (untracked ? ["--include-untracked"] : [])
            if !message.isEmpty { a += ["-m", message] }
            return (Self.localPrefix(identity: true) + a).map(Self.quote).joined(separator: " ")
        case .stashApply(let i), .stashPop(let i), .stashDrop(let i):
            guard (0..<1000).contains(i) else { throw SandboxCommandError(String(localized: "Invalid stash.")) }
            let verb: String
            switch self { case .stashApply: verb = "apply"; case .stashPop: verb = "pop"; default: verb = "drop" }
            return (Self.localPrefix(identity: true) + ["stash", verb, "stash@{\(i)}"]).map(Self.quote).joined(separator: " ")
        case .push(let branch, let setUpstream):
            guard Self.validRef(branch) else { throw SandboxCommandError(String(localized: "Invalid branch name.")) }
            args = ["push", "--no-verify", "--no-recurse-submodules", "--progress"]
                + (setUpstream ? ["--set-upstream", "origin", branch] : ["origin", "HEAD:refs/heads/" + branch])
        case .fetch: args = ["fetch", "--all", "--prune", "--no-recurse-submodules", "--progress"]
        case .fetchUpstream: args = ["fetch", "--prune", "--no-recurse-submodules", "--progress"]
        case .fastForward:
            // No network, no keys: the checkout (and any filter it triggers) runs with an agent's rights.
            let local = ["/usr/bin/git", "--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                         "-c", "submodule.recurse=false", "merge", "--ff-only", "--no-edit", "@{u}"]
            return local.map(Self.quote).joined(separator: " ")
        case .clone(let url):
            guard Self.validCloneURL(url) else { throw SandboxCommandError(String(localized: "Please use an HTTPS or SSH Git URL without a password.")) }
            args = ["clone", "--progress", "--no-recurse-submodules", "--", url, "."]
        }
        // Keep the sandbox's inherited GitLab proxy/credential configuration intact.
        // Helpers/filters may run inside that sandbox, never through the host dispatcher.
        var prefix = ["/usr/bin/env", "-u", "GIT_SSH_COMMAND", "-u", "GIT_SSH", "-u", "GIT_PROXY_COMMAND",
                      "GIT_TERMINAL_PROMPT=0", "GCM_INTERACTIVE=never",
                      "GIT_ASKPASS=/usr/bin/false", "SSH_ASKPASS=/usr/bin/false", "SSH_ASKPASS_REQUIRE=never",
                      "/usr/bin/git", "--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                      "-c", "diff.external=", "-c", "submodule.recurse=false", "-c", "protocol.ext.allow=never",
                      "-c", "protocol.file.allow=never", "-c", "core.gitProxy="]
        // These run with access to SSH keys and the keychain: take them only from the user's
        // global configuration, never from the repository's own (possibly agent-written) .git/config.
        prefix += repoOverrides
        prefix += ["-c", "core.sshCommand=" + Self.globalConfig.sshCommand, "-c", "credential.helper="]
        for helper in Self.globalConfig.credentialHelpers { prefix += ["-c", "credential.helper=" + helper] }
        return (prefix + args).map(Self.quote).joined(separator: " ")
    }

    /// Values from ~/.gitconfig (read only, no repository involved).
    static let globalConfig: (sshCommand: String, credentialHelpers: [String]) = {
        func read(_ args: [String]) -> [String] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["config", "--global"] + args
            p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        let helpers = read(["--get-all", "credential.helper"])
        return (read(["--get", "core.sshCommand"]).last ?? "/usr/bin/ssh", helpers.isEmpty ? ["osxkeychain"] : helpers)
    }()

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func validCloneURL(_ value: String) -> Bool {
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        if value.range(of: #"^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[^\s]+$"#, options: .regularExpression) != nil { return true }
        guard let url = URLComponents(string: value), ["https", "ssh"].contains(url.scheme ?? ""),
              let host = url.host, !host.isEmpty, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true,
              url.scheme != "https" || url.user == nil, !url.path.isEmpty, url.path != "/" else { return false }
        return true
    }
}

/// Runs the fixed Git operations on a sandbox command runner. No host Process, no
/// agent prompt, no chat session, no access to the app's GitLab tokens.
struct SandboxGitRunner: Sendable {
    let runner: any SandboxCommandRunner
    let root: URL
    /// Neutralised repository config keys for network operations (Git.networkSandboxOverrides).
    var repoOverrides: [String] = []
    var timeout: TimeInterval = 600
    var pollInterval: Duration = .milliseconds(200)

    typealias Failure = SandboxCommandError

    func run(_ operation: SandboxGitOperation,
             progress: @escaping @Sendable (String, Double?) -> Void = { _, _ in }) async -> Git.OpResult {
        var id: String?
        do {
            guard root.isFileURL, root.path.hasPrefix("/") else { throw Failure(String(localized: "Invalid folder. No host fallback.")) }
            try Task.checkCancellation()
            let commandID = try await runner.start(SandboxCommandRequest(
                command: try operation.command(repoOverrides: repoOverrides), cwd: root.path,
                metadata: ["source": "Hearth IDE", "operation": "git-" + operation.name]))
            id = commandID
            var cursor = 0
            var output = ""
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                try Task.checkCancellation()
                guard Date() < deadline else { throw Failure(String(localized: "The Git operation timed out and is stopped in the sandbox.")) }
                // Read the state first: output written before the exit is then complete below.
                let state = try await runner.state(of: commandID)
                // Drain output by byte cursor, including output larger than one page.
                while true {
                    let page = try await runner.output(of: commandID, from: cursor, limit: 65536)
                    guard page.next > cursor else { break }
                    cursor = page.next
                    output += page.text
                    if output.count > 200_000 { output = "…\n" + output.suffix(180_000) }
                    progress(Self.lastLine(page.text), Self.fraction(page.text))
                    if cursor >= page.size { break }
                }
                if !state.isRunning {
                    await runner.remove(commandID)
                    let ok = state == .exited(0)
                    let fallback = ok ? String(localized: "Git \(operation.name) finished") : "Git \(operation.name): \(Self.describe(state))"
                    return Git.OpResult(ok: ok, output: output.isEmpty ? fallback : output.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                try await Task.sleep(for: pollInterval)
            }
        } catch {
            if let id { await remove(id) }
            let detail = error is CancellationError ? "Git operation cancelled." : error.localizedDescription
            return Git.OpResult(ok: false, output: detail + String(localized: "\nNothing was run on the host."))
        }
    }

    private func remove(_ id: String) async {
        let runner = runner
        // Cleanup must survive cancellation of the calling UI task.
        await Task.detached { await runner.remove(id) }.value
    }

    static func describe(_ state: SandboxCommandState) -> String {
        switch state {
        case .running: String(localized: "running")
        case .exited(let code): String(localized: "exit \(code)")
        case .timedOut: String(localized: "timed out")
        case .killed: String(localized: "cancelled")
        }
    }

    private static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).last.map(String.init) ?? text
    }

    private static func fraction(_ text: String) -> Double? {
        let line = lastLine(text)
        guard let range = line.range(of: #"\d+%"#, options: .regularExpression), let value = Double(line[range].dropLast()) else { return nil }
        return min(1, max(0, value / 100))
    }
}
