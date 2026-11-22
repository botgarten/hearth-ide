import Foundation

/// Writes a commit message for the current changes with one of the agent CLIs, run once
/// and non-interactively in the agent's own sandbox (same login, same rights as a session,
/// but without tools: the diff comes from Hearth, the agent only answers).
enum CommitMessageGenerator {
    /// Agents with a dependable one-shot mode.
    static let supported: [AgentKind] = [.claude, .codex, .gemini]

    /// Upper bound for the diff in the prompt; larger diffs are cut (the file list stays complete).
    /// About 5k tokens: enough to describe a change, and a commit message is not worth more.
    static let maxDiff = 20_000

    /// Generated files whose diff says nothing about the change (they stay in the file list).
    static let noisePatterns = ["Package.resolved", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock",
                                "pnpm-lock.yaml", "bun.lockb", "Cargo.lock", "Gemfile.lock", "poetry.lock",
                                "composer.lock", "go.sum", "Podfile.lock", "*.min.js", "*.min.css", "*.map"]

    /// Pathspec that leaves the noise out of `git diff`.
    static let diffPathspec = ["--", "."] + noisePatterns.map { ":(exclude,glob)**/" + $0 }

    static func isNoise(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return noisePatterns.contains { pattern in
            pattern.hasPrefix("*") ? name.hasSuffix(pattern.dropFirst()) : name == pattern
        }
    }

    /// The model for the one-shot call: writing a commit message is a small task.
    static let claudeModel = "haiku"
    static let claudeSystemPrompt = "You write concise, accurate git commit messages. Answer with the message only."

    struct Input: Sendable, Equatable {
        /// `git diff --stat` style overview of every file.
        var files: String
        var diff: String
        var recentSubjects: [String]
        var truncated = false
        var stagedOnly: Bool
    }

    enum Failure: LocalizedError {
        case noChanges, empty(String), timedOut

        var errorDescription: String? {
            switch self {
            case .noChanges: String(localized: "There are no changes to describe.")
            case .empty(let output):
                output.isEmpty ? String(localized: "The agent returned no message.")
                    : String(localized: "The agent returned no message: \(output)")
            case .timedOut: String(localized: "The agent did not answer in time.")
            }
        }
    }

    // MARK: Input

