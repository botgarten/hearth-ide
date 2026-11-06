import Foundation

enum InspectorTab: String, CaseIterable, Identifiable, Codable, Sendable {
    case sessions = "Sessions", chat = "Chat"
    case directory = "Directory", git = "Git", pipelines = "CI/CD", tests = "Tests", preview = "Preview", architecture = "Architecture"
    case terminal = "Terminal"
    case journal = "Journal"
    case build = "Build & Deployment"

    /// Tabs that show files of the selected workspace (need a sandbox/session).
    var needsWorkspace: Bool { self != .sessions && self != .chat && self != .terminal && self != .journal }
    var id: String { rawValue }
    /// Keep persisted raw values/IDs compatible with existing layouts and detached windows.
    var title: String {
        switch self {
        case .sessions: String(localized: "Sessions")
        case .chat: String(localized: "Chat")
        case .directory: String(localized: "Directory")
        case .git: String(localized: "Git")
        case .pipelines: String(localized: "CI/CD")
        case .tests: String(localized: "Tests")
        case .preview: String(localized: "Editor")
        case .architecture: String(localized: "Architecture")
        case .terminal: String(localized: "Terminal")
        case .journal: String(localized: "Overview")
        case .build: String(localized: "Build & Deployment")
        }
    }
    var symbol: String {
        switch self {
        case .sessions: "tray.full"
        case .chat: "bubble.left.and.bubble.right"
        case .terminal: "terminal"
        case .journal: "list.bullet.indent"
        case .directory: "folder"
        case .git: "arrow.triangle.branch"
        case .pipelines: "point.3.filled.connected.trianglepath.dotted"
        case .tests: "checkmark.seal"
        case .preview: "doc.text.magnifyingglass"
        case .architecture: "point.3.connected.trianglepath.dotted"
        case .build: "hammer"
        }
    }
}

struct InspectorPane: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var tab: InspectorTab
}

struct GitFileChange: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    /// Porcelain v1 two-letter code, e.g. " M", "A ", "??".
    let code: String
    var added = 0
    var removed = 0

    var marker: String {
        let c = code.trimmingCharacters(in: .whitespaces)
        return c == "??" ? "U" : String(c.prefix(1))
    }
}

struct GitSnapshot: Sendable {
    var isRepo = false
    var branch = ""
    var upstream: String?
    var ahead = 0
    var behind = 0
    var changes: [GitFileChange] = []
    var recentCommits: [String] = []

    /// Status marker per repo-relative path, including all parent directories.
    var markers: [String: String] {
        var m: [String: String] = [:]
        for c in changes {
            m[c.path] = c.marker
            var parent = (c.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                m[parent] = m[parent] ?? "•"
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return m
    }
}

/// Hardened host queries/local mutations. Network commands must run in a sandbox,
/// not with repository-controlled transport helpers on the host.
enum Git {
    static let sandboxRequired = String(localized: "This command must not run through the host Git path. Fetch, pull and clone use the app’s separate sandbox Git path.")
    static let hostOptions = ["--no-pager", "--no-optional-locks",
        "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
        "-c", "core.untrackedCache=false", "-c", "core.attributesFile=/dev/null",
        "-c", "core.pager=cat", "-c", "diff.external=", "-c", "credential.helper=",
        "-c", "core.sshCommand=/usr/bin/false", "-c", "core.gitProxy=",
        "-c", "protocol.allow=never", "-c", "submodule.recurse=false"]

    static var hostEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_ATTR_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        return env
    }

    /// Git binaries the hardened host process may execute: Apple's shim and the real Git it
    /// hands over to, wherever the selected developer directory is (e.g. "Xcode-beta.app").
    static let gitExecutables: [String] = {
        var paths = ["/usr/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
                     "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--find", "git"]
        p.environment = ["PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let found = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let real = URL(fileURLWithPath: found).resolvingSymlinksInPath().path
            for path in [found, real] where p.terminationStatus == 0 && path.hasPrefix("/") && path.hasSuffix("/git")
                && FileManager.default.isExecutableFile(atPath: path) && !paths.contains(path) {
                paths.append(path)
            }
        }
        return paths
    }()

    /// Defense in depth against config/attribute changes between inspection and
    /// the actual query: only Apple's Git executable may execute, never a helper
    /// shell, filter, hook or transport. Missing Seatbelt support fails closed.
    static func hostProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        let allowed = gitExecutables.map { "  (literal \(SandboxPolicy.sbString($0)))" }.joined(separator: "\n")
        let profile = """
        (version 1)
        (allow default)
        (deny network*)
        (deny process-exec)
        (allow process-exec
        \(allowed))
        """
        process.arguments = ["-p", profile, "/usr/bin/git"] + arguments
        process.environment = hostEnvironment
        return process
    }

