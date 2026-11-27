import Foundation
import CoreServices
import CryptoKit

// Agent hooks: automations that react to what an agent did in the project. When a turn of
// the agent ends, Hearth looks at the files it created, saved or deleted and at hooks
// listening for the turn's end, and then sends the hook's prompt to that agent or runs
// its command in Hearth's nono sandbox. The format follows Kiro's `.kiro/hooks/*.json`
// (`{"version": "v1", "hooks": [...]}`); Hearth's own hooks live in `.hearth/hooks/`.
//
// Loops are ruled out by design: a turn that a hook started never triggers hooks itself.
// Hook files come from the repository (and the agent can write them), so a file only
// runs after the user allowed exactly that content (see `HookTrust`).

/// What a hook listens for.
enum HookTrigger: String, CaseIterable, Identifiable, Sendable {
    case fileSave = "FileSave"
    case fileCreate = "FileCreate"
    case fileDelete = "FileDelete"
    case agentStop = "Stop"
    case manual = "Manual"

    var id: String { rawValue }

    /// Accepts Kiro's spellings (current and the older `.kiro.hook` format).
    init?(kiro raw: String) {
        switch raw.lowercased() {
        case "filesave", "postfilesave", "fileedited", "filesaved": self = .fileSave
        case "filecreate", "filecreated": self = .fileCreate
        case "filedelete", "filedeleted": self = .fileDelete
        case "stop", "agentstop": self = .agentStop
        case "manual", "usertriggered": self = .manual
        default: return nil
        }
    }

    var isFileTrigger: Bool { self == .fileSave || self == .fileCreate || self == .fileDelete }

    var title: String {
        switch self {
        case .fileSave: String(localized: "Agent saved a file")
        case .fileCreate: String(localized: "Agent created a file")
        case .fileDelete: String(localized: "Agent deleted a file")
        case .agentStop: String(localized: "Agent finished its turn")
        case .manual: String(localized: "Manually")
        }
    }

    var symbol: String {
        switch self {
        case .fileSave: "square.and.arrow.down"
        case .fileCreate: "doc.badge.plus"
        case .fileDelete: "trash"
        case .agentStop: "flag.checkered"
        case .manual: "hand.tap"
        }
    }
}

/// How a file changed.
enum FileChangeKind: Sendable, Equatable {
    case saved, created, deleted

    var trigger: HookTrigger {
        switch self {
        case .saved: .fileSave
        case .created: .fileCreate
        case .deleted: .fileDelete
        }
    }

    /// From FSEvents item flags and whether the path exists now.
    static func classify(flags: UInt32, exists: Bool) -> FileChangeKind? {
        let f = Int(flags)
        guard f & kFSEventStreamEventFlagItemIsFile != 0 else { return nil }
        if !exists { return f & (kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0 ? .deleted : nil }
        let created = f & kFSEventStreamEventFlagItemCreated != 0
        let modified = f & (kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemInodeMetaMod) != 0
        if created && f & kFSEventStreamEventFlagItemModified == 0 { return .created }
        return modified || created ? .saved : nil
    }
}

/// One hook as written in a hook file.
struct AgentHook: Identifiable, Sendable {
    enum Action: Sendable, Equatable {
        case agent(prompt: String)
        case command(String, timeout: Int?)
        case unsupported(String)
    }

    /// File it comes from, relative to the project.
    let file: String
    /// Index in the file's `hooks` array.
    let index: Int
    var name: String
    var description: String?
    var enabled: Bool
    /// nil = a trigger Hearth doesn't support (e.g. Kiro's PreToolUse); never fires.
    var trigger: HookTrigger?
    var rawTrigger: String
    /// Regular expression matched against the project-relative path; nil = every file.
    var matcher: String?
    var action: Action

    var id: String { "\(file)#\(index)" }

    var isSupported: Bool {
        if case .unsupported = action { return false }
        return trigger != nil
    }