    /// The staged changes, or every change when nothing is staged yet.
    static func input(in root: String, changes: [GitFileChange]) async -> Input? {
        let staged = changes.contains(where: \.isStaged)
        var stat: String
        var diff: String
        if staged {
            stat = await Git.run(["diff", "--cached", "--stat=200", "--no-color"], in: root) ?? ""
            diff = await Git.run(["diff", "--cached", "--no-color", "-U1"] + diffPathspec, in: root) ?? ""
        } else {
            // No HEAD yet (first commit): compare with the index instead.
            let base = await Git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root) != nil ? ["HEAD"] : []
            stat = await Git.run(["diff"] + base + ["--stat=200", "--no-color"], in: root) ?? ""
            diff = await Git.run(["diff"] + base + ["--no-color", "-U1"] + diffPathspec, in: root) ?? ""
            // New files are not in `git diff`: list them and show the first few.
            let untracked = changes.filter { $0.code == "??" }
            if !untracked.isEmpty {
                stat += (stat.isEmpty ? "" : "\n") + untracked.map { " \($0.path) (new)" }.joined(separator: "\n")
                for change in untracked.filter({ !isNoise($0.path) }).prefix(8) where diff.count < maxDiff {
                    diff += await Git.diff(path: change.path, in: root, untracked: true)
                }
            }
        }
        guard !stat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !diff.isEmpty else { return nil }
        let subjects = await Git.log(limit: 12, in: root).map(\.subject)
        var input = Input(files: stat.trimmingCharacters(in: .newlines), diff: diff, recentSubjects: subjects, stagedOnly: staged)
        if diff.count > maxDiff {
            input.diff = String(diff.prefix(maxDiff))
            input.truncated = true
        }
        return input
    }

    static func prompt(_ input: Input) -> String {
        var p = """
        Write a git commit message for the changes below.

        Rules:
        - Output only the commit message itself: no explanations, no quotes, no Markdown code fences.
        - First line: a concise summary of at most 72 characters, in the imperative mood.
        - If the change needs more explanation, add a blank line and a short body (wrapped at 72 characters) that says what changed and why. Leave the body out for small, obvious changes.
        - Follow the language and conventions (prefixes, capitalization, style) of the recent commit messages if there are any; otherwise write in English.
        - Do not mention files or details that are not in the changes.

        """
        if !input.recentSubjects.isEmpty {
            p += "\nRecent commit messages of this repository:\n"
            p += input.recentSubjects.map { "- " + $0 }.joined(separator: "\n") + "\n"
        }
        p += "\n" + (input.stagedOnly ? "Changed files (staged):" : "Changed files:") + "\n" + input.files + "\n"
        p += "\nDiff" + (input.truncated ? " (cut off, too long)" : "") + ":\n" + input.diff
        return p
    }

    // MARK: Agent call

    /// Command line for the one-shot call. Claude Code reads the prompt from stdin.
    /// Kept small on purpose: a small model, no tools, no MCP servers and (Claude) a one-line
    /// system prompt instead of the agent's large default one.
    static func arguments(for kind: AgentKind, prompt: String) -> (args: [String], stdin: String?) {
        switch kind {
        case .claude:
            (["--print", "--output-format", "text", "--no-session-persistence", "--tools=",
              "--strict-mcp-config", "--model", claudeModel, "--system-prompt", claudeSystemPrompt], prompt)
        case .codex:
            (["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never",
              "-c", "model_reasoning_effort=\"low\"", prompt], nil)
        case .gemini:
            (["--prompt", prompt], nil)
        default:
            ([], nil)
        }
    }

    /// The message from the agent's answer: no terminal codes, fences, quotes or preamble.
    static func clean(_ output: String) -> String {
        var text = output.replacingOccurrences(of: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A fenced block: take its content.
        if let open = text.range(of: "```") {
            let afterOpen = text[open.upperBound...]
            let bodyStart = afterOpen.firstIndex(of: "\n").map { afterOpen.index(after: $0) } ?? afterOpen.endIndex
            let body = text[bodyStart...]
            if let close = body.range(of: "```") { text = String(body[..<close.lowerBound]) }
        }
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first?.trimmingCharacters(in: .whitespaces).lowercased(),
           first.hasSuffix(":"), first.contains("commit message") {
            lines.removeFirst()
        }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        for quote in ["\"", "'", "`"] where text.count > 1 && text.hasPrefix(quote) && text.hasSuffix(quote) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    static func generate(with kind: AgentKind, in root: String, changes: [GitFileChange],
                         timeout: Duration = .seconds(180)) async throws -> String {
        guard let input = await input(in: root, changes: changes) else { throw Failure.noChanges }
        let call = arguments(for: kind, prompt: prompt(input))
        let runID = "msg-" + UUID().uuidString.lowercased()
        defer { try? FileManager.default.removeItem(at: SandboxManager.runDirectory(runID)) }
        let launch = try SandboxManager.prepare(.agent(kind), runID: runID, directory: root,
                                                arguments: call.args, statusHooks: false)
        let result = try await run(launch, stdin: call.stdin, timeout: timeout)
        let message = clean(result.stdout)
        guard result.status == 0, SandboxGitOperation.validMessage(message) else {
            let detail = (result.status == 0 ? result.stdout : result.stderr + "\n" + result.stdout)
                .lastNonEmptyLines(3)
            throw Failure.empty(clean(detail))
        }
        return message
    }

    private final class Output: @unchecked Sendable {
        var stdout = Data()
        var stderr = Data()
    }

    private static func run(_ launch: SandboxManager.Launch, stdin: String?,
                            timeout: Duration) async throws -> (status: Int32, stdout: String, stderr: String) {
        let box = ProcessBox()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: launch.directory)
        var env = Dictionary(launch.environment.compactMap { line -> (String, String)? in
            guard let eq = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<eq]), String(line[line.index(after: eq)...]))
        }, uniquingKeysWith: { $1 })
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = stdin.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let output = Output()
                let group = DispatchGroup()
                group.enter(); group.enter()
                DispatchQueue.global().async { output.stdout = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                DispatchQueue.global().async { output.stderr = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let timedOut = Flag()
                process.terminationHandler = { p in
                    group.wait()
                    if timedOut.value {
                        continuation.resume(throwing: Failure.timedOut)
                    } else if p.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: (p.terminationStatus,
                                                        String(decoding: output.stdout, as: UTF8.self),
                                                        String(decoding: output.stderr, as: UTF8.self)))
                    }
                }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                if let input, let stdin {
                    DispatchQueue.global().async {
                        input.fileHandleForWriting.write(Data(stdin.utf8))
                        try? input.fileHandleForWriting.close()
                    }
                }
                Task.detached {
                    try? await Task.sleep(for: timeout)
                    if box.process.isRunning { timedOut.value = true; box.process.terminate() }
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }
}