    /// `git config` only reads config; it does not invoke its configured helpers.
    /// Include worktree/conditional includes too. Unknown/unreadable config fails closed.
    static func filterOverrides(in dir: String) -> [String]? {
        let process = hostProcess(hostOptions + ["-C", dir, "config", "--includes", "--null", "--name-only", "--list"])
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let keys = String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
        return Set(keys.filter { $0.lowercased().hasPrefix("filter.") }).sorted().flatMap {
            ["-c", $0 + ($0.lowercased().hasSuffix(".required") ? "=false" : "=")]
        }
    }

    /// Overrides for repository config keys that would execute something or hand out
    /// credentials inside the Git network sandbox (which can read SSH keys and the keychain):
    /// clean/smudge/process filters and credential helpers, including URL-scoped ones
    /// like `credential.https://host.helper`. Nil when the config can't be read safely.
    static func networkSandboxOverrides(in dir: String) -> [String]? {
        let process = hostProcess(hostOptions + ["-C", dir, "config", "--includes", "--null", "--name-only", "--list"])
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let keys = String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
        return networkSandboxOverrides(forKeys: keys)
    }

    static func networkSandboxOverrides(forKeys keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { key in
            let k = key.lowercased()
            let risky = k.hasPrefix("filter.") || (k.hasPrefix("credential.") && k.hasSuffix(".helper"))
                || k == "core.askpass" || k.hasSuffix(".sshcommand") || k == "core.gitproxy"
            return risky && seen.insert(k).inserted
        }.sorted().flatMap { ["-c", $0 + ($0.lowercased().hasSuffix(".required") ? "=false" : "=")] }
    }

    static func safeReadArguments(_ args: [String]) -> [String]? {
        guard let command = args.first,
              ["rev-parse", "status", "diff", "log", "for-each-ref", "ls-files", "config", "show"].contains(command) else { return nil }
        if ["diff", "show", "log"].contains(command) {
            return [command, "--no-ext-diff", "--no-textconv"] + args.dropFirst()
        }
        return args
    }

    static func run(_ args: [String], in dir: String, ok: Set<Int32> = [0]) async -> String? {
        guard !Task.isCancelled else { return nil }
        return await Task.detached {
            guard let safe = safeReadArguments(args), let filters = filterOverrides(in: dir) else { return nil }
            let p = hostProcess(hostOptions + filters + ["-C", dir] + safe)
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return ok.contains(p.terminationStatus) ? String(decoding: data, as: UTF8.self) : nil
        }.value
    }