    func matches(path: String) -> Bool {
        guard let matcher, !matcher.isEmpty else { return true }
        guard let re = try? NSRegularExpression(pattern: matcher) else { return false }
        return re.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }
}

/// A hook file that could not be read.
struct HookFileProblem: Identifiable, Sendable, Equatable {
    let file: String
    let message: String
    var id: String { file }
}

/// The hooks of one project.
struct HookSet: Sendable {
    var hooks: [AgentHook] = []
    var problems: [HookFileProblem] = []
    /// File (relative) → SHA-256 of its content, for trust.
    var hashes: [String: String] = [:]
}

enum HookLibrary {
    static let hearthDir = ".hearth/hooks"
    static let kiroDir = ".kiro/hooks"

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func load(root: String) -> HookSet {
        var set = HookSet()
        for dir in [hearthDir, kiroDir] {
            let base = URL(fileURLWithPath: root).appendingPathComponent(dir)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
                .filter { $0.hasSuffix(".json") || $0.hasSuffix(".kiro.hook") }.sorted()
            for name in names {
                let rel = dir + "/" + name
                guard let data = try? Data(contentsOf: base.appendingPathComponent(name)) else { continue }
                set.hashes[rel] = hash(data)
                do { set.hooks += try parse(data, file: rel) } catch {
                    set.problems.append(HookFileProblem(file: rel, message: error.localizedDescription))
                }
            }
        }
        return set
    }

    struct FormatError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Reads `{"version": "v1", "hooks": [...]}` or the older single-hook `{"when", "then"}` form.
    static func parse(_ data: Data, file: String) throws -> [AgentHook] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FormatError(message: String(localized: "Not a JSON object"))
        }
        if let list = json["hooks"] as? [[String: Any]] {
            return list.enumerated().map { hook(from: $1, file: file, index: $0) }
        }
        if json["when"] != nil, json["then"] != nil { return [legacyHook(from: json, file: file)] }
        throw FormatError(message: String(localized: "No “hooks” list found"))
    }

    private static func hook(from h: [String: Any], file: String, index: Int) -> AgentHook {
        let raw = h["trigger"] as? String ?? ""
        let a = h["action"] as? [String: Any] ?? [:]
        let type = (a["type"] as? String ?? "agent").lowercased()
        let action: AgentHook.Action
        if type == "agent" || type == "askagent", let p = a["prompt"] as? String {
            action = .agent(prompt: p)
        } else if type == "command" || type == "runcommand", let c = a["command"] as? String {
            action = .command(c, timeout: (a["timeout"] as? Int) ?? (h["timeout"] as? Int))
        } else {
            action = .unsupported(type)
        }
        return AgentHook(file: file, index: index, name: h["name"] as? String ?? String(localized: "Hook \(index + 1)"),
                         description: h["description"] as? String, enabled: h["enabled"] as? Bool ?? true,
                         trigger: HookTrigger(kiro: raw), rawTrigger: raw, matcher: h["matcher"] as? String, action: action)
    }

    private static func legacyHook(from json: [String: Any], file: String) -> AgentHook {
        let when = json["when"] as? [String: Any] ?? [:]
        let then = json["then"] as? [String: Any] ?? [:]
        let raw = when["type"] as? String ?? ""
        let patterns = when["patterns"] as? [String] ?? []
        let action: AgentHook.Action = if let p = then["prompt"] as? String { .agent(prompt: p) }
            else if let c = then["command"] as? String { .command(c, timeout: nil) }
            else { .unsupported(then["type"] as? String ?? "") }
        return AgentHook(file: file, index: 0, name: json["name"] as? String ?? file,
                         description: json["description"] as? String, enabled: json["enabled"] as? Bool ?? true,
                         trigger: HookTrigger(kiro: raw), rawTrigger: raw,
                         matcher: patterns.isEmpty ? nil : patterns.map(globToRegex).joined(separator: "|"), action: action)
    }

    /// `src/**/*.ts` → `^src/(.*/)?[^/]*\.ts$`; a pattern without `/` matches the file name anywhere.
    static func globToRegex(_ glob: String) -> String {
        var re = ""
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    if i + 2 < chars.count, chars[i + 2] == "/" { re += "(.*/)?"; i += 3; continue }
                    re += ".*"; i += 2; continue
                }
                re += "[^/]*"
            } else if c == "?" {
                re += "[^/]"
            } else if c == "{" {
                re += "("
            } else if c == "}" {
                re += ")"
            } else if c == "," {
                re += "|"
            } else {
                re += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        return (glob.contains("/") ? "^" : "(^|/)") + re + "$"
    }

    // MARK: Writing (Hearth's own files; Kiro files are changed in place)

    /// Writes a new hook to `.hearth/hooks/<slug>.json` and returns the relative path.
    static func create(name: String, description: String?, trigger: HookTrigger, matcher: String?,
                       action: AgentHook.Action, root: String) throws -> String {
        let base = URL(fileURLWithPath: root).appendingPathComponent(hearthDir)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let stem = SpecLibrary.slug(name)
        var slug = stem
        var n = 2
        while FileManager.default.fileExists(atPath: base.appendingPathComponent(slug + ".json").path) { slug = "\(stem)-\(n)"; n += 1 }
        var hook: [String: Any] = ["name": name, "trigger": trigger.rawValue, "enabled": true]
        if let description, !description.isEmpty { hook["description"] = description }
        if let matcher, !matcher.isEmpty, trigger.isFileTrigger { hook["matcher"] = matcher }
        switch action {
        case .agent(let prompt): hook["action"] = ["type": "agent", "prompt": prompt]
        case .command(let c, let timeout):
            var a: [String: Any] = ["type": "command", "command": c]
            if let timeout { a["timeout"] = timeout }
            hook["action"] = a
        case .unsupported: throw FormatError(message: "unsupported action")
        }
        let rel = hearthDir + "/" + slug + ".json"
        try write(["version": "v1", "hooks": [hook]], to: URL(fileURLWithPath: root).appendingPathComponent(rel))
        return rel
    }

    static func setEnabled(_ enabled: Bool, hook: AgentHook, root: String) throws {
        try edit(hook, root: root) { list in list[hook.index]["enabled"] = enabled }
    }

    static func delete(_ hook: AgentHook, root: String) throws {
        let url = URL(fileURLWithPath: root).appendingPathComponent(hook.file)
        var removeFile = false
        try edit(hook, root: root) { list in
            list.remove(at: hook.index)
            removeFile = list.isEmpty
        }
        if removeFile { try FileManager.default.removeItem(at: url) }
    }

    private static func edit(_ hook: AgentHook, root: String, _ change: (inout [[String: Any]]) -> Void) throws {
        let url = URL(fileURLWithPath: root).appendingPathComponent(hook.file)
        guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { return }
        if var list = json["hooks"] as? [[String: Any]] {
            guard list.indices.contains(hook.index) else { return }
            change(&list)
            json["hooks"] = list
        } else {
            // Older single-hook file: treat it as a list of one.
            var list = [json]
            change(&list)
            if list.isEmpty { try FileManager.default.removeItem(at: url); return }
            json = list[0]
        }
        try write(json, to: url)
    }

    private static func write(_ json: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}

