import Foundation

/// Runs agents inside a nono sandbox (Seatbelt on macOS). Writes one nono profile
/// per run and builds the command line; the terminal view starts the process.
enum SandboxManager {
    static let nonoVersion = "v0.80.0"

    enum Failure: LocalizedError {
        case nonoMissing
        case agentMissing(AgentKind)
        case outsideHome(String)
        case protectedFolder(String)

        var errorDescription: String? {
            switch self {
            case .nonoMissing:
                String(localized: "nono was not found. The app bundle has it in Contents/Helpers; for development run scripts/fetch-nono.sh.")
            case .agentMissing(let kind):
                String(localized: "\(kind.displayName) is not installed (\(kind.executable) is not on the PATH).") + (kind.installHint.isEmpty ? "" : " Installation: \(kind.installHint)")
            case .outsideHome(let dir):
                String(localized: "The folder must be inside your home folder: \(dir)")
            case .protectedFolder(let reason):
                reason
            }
        }
    }

    // MARK: Locating tools

    /// nono: HEARTH_NONO_BIN, the app bundle, a development checkout's Vendor folder, then PATH.
    static func locateNono() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["HEARTH_NONO_BIN"] { candidates.append(override) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/nono").path)
        // `swift run`: the executable lives in <repo>/.build/<config>/; walk up to the repo.
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<5 {
            guard let d = dir else { break }
            candidates.append(d.appendingPathComponent("Vendor/nono/\(nonoVersion)/nono").path)
            dir = d.deletingLastPathComponent()
        }
        candidates += searchPath.map { ($0 as NSString).appendingPathComponent("nono") }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// PATH of the user's login shell (GUI apps start with a minimal PATH), plus common tool folders.
    static let searchPath: [String] = {
        var dirs: [String] = []
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            dirs = String(decoding: data, as: UTF8.self).split(separator: ":").map(String.init)
        }
        let home = NSHomeDirectory()
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
                 "\(home)/.bun/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }()

    static func locate(_ kind: AgentKind) -> URL? {
        if kind == .shell { return URL(fileURLWithPath: "/bin/zsh") }
        return searchPath.map { URL(fileURLWithPath: $0).appendingPathComponent(kind.executable) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Profile

    /// Hearth's own data (sessions, settings, profiles). `HEARTH_SUPPORT_DIR` points a development
    /// instance elsewhere so it never touches the installed app's sessions.
    static var supportDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["HEARTH_SUPPORT_DIR"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Hearth")
    }

    /// Neutral folder for logins started from the settings (a sandbox needs a working folder).
    static var loginDirectory: URL {
        let url = supportDirectory.appendingPathComponent("Anmeldung")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func runDirectory(_ runID: String) -> URL {
        supportDirectory.appendingPathComponent("runs/\(runID)")
    }

    /// Script files referenced by hooks in the agent's Claude settings (Hearth's copy),
    /// below home and outside protected areas, so status scripts like iTerm2's keep working.
    static func claudeHookScripts(settingsFile: String, home: String = NSHomeDirectory()) -> [String] {
        guard let data = FileManager.default.contents(atPath: settingsFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return [] }
        var commands: [String] = []
        for case let groups as [[String: Any]] in hooks.values {
            for group in groups {
                for case let hook as [String: Any] in group["hooks"] as? [Any] ?? [] {
                    if let c = hook["command"] as? String { commands.append(c) }
                }
            }
        }
        var paths = Set<String>()
        for command in commands {
            for token in command.split(whereSeparator: { $0 == " " || $0 == "'" || $0 == "\"" }) {
                let path = token.hasPrefix("~/") ? home + token.dropFirst() : String(token)
                guard path.hasPrefix(home + "/"), !path.contains("/.ssh"),
                      FileManager.default.isReadableFile(atPath: path) else { continue }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue { paths.insert(path) }
            }
        }
        return paths.sorted()
    }

    /// A currently free TCP port on 127.0.0.1.
    static func freeLocalPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { throw POSIXError(.EADDRINUSE) }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// Starts `opencode serve` on the given port, waits until it listens, runs the client and
    /// stops the server when the client exits. Args: opencode, port, log, client args.
    static let openCodeLauncher = #"""
    set -eu
    oc="$1"; port="$2"; log="$3"; shift 3
    "$oc" serve --hostname 127.0.0.1 --port "$port" >"$log" 2>&1 &
    srv=$!
    trap 'kill "$srv" 2>/dev/null || true' EXIT
    trap 'exit 130' INT TERM HUP
    i=0
    until grep -q "server listening" "$log" 2>/dev/null; do
      if ! kill -0 "$srv" 2>/dev/null; then echo "The OpenCode server could not start:" >&2; cat "$log" >&2; exit 1; fi
      i=$((i + 1)); if [ "$i" -gt 300 ]; then echo "The OpenCode server does not start (30 s)" >&2; exit 1; fi
      sleep 0.1
    done
    exec 3<&0
    "$oc" "$@" <&3 3<&- &
    cli=$!
    stop() {
      trap '' INT TERM HUP
      kill -TERM "$cli" 2>/dev/null || true
      (sleep 1; kill -KILL "$cli" 2>/dev/null) </dev/null >/dev/null 2>&1 &
      wait "$cli" || true
      exit 130
    }
    trap stop INT TERM HUP
    wait "$cli"
    """#

    // MARK: Launch

    struct Launch {
        let executable: String
        let arguments: [String]
        let environment: [String]
        let directory: String
    }

    /// Checks a folder a sandbox should work in: below home, not a protected area.
    static func validateWorkdir(_ directory: String) throws -> String {
        let home = NSHomeDirectory()
        let resolved = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(home + "/") else { throw Failure.outsideHome(directory) }
        if let reason = SandboxSettings.protectedReason(resolved, home: home, support: supportDirectory.path),
           resolved != loginDirectory.path {
            throw Failure.protectedFolder(reason)
        }
        return resolved
    }

    /// The context for a sandbox in `directory` (nil: no project folder, e.g. a profile preview).
    static func context(runDirectory: URL, directory: String?, settings: SandboxSettings,
                        hookScripts: [String] = [], gitHosts: [String] = [],
                        extraDomains: [String] = [], extraPorts: [Int] = []) -> SandboxContext {
        var settings = settings
        // nono refuses grants for paths that don't exist.
        let exists = { (f: SandboxSettings.Folder) in FileManager.default.fileExists(atPath: f.path) }
        settings.folders = settings.folders.filter(exists)
        settings.projects = settings.projects.map { var p = $0; p.folders = p.folders.filter(exists); return p }
        return SandboxContext(home: NSHomeDirectory(), support: supportDirectory.path, runDirectory: runDirectory.path,
                              workdir: directory, settings: settings, hookScripts: hookScripts, gitHosts: gitHosts,
                              extraDomains: extraDomains, extraPorts: extraPorts)
    }

    /// Writes the profile (and status hooks) for one sandbox and returns how to start it.
    static func prepare(_ purpose: SandboxPurpose, runID: String, directory: String, arguments agentArguments: [String],
                        statusHooks: Bool = true, openPorts extraPorts: [Int] = [], gitHosts: [String] = [],
                        extraDomains: [String] = []) throws -> Launch {
        let kind = purpose.kind
        guard let nono = locateNono() else { throw Failure.nonoMissing }
        guard let agent = locate(kind) else { throw Failure.agentMissing(kind) }
        let resolved = try validateWorkdir(directory)

        let agentHome = AgentHome.layout(for: kind, support: supportDirectory.path, home: NSHomeDirectory())
        try agentHome.prepare()

        let runDir = runDirectory(runID)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        var args = agentArguments
        var journalBin: URL?
        if statusHooks {
            args = try AgentStatusHooks.install(kind: kind, runDirectory: runDir) + args
            if kind != .shell, JournalSupport.enabled {
                journalBin = try JournalSupport.install(runDirectory: runDir)
                args = JournalSupport.arguments(kind: kind) + args
            }
        }
        var program = agent.path
        var openPorts: [Int] = extraPorts
        var extraEnv: [String: String] = [:]
        if kind == .opencode, args.first != "auth" {
            // OpenCode's clients attach to a shared background service on a fixed port (outside any
            // sandbox), and --standalone binds a random port nono can't allow without opening every
            // local port. Run a private server on one picked port, protected by a per-run password.
            let port = try freeLocalPort()
            openPorts.append(port)
            extraEnv["OPENCODE_SERVER_PASSWORD"] = UUID().uuidString + UUID().uuidString
            args = ["-c", openCodeLauncher, "hearth-opencode", agent.path, String(port),
                    runDir.appendingPathComponent("opencode-server.log").path,
                    "--server", "http://127.0.0.1:\(port)"] + args
            program = "/bin/sh"
        }

        let hooks = agentHome.root.map { claudeHookScripts(settingsFile: $0 + "/settings.json") } ?? []
        let policy = SandboxPolicy.make(purpose, context(runDirectory: runDir, directory: resolved, settings: .load(),
                                                         hookScripts: kind == .claude ? hooks : [],
                                                         gitHosts: gitHosts, extraDomains: extraDomains,
                                                         extraPorts: openPorts))
        let profileURL = runDir.appendingPathComponent("nono-profile.json")
        try policy.profileData.write(to: profileURL, options: .atomic)

        var env = ProcessInfo.processInfo.environment
        // Never pass on state of an agent session Hearth itself was started from.
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK")
            || key == "CLAUDE_CONFIG_DIR" || key == "CODEX_HOME" || key.hasPrefix("XDG_")
            || key == "CODEX_SANDBOX" || key.hasPrefix("OPENCODE_") || key.hasPrefix("NONO_") {
            env[key] = nil
        }
        env["PATH"] = ((journalBin.map { [$0.path] } ?? []) + searchPath).joined(separator: ":")
        if journalBin != nil { env["HEARTH_JOURNAL"] = JournalSupport.url(runDirectory: runDir).path }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "hearth"
        env["HEARTH_RUN_ID"] = runID
        env["NONO_NO_UPDATE_CHECK"] = "1"
        env["NONO_NO_SAVE_PROMPT"] = "1"
        env["NONO_NO_PACK_UPDATE_HINTS"] = "1"
        if env["LANG"] == nil { env["LANG"] = "de_DE.UTF-8" }
        // The agent's private configuration folder (also set in the profile).
        env.merge(agentHome.environment) { $1 }
        env.merge(extraEnv) { $1 }

        let nonoArgs = ["run", "--silent", "--profile", profileURL.path, "--allow-cwd", "--no-diagnostics",
                        "--log-file", runDir.appendingPathComponent("nono.log").path]
            + policy.credentialFlags + ["--", program] + args
        return Launch(executable: nono.path, arguments: nonoArgs,
                      environment: env.map { "\($0.key)=\($0.value)" }, directory: resolved)
    }
}

/// Status reporting from inside the sandbox: the agent appends one JSON line per
/// event to `<run>/events.jsonl` (the only Hearth path it may write); the app tails it.
enum AgentStatusHooks {
    static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                               "Notification", "Stop", "SessionEnd"]

    /// Writes the hook script/settings and returns the extra agent arguments that enable them.
    static func install(kind: AgentKind, runDirectory: URL) throws -> [String] {
        let events = runDirectory.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: events.path) {
            FileManager.default.createFile(atPath: events.path, contents: nil)
        }
        switch kind.statusSource {
        case .hooks:
            // Hook input is one JSON object on stdin; newlines only occur as whitespace.
            let script = runDirectory.appendingPathComponent("hook.sh")
            try "#!/bin/sh\n{ /usr/bin/tr -d '\\n\\r'; echo; } >> \"$(dirname \"$0\")/events.jsonl\"\nexit 0\n"
                .write(to: script, atomically: true, encoding: .utf8)
            let command = "/bin/sh '\(script.path)'"
            var hooks: [String: Any] = [:]
            for event in claudeEvents {
                hooks[event] = [["hooks": [["type": "command", "command": command, "timeout": 5]]]]
            }
            let settings = runDirectory.appendingPathComponent("claude-settings.json")
            let data = try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settings, options: .atomic)
            return ["--settings", settings.path]
        case .notify:
            // Codex calls `notify` with the event JSON as the last argument after each turn.
            let script = runDirectory.appendingPathComponent("notify.sh")
            try "#!/bin/sh\nprintf '%s' \"$1\" | /usr/bin/tr -d '\\n\\r' >> \"$(dirname \"$0\")/events.jsonl\"; echo >> \"$(dirname \"$0\")/events.jsonl\"\nexit 0\n"
                .write(to: script, atomically: true, encoding: .utf8)
            return ["-c", "notify=[\"/bin/sh\",\"\(script.path)\"]"]
        case .terminal:
            return []
        }
    }
}