    static func toplevel(of dir: String) async -> String? {
        await run(["rev-parse", "--show-toplevel"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func snapshot(of dir: String) async -> GitSnapshot {
        var s = GitSnapshot()
        guard let status = await run(["status", "--porcelain=v1", "--branch", "--untracked-files=all"], in: dir) else {
            return s
        }
        s.isRepo = true
        for line in status.split(separator: "\n").map(String.init) {
            if line.hasPrefix("## ") {
                parseBranch(String(line.dropFirst(3)), into: &s)
            } else if line.count > 3 {
                var path = String(line.dropFirst(3))
                if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
                s.changes.append(GitFileChange(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                                               code: String(line.prefix(2))))
            }
        }
        if let numstat = await run(["diff", "HEAD", "--numstat"], in: dir) {
            var counts: [String: (Int, Int)] = [:]
            for line in numstat.split(separator: "\n") {
                let f = line.split(separator: "\t", maxSplits: 2)
                if f.count == 3 { counts[String(f[2])] = (Int(f[0]) ?? 0, Int(f[1]) ?? 0) }
            }
            for i in s.changes.indices {
                if let c = counts[s.changes[i].path] { (s.changes[i].added, s.changes[i].removed) = c }
            }
        }
        s.recentCommits = (await run(["log", "--oneline", "-8"], in: dir))?
            .split(separator: "\n").map(String.init) ?? []
        return s
    }

    static func parseBranch(_ header: String, into s: inout GitSnapshot) {
        // e.g. "main...origin/main [ahead 2, behind 1]" or "No commits yet on main"
        var rest = header
        if let bracket = rest.range(of: " [") {
            let info = rest[bracket.upperBound...].dropLast()
            for part in info.split(separator: ",") {
                let kv = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
                if kv.count == 2, let n = Int(kv[1]) {
                    if kv[0] == "ahead" { s.ahead = n } else if kv[0] == "behind" { s.behind = n }
                }
            }
            rest = String(rest[..<bracket.lowerBound])
        }
        let parts = rest.components(separatedBy: "...")
        s.branch = parts[0]
        s.upstream = parts.count > 1 ? parts[1] : nil
    }

    static func diff(path: String, in dir: String, untracked: Bool) async -> String {
        if untracked {
            return await run(["diff", "--no-index", "--", "/dev/null", path], in: dir, ok: [0, 1]) ?? ""
        }
        return await run(["diff", "HEAD", "--", path], in: dir) ?? ""
    }

    // MARK: Branches & write operations (explicit user actions only)

    struct Branch: Identifiable, Hashable, Sendable {
        let name: String
        let isRemote: Bool
        let isCurrent: Bool
        let upstream: String?
        let track: String?
        let subject: String
        let date: String
        var id: String { (isRemote ? "r/" : "l/") + name }
        /// Local branch name to use when checking out (remote "origin/x" → "x").
        var localName: String {
            guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
            return String(name[name.index(after: slash)...])
        }
    }

    static func branches(in dir: String) async -> [Branch] {
        let format = "%(HEAD)\t%(refname)\t%(refname:short)\t%(upstream:short)\t%(upstream:track)\t%(contents:subject)\t%(committerdate:relative)"
        guard let out = await run(["for-each-ref", "--sort=-committerdate", "--format=\(format)",
                                   "refs/heads", "refs/remotes"], in: dir) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, !f[1].hasSuffix("/HEAD") else { return nil }
            return Branch(name: f[2], isRemote: f[1].hasPrefix("refs/remotes/"), isCurrent: f[0] == "*",
                          upstream: f[3].isEmpty ? nil : f[3], track: f[4].isEmpty ? nil : f[4],
                          subject: f[5], date: f[6])
        }
    }

    struct OpResult: Sendable {
        let ok: Bool
        let output: String
    }

    /// Runs a mutating git command and returns its combined output for user feedback.
    static func mutate(_ args: [String], in dir: String) async -> OpResult {
        await Task.detached {
            guard let command = args.first, ["add", "apply", "branch", "switch", "clean", "restore"].contains(command) else {
                return OpResult(ok: false, output: sandboxRequired)
            }
            guard let filters = filterOverrides(in: dir) else { return OpResult(ok: false, output: String(localized: "The Git configuration could not be read safely.")) }
            // Silently bypassing an LFS/encryption clean/smudge filter could corrupt files.
            guard filters.isEmpty else { return OpResult(ok: false, output: String(localized: "The repository uses filters. ") + sandboxRequired) }
            let p = hostProcess(hostOptions + ["-C", dir] + args)
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            do { try p.run() } catch { return OpResult(ok: false, output: error.localizedDescription) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return OpResult(ok: p.terminationStatus == 0,
                            output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    static func checkout(_ branch: Branch, in dir: String) async -> OpResult {
        guard branch.isRemote else { return await mutate(["switch", branch.name], in: dir) }
        let locals = await branches(in: dir).filter { !$0.isRemote }.map(\.name)
        if locals.contains(branch.localName) { return await mutate(["switch", branch.localName], in: dir) }
        return await mutate(["switch", "--track", branch.name], in: dir)
    }

    static func show(commit: String, in dir: String) async -> String {
        await run(["show", "--stat", "--patch", "--format=fuller", "--end-of-options", commit, "--"], in: dir) ?? ""
    }

    /// Suggested folder name for a clone URL ("git@host:group/my-repo.git" → "my-repo").
    static func repoName(from url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let last = s.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return last
    }

    static func looksLikeCloneURL(_ url: String) -> Bool {
        let s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return SandboxGitOperation.validCloneURL(s) && !repoName(from: s).isEmpty
    }

}
