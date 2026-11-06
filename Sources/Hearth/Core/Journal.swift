import Foundation

/// The structured history of an agent session ("Anti-Burnout"): steps, decisions with their
/// reasons and open questions as a tree, so nobody has to read the agent's whole output.
///
/// Any agent can fill it: inside the sandbox `hearth-journal` appends one JSON line per
/// entry to `<run>/journal.jsonl` (the run folder is the only Hearth path the sandbox may
/// write). Hearth also appends the user's revocations there. Later lines with the same `id`
/// update earlier ones. The file is written from inside the sandbox, so everything read
/// from it is bounded and sanitized.
enum JournalKind: String, Sendable { case step, decision, question }

enum JournalStatus: String, Sendable {
    case planned, running, done, blocked
    case open, answered
}

struct JournalNode: Identifiable, Equatable, Sendable {
    let id: String
    var kind: JournalKind
    var parent: String?
    var title: String
    var status: JournalStatus
    var why: String?
    var rejected: [String] = []
    var answer: String?
    var revoked: Revocation?
    /// Order of first appearance, stable across updates.
    var order: Int

    struct Revocation: Equatable, Sendable {
        var reason: String
        var replacedBy: String?
    }
}

struct Journal: Equatable, Sendable {
    private(set) var nodes: [String: JournalNode] = [:]
    private var nextOrder = 0

    static let maxTextLength = 600
    static let maxNodes = 2000
    static let maxRejected = 8

    var isEmpty: Bool { nodes.isEmpty }
    var nodeIDs: [String] { Array(nodes.keys) }

    /// Roots first-appearance ordered, children below their parent. A node whose parent
    /// is unknown (or would form a cycle) is shown at the top level.
    var roots: [JournalNode] { children(of: nil) }

    func children(of parent: String?) -> [JournalNode] {
        nodes.values
            .filter { effectiveParent($0) == parent }
            .sorted { $0.order < $1.order }
    }

    func node(_ id: String) -> JournalNode? { nodes[id] }

    /// `a1.s2.d1`-style path for display (ids joined from the root).
    func path(of id: String) -> String {
        var parts: [String] = []
        var seen = Set<String>()
        var current: String? = id
        while let c = current, seen.insert(c).inserted, let n = nodes[c] {
            parts.append(c)
            current = effectiveParent(n)
        }
        return parts.reversed().joined(separator: ".")
    }

    private func effectiveParent(_ node: JournalNode) -> String? {
        guard let parent = node.parent, parent != node.id, nodes[parent] != nil else { return nil }
        // Break cycles: walk up; if we come back to the node, treat it as a root.
        var seen: Set<String> = [node.id]
        var current: String? = parent
        while let c = current {
            if !seen.insert(c).inserted { return nil }
            current = nodes[c]?.parent
        }
        return parent
    }

    /// Reduces the nodes below `id` to their most urgent state, for collapsed rows.
    func openCount(below id: String) -> Int {
        children(of: id).reduce(0) { sum, child in
            sum + (child.status == .open && child.revoked == nil ? 1 : 0) + openCount(below: child.id)
        }
    }

    /// The step currently being worked on: the deepest running step.
    var currentID: String? {
        func deepest(_ parent: String?) -> String? {
            for node in children(of: parent).reversed() where node.revoked == nil {
                if let inner = deepest(node.id) { return inner }
                if node.kind == .step, node.status == .running { return node.id }
            }
            return nil
        }
        return deepest(nil)
    }

    // MARK: Applying lines

    static func validID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$"#, options: .regularExpression) != nil
    }

    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        // Titles end up in the UI and, on revoke, in the agent's prompt: no control characters.
        let scalars = text.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : Character($0) }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxTextLength))
    }

    /// Applies one decoded journal line; returns false when it was ignored.
    @discardableResult
    mutating func apply(_ line: [String: Any]) -> Bool {
        guard let type = line["t"] as? String else { return false }
        if type == "revoke" { return applyRevoke(line) }
        guard let kind = JournalKind(rawValue: type), let id = line["id"] as? String, Self.validID(id) else { return false }
        var node = nodes[id] ?? JournalNode(id: id, kind: kind, parent: nil, title: id,
                                            status: kind == .question ? .open : .planned, order: nextOrder)
        if nodes[id] == nil {
            guard nodes.count < Self.maxNodes else { return false }
            nextOrder += 1
        }
        node.kind = nodes[id]?.kind ?? kind
        if let p = line["parent"] as? String { node.parent = Self.validID(p) ? p : nil }
        if let title = Self.clean(line["title"] as? String) { node.title = title }
        if let raw = line["status"] as? String, let status = JournalStatus(rawValue: raw), Self.allowed(status, for: node.kind) {
            node.status = status
        }
        if let why = Self.clean(line["why"] as? String) { node.why = why }
        if let list = line["rejected"] as? [String] {
            node.rejected = list.prefix(Self.maxRejected).compactMap(Self.clean)
        }
        if let answer = Self.clean(line["answer"] as? String) {
            node.answer = answer
            if node.kind == .question { node.status = .answered }
        }
        nodes[id] = node
        return true
    }

    private static func allowed(_ status: JournalStatus, for kind: JournalKind) -> Bool {
        switch kind {
        case .step: [.planned, .running, .done, .blocked].contains(status)
        case .question: [.open, .answered].contains(status)
        case .decision: status == .done
        }
    }

    private mutating func applyRevoke(_ line: [String: Any]) -> Bool {
        guard let target = line["target"] as? String, var node = nodes[target] else { return false }
        let replacement = (line["replacedBy"] as? String).flatMap { Self.validID($0) && $0 != target ? $0 : nil }
        node.revoked = .init(reason: Self.clean(line["reason"] as? String) ?? "", replacedBy: replacement)
        nodes[target] = node
        return true
    }

    /// Instruction the app types into the agent's prompt when the user revokes a node.
    func revokePrompt(for id: String, reason: String) -> String {
        guard let node = nodes[id] else { return "" }
        let kindName = switch node.kind {
        case .step: "step"
        case .decision: "decision"
        case .question: "question"
        }
        var text = "I am revoking \(kindName) \(id) (\"\(node.title)\")."
        if let reason = Self.clean(reason) { text += " Reason: \(reason)." }
        text += " Undo or adjust the work that depended on it, then record the replacement with hearth-journal."
        return text
    }
}