/// Which hook files the user allowed to run, by content hash. Kept in the app's own
/// defaults, outside the project, so neither a cloned repository nor the agent can
/// approve a hook; any change to the file needs another approval.
struct HookTrust {
    var defaults: UserDefaults = .standard
    static let key = "agentHooks.trusted"

    private var map: [String: String] { defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:] }

    func isTrusted(_ file: String, root: String, hash: String?) -> Bool {
        guard let hash else { return false }
        return map[Self.path(file, root)] == hash
    }

    func trust(_ file: String, root: String, hash: String) {
        var m = map
        m[Self.path(file, root)] = hash
        defaults.set(m, forKey: Self.key)
    }

    func revoke(_ file: String, root: String) {
        var m = map
        m[Self.path(file, root)] = nil
        defaults.set(m, forKey: Self.key)
    }

    private static func path(_ file: String, _ root: String) -> String { URL(fileURLWithPath: root).appendingPathComponent(file).standardizedFileURL.path }
}

/// A session the engine can talk to.
struct HookRunInfo: Sendable, Equatable {
    var id: String
    var directory: String
    var status: AgentStatus
    var isRunning: Bool
    var isSelected = false
}

/// Watches the projects of running sessions and runs their hooks.
@MainActor
@Observable
final class AgentHooksEngine {
    struct CommandResult: Sendable {
        var exitCode: Int32?
        var output: String
    }

    struct Dependencies {
        var runs: @MainActor () -> [HookRunInfo]
        var send: @MainActor (_ runID: String, _ prompt: String) -> Void
        var runCommand: (_ root: String, _ command: String, _ timeout: Int?) async -> CommandResult
    }

    struct Activity: Identifiable, Sendable {
        enum Outcome: Sendable, Equatable { case sent, queued, noAgent, commandOK, commandFailed(Int32?), running }
        let id = UUID()
        let date: Date
        let root: String
        let hook: String
        let detail: String
        var outcome: Outcome
    }

    private(set) var sets: [String: HookSet] = [:]
    private(set) var activity: [Activity] = []
    /// Bumped when trust changes (trust lives outside the observed state).
    private(set) var trustRevision = 0

    @ObservationIgnored let trust: HookTrust
    @ObservationIgnored private let deps: Dependencies
    @ObservationIgnored private var watchers: [String: FileEventStream] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastStatus: [String: AgentStatus] = [:]

    /// A turn of one session and the files it touched.
    struct Turn {
        let runID: String
        let root: String
        var byHook: Bool
        var files: [String: FileChangeKind] = [:]
        var endsAt: Date?
    }
    @ObservationIgnored private(set) var turns: [String: Turn] = [:]
    /// Sessions whose next turn was started by a hook.
    @ObservationIgnored private var hookStarted: [String: Date] = [:]
    @ObservationIgnored private var queue: [(runID: String, prompt: String, activity: UUID)] = []

    /// Time FSEvents needs to deliver the last writes of a turn.
    static let settle: TimeInterval = 1.5