/// Reads a journal file incrementally; one instance per session.
struct JournalReader {
    private(set) var journal = Journal()
    private var offset: UInt64 = 0
    static let maxChunk = 1 << 20

    /// Reads complete lines written since the last call. Returns true when the journal changed.
    mutating func poll(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Self.maxChunk), !data.isEmpty else { return false }
        guard let lastNewline = data.lastIndex(of: 10) else {
            // A single line without end that is larger than the chunk: skip it.
            if data.count >= Self.maxChunk { offset += UInt64(data.count) }
            return false
        }
        let complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)
        var changed = false
        for line in complete.split(separator: 10) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if journal.apply(obj) { changed = true }
        }
        return changed
    }

    mutating func reset() { self = JournalReader() }
}

/// The helper the agent calls inside the sandbox, and the instruction that tells it how.
enum JournalSupport {
    static let fileName = "journal.jsonl"
    static let enabledKey = "journal.enabled"

    /// Whether new sessions get `hearth-journal` and the instruction (default: on).
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func url(runDirectory: URL) -> URL { runDirectory.appendingPathComponent(fileName) }

    /// POSIX shell script; builds the JSON line with `printf`, escaping only what JSON requires.
    static let helperScript = """
    #!/bin/sh
    # hearth-journal step|decision|question <id> [--parent ID] [--title T] [--status S] [--why T] [--rejected T]... [--answer T]
    # Records progress for the Hearth session overview.
    file="${HEARTH_JOURNAL:?not inside a Hearth session}"
    type="$1"; id="$2"
    case "$type" in step|decision|question) ;; *) echo "usage: hearth-journal step|decision|question <id> [options]" >&2; exit 2;; esac
    [ -n "$id" ] || { echo "missing id" >&2; exit 2; }
    shift 2
    esc() { printf '%s' "$1" | /usr/bin/sed -e 's/\\\\/\\\\\\\\/g' -e 's/"/\\\\"/g' | /usr/bin/tr '\\n\\r\\t' '   '; }
    json="{\\"t\\":\\"$type\\",\\"id\\":\\"$(esc "$id")\\""
    rejected=""
    while [ $# -gt 1 ]; do
      case "$1" in
        --parent) json="$json,\\"parent\\":\\"$(esc "$2")\\"" ;;
        --title) json="$json,\\"title\\":\\"$(esc "$2")\\"" ;;
        --status) json="$json,\\"status\\":\\"$(esc "$2")\\"" ;;
        --why) json="$json,\\"why\\":\\"$(esc "$2")\\"" ;;
        --answer) json="$json,\\"answer\\":\\"$(esc "$2")\\"" ;;
        --rejected) rejected="$rejected${rejected:+,}\\"$(esc "$2")\\"" ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
      esac
      shift 2
    done
    [ -z "$rejected" ] || json="$json,\\"rejected\\":[$rejected]"
    printf '%s}\\n' "$json" >> "$file"
    """

    /// Installs the helper into the run folder and returns the folder to put on PATH.
    static func install(runDirectory: URL) throws -> URL {
        let fm = FileManager.default
        let bin = runDirectory.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("hearth-journal")
        try helperScript.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let journal = url(runDirectory: runDirectory)
        if !fm.fileExists(atPath: journal.path) { fm.createFile(atPath: journal.path, contents: nil) }
        return bin
    }

    /// Short instruction for the agent's system prompt.
    static let instruction = """
    Hearth shows the user a tree of your work so they do not have to read all your output. \
    Record it with the shell command `hearth-journal` (already on PATH): \
    `hearth-journal step <id> --parent <id> --title "…" --status planned|running|done|blocked` for each step, \
    `hearth-journal decision <id> --parent <step-id> --title "…" --why "…" --rejected "alternative"` for every real choice \
    between options, and `hearth-journal question <id> --parent <id> --title "…" [--answer "…"]` for open questions. \
    Use short unique ids (s1, s2, d1, q1). Repeat a call with the same id to update it. \
    Keep titles under 80 characters. If the user tells you they revoked an entry, undo the dependent work and record the replacement.
    """

    /// Agent arguments that hand the instruction over as system/developer prompt, where the CLI has one.
    /// Others get it on request from the Journal pane.
    static func arguments(kind: AgentKind) -> [String] {
        switch kind {
        case .claude:
            return ["--append-system-prompt", instruction]
        case .codex:
            // A JSON string is a valid TOML basic string.
            guard let data = try? JSONEncoder().encode(instruction), let quoted = String(data: data, encoding: .utf8) else { return [] }
            return ["-c", "developer_instructions=\(quoted)"]
        default:
            return []
        }
    }
}