    init(deps: Dependencies, trust: HookTrust = HookTrust()) {
        self.deps = deps
        self.trust = trust
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(now: Date()) }
        }
    }

    // MARK: Hooks of a project

    func hooks(for root: String) -> HookSet {
        if let s = sets[root] { return s }
        let s = HookLibrary.load(root: root)
        sets[root] = s
        return s
    }

    func reload(_ root: String) { sets[root] = HookLibrary.load(root: root) }

    func isTrusted(_ hook: AgentHook, root: String) -> Bool {
        trust.isTrusted(hook.file, root: root, hash: sets[root]?.hashes[hook.file])
    }

    func allow(file: String, root: String) {
        reload(root)
        if let h = sets[root]?.hashes[file] { trust.trust(file, root: root, hash: h) }
        trustRevision += 1
    }

    func allowRevoked() { trustRevision += 1 }

    /// After Hearth itself wrote a file: keep it allowed if it was before (or is new from Hearth).
    func wrote(file: String, root: String, wasTrusted: Bool) {
        reload(root)
        if wasTrusted, let h = sets[root]?.hashes[file] { trust.trust(file, root: root, hash: h) }
        trustRevision += 1
    }

    private func active(_ root: String) -> [AgentHook] {
        hooks(for: root).hooks.filter { $0.enabled && $0.isSupported && isTrusted($0, root: root) }
    }

    // MARK: Events

    /// File changes under `root` (paths relative to it).
    func filesChanged(root: String, _ changes: [(String, FileChangeKind)], now: Date = Date()) {
        var reloadHooks = false
        for (path, kind) in changes {
            if path.hasPrefix(HookLibrary.hearthDir + "/") || path.hasPrefix(HookLibrary.kiroDir + "/") { reloadHooks = true; continue }
            if Self.ignored(path) { continue }
            // Attributed to the turn(s) running in this folder, or one that just ended.
            for key in turns.keys where turns[key]?.root == root {
                if let end = turns[key]?.endsAt, now > end { continue }
                turns[key]?.files[path] = kind
            }
        }
        if reloadHooks { reload(root) }
    }

    static func ignored(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.contains { [".git", "node_modules", ".build", "DerivedData", ".swiftpm", ".DS_Store"].contains(String($0)) }
    }

    func tick(now: Date) {
        let runs = deps.runs()
        reconcileWatchers(runs)
        for run in runs {
            let previous = lastStatus[run.id]
            lastStatus[run.id] = run.status
            if run.status == .running, previous != .running {
                let byHook = hookStarted.removeValue(forKey: run.id) != nil
                turns[run.id] = Turn(runID: run.id, root: run.directory, byHook: byHook)
            } else if previous == .running, run.status != .running, run.status != .needsInput {
                // Turn over (asking for permission is part of the turn): wait for the last file events.
                turns[run.id]?.endsAt = now.addingTimeInterval(Self.settle)
            }
        }
        // A hook prompt that never led to a turn (agent ignored it) must not mark a later one.
        hookStarted = hookStarted.filter { now.timeIntervalSince($0.value) < 30 }
        for (id, turn) in turns {
            guard let end = turn.endsAt, now >= end else { continue }
            turns[id] = nil
            if !turn.byHook { finished(turn, now: now) }
        }
        flushQueue(runs, now: now)
    }

    private func finished(_ turn: Turn, now: Date) {
        for hook in active(turn.root) {
            guard let trigger = hook.trigger else { continue }
            if trigger.isFileTrigger {
                let files = turn.files.filter { $0.value.trigger == trigger && hook.matches(path: $0.key) }.keys.sorted()
                if !files.isEmpty { fire(hook, root: turn.root, runID: turn.runID, files: files, now: now) }
            } else if trigger == .agentStop {
                fire(hook, root: turn.root, runID: turn.runID, files: [], now: now)
            }
        }
    }

    /// Runs a hook now (▶ in the hooks pane), for the selected or first session of the folder.
    func runManually(_ hook: AgentHook, root: String) {
        let runs = deps.runs().filter { $0.directory == root && $0.isRunning }
        let target = runs.first(where: \.isSelected) ?? runs.first
        fire(hook, root: root, runID: target?.id, files: [], now: Date())
    }

    private func fire(_ hook: AgentHook, root: String, runID: String?, files: [String], now: Date) {
        let detail = files.isEmpty ? (hook.trigger?.title ?? hook.rawTrigger) : files.prefix(3).joined(separator: ", ") + (files.count > 3 ? " +\(files.count - 3)" : "")
        switch hook.action {
        case .agent(let prompt):
            guard let runID else { log(root, hook, detail, .noAgent, now); return }
            let id = log(root, hook, detail, .queued, now)
            queue.append((runID, Self.prompt(hook, files: files, base: prompt), id))
        case .command(let command, let timeout):
            let id = log(root, hook, command, .running, now)
            Task { [deps] in
                let result = await deps.runCommand(root, command, timeout)
                let ok = result.exitCode == 0
                self.update(id, ok ? .commandOK : .commandFailed(result.exitCode))
                guard !ok, let runID else { return }
                // Like Kiro: a failing command hands its output to the agent.
                let qid = self.log(root, hook, String(localized: "Output sent to the agent"), .queued, Date())
                self.queue.append((runID, Self.failurePrompt(hook, command: command, result: result, files: files), qid))
            }
        case .unsupported:
            break
        }
    }

    private func flushQueue(_ runs: [HookRunInfo], now: Date) {
        guard !queue.isEmpty else { return }
        var sentTo: Set<String> = []
        var remaining: [(runID: String, prompt: String, activity: UUID)] = []
        for item in queue {
            guard let run = runs.first(where: { $0.id == item.runID }), run.isRunning else {
                update(item.activity, .noAgent)
                continue
            }
            // One prompt per idle agent; the next waits until that turn is over.
            let busy = run.status == .running || run.status == .needsInput || turns[run.id] != nil
                || hookStarted[run.id] != nil || sentTo.contains(run.id)
            if busy { remaining.append(item); continue }
            deps.send(run.id, item.prompt)
            hookStarted[run.id] = now
            sentTo.insert(run.id)
            update(item.activity, .sent)
        }
        queue = remaining
    }

    @discardableResult
    private func log(_ root: String, _ hook: AgentHook, _ detail: String, _ outcome: Activity.Outcome, _ now: Date) -> UUID {
        let a = Activity(date: now, root: root, hook: hook.name, detail: detail, outcome: outcome)
        activity.insert(a, at: 0)
        if activity.count > 40 { activity.removeLast(activity.count - 40) }
        return a.id
    }

    private func update(_ id: UUID, _ outcome: Activity.Outcome) {
        if let i = activity.firstIndex(where: { $0.id == id }) { activity[i].outcome = outcome }
    }

    // MARK: Prompts

    /// One line (terminals submit on newline).
    static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func prompt(_ hook: AgentHook, files: [String], base: String) -> String {
        var s = "[Hook “\(hook.name)”] " + base
        if !files.isEmpty {
            s += " — Files: " + files.prefix(20).map { "`\($0)`" }.joined(separator: ", ")
            if files.count > 20 { s += " (+\(files.count - 20))" }
        }
        return oneLine(s)
    }

    static func failurePrompt(_ hook: AgentHook, command: String, result: CommandResult, files: [String]) -> String {
        let tail = String(result.output.suffix(1500))
        let code = result.exitCode.map(String.init) ?? "timeout"
        return oneLine("[Hook “\(hook.name)”] `\(command)` failed after your last changes (exit \(code)). Output: \(tail) — Please fix the cause.")
    }

    // MARK: Watching

    private func reconcileWatchers(_ runs: [HookRunInfo]) {
        let roots = Set(runs.filter(\.isRunning).map(\.directory))
        for root in watchers.keys where !roots.contains(root) {
            watchers[root]?.stop()
            watchers[root] = nil
        }
        for root in roots where watchers[root] == nil {
            reload(root)
            let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            watchers[root] = FileEventStream(path: base) { [weak self] events in
                MainActor.assumeIsolated {
                    let changes = events.compactMap { path, flags -> (String, FileChangeKind)? in
                        guard path.hasPrefix(base + "/") else { return nil }
                        let rel = String(path.dropFirst(base.count + 1))
                        let exists = FileManager.default.fileExists(atPath: path)
                        return FileChangeKind.classify(flags: flags, exists: exists).map { (rel, $0) }
                    }
                    if !changes.isEmpty { self?.filesChanged(root: root, changes) }
                }
            }
        }
    }
}

/// File-level FSEvents for one folder, delivered on the main queue.
final class FileEventStream {
    private var stream: FSEventStreamRef?
    private let handler: ([(String, UInt32)]) -> Void

    init?(path: String, handler: @escaping ([(String, UInt32)]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<FileEventStream>.fromOpaque(info).takeUnretainedValue()
            guard let list = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            me.handler((0..<min(count, list.count)).map { (list[$0], flags[$0]) })
        }
        let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, options) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}

/// Starting points for new hooks.
enum HookTemplate: String, CaseIterable, Identifiable {
    case blank, tests, docs, translations, review, specSync, lint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: String(localized: "Empty hook")
        case .tests: String(localized: "Keep tests up to date")
        case .docs: String(localized: "Keep the documentation in sync")
        case .translations: String(localized: "Complete translations")
        case .review: String(localized: "Review each turn")
        case .specSync: String(localized: "Keep spec documents consistent")
        case .lint: String(localized: "Run the linter (command)")
        }
    }

    var trigger: HookTrigger {
        switch self {
        case .blank, .tests, .docs, .lint: .fileSave
        case .translations: .fileSave
        case .review: .agentStop
        case .specSync: .fileSave
        }
    }

    var matcher: String {
        switch self {
        case .blank: ""
        case .tests: #"\.(swift|ts|tsx|js|py|go|kt|java|rs)$"#
        case .docs: #"^(src|Sources|lib)/"#
        case .translations: #"(\.strings|\.xcstrings|locales/.*\.json|\.po)$"#
        case .review: ""
        case .specSync: #"^\.hearth/specs/[^/]+/requirements\.md$"#
        case .lint: #"\.(ts|tsx|js)$"#
        }
    }

    var isCommand: Bool { self == .lint }

    var body: String {
        switch self {
        case .blank: ""
        case .tests: String(localized: "Check whether the tests still cover the changed behaviour of these files. Update or add tests and run them. Do not change the production code.")
        case .docs: String(localized: "Check whether these changes affect documented behaviour (README, docs/). If so, update the documentation briefly; otherwise do nothing.")
        case .translations: String(localized: "Make sure every language has the same keys as the changed translation files. Add missing translations and keep placeholders intact.")
        case .review: String(localized: "Review your last turn (git diff): look for bugs, missing tests, leftover debug output and unhandled errors. Fix what you find and say briefly what you changed, or that everything is fine.")
        case .specSync: String(localized: "These requirements changed. Check design.md and tasks.md of the same spec and update them so they still match; list what you changed.")
        case .lint: "npx eslint --fix ."
        }
    }
}
