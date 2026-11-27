import Foundation
import CryptoKit

// Spec-driven development: a feature goes through requirements → design → tasks →
// implementation, and each document is approved before the next one is written.
// The documents live in the project (`.hearth/specs/<slug>/`, Kiro's `.kiro/specs/`
// is read as well), so any agent CLI can read and write them; Hearth only keeps
// the approvals (`spec.json`) and drives the agent with prompts.

/// The three documents of a spec, in workflow order.
enum SpecPhase: String, CaseIterable, Codable, Sendable, Identifiable {
    case requirements, design, tasks
    var id: String { rawValue }

    var fileName: String { rawValue + ".md" }

    var title: String {
        switch self {
        case .requirements: String(localized: "Requirements")
        case .design: String(localized: "Design")
        case .tasks: String(localized: "Tasks")
        }
    }

    var symbol: String {
        switch self {
        case .requirements: "list.bullet.rectangle"
        case .design: "square.stack.3d.up"
        case .tasks: "checklist"
        }
    }

    var previous: SpecPhase? {
        switch self {
        case .requirements: nil
        case .design: .requirements
        case .tasks: .design
        }
    }

    var next: SpecPhase? {
        switch self {
        case .requirements: .design
        case .design: .tasks
        case .tasks: nil
        }
    }
}

/// Where a document stands.
enum SpecDocStatus: Equatable, Sendable {
    /// Not written yet.
    case missing
    /// Written, not approved.
    case draft
    case approved
    /// Approved, then edited: needs another look.
    case changed
}

/// One checkbox line of `tasks.md`, e.g. `- [ ] 1.2 Add the parser` with its detail lines.
struct SpecTask: Identifiable, Hashable, Sendable {
    /// Number from the list ("1", "1.2") or, without one, the line number.
    let id: String
    let title: String
    let done: Bool
    /// Nesting level (0 = top level).
    let depth: Int
    /// 0-based line of the checkbox in tasks.md.
    let line: Int
    /// Bullet lines below the task that are not tasks themselves.
    var details: [String] = []
    /// Requirement numbers from `_Requirements: 1.1, 2.3_`.
    var requirements: [String] = []
}

enum SpecTasksParser {
    private static let checkbox = try! NSRegularExpression(pattern: #"^(\s*)[-*+]\s+\[( |x|X)\]\s+(.*)$"#)
    private static let number = try! NSRegularExpression(pattern: #"^(\d+(?:\.\d+)*)\.?\s+(.*)$"#)
    private static let refs = try! NSRegularExpression(pattern: #"^[_*]*Requirements?[_*]*\s*:\s*(.*?)[_*]*$"#, options: .caseInsensitive)

    static func parse(_ markdown: String) -> [SpecTask] {
        var tasks: [SpecTask] = []
        var inFence = false
        for (index, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            let ns = line as NSString
            if let m = checkbox.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let indent = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "\t", with: "  ").count
                let done = ns.substring(with: m.range(at: 2)) != " "
                var text = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
                var id = "L\(index + 1)"
                let tn = text as NSString
                if let n = number.firstMatch(in: text, range: NSRange(location: 0, length: tn.length)) {
                    id = tn.substring(with: n.range(at: 1))
                    text = tn.substring(with: n.range(at: 2))
                }
                tasks.append(SpecTask(id: id, title: strip(text), done: done, depth: indent / 2, line: index))
                continue
            }
            // Detail lines belong to the last task when indented below it.
            guard !tasks.isEmpty, line.hasPrefix(" ") || line.hasPrefix("\t") else { continue }
            var detail = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["- ", "* ", "+ "] where detail.hasPrefix(prefix) { detail.removeFirst(prefix.count) }
            guard !detail.isEmpty else { continue }
            let dn = detail as NSString
            if let r = refs.firstMatch(in: detail, range: NSRange(location: 0, length: dn.length)) {
                tasks[tasks.count - 1].requirements += dn.substring(with: r.range(at: 1))
                    .split(whereSeparator: { $0 == "," || $0 == ";" })
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " _*")) }
                    .filter { !$0.isEmpty }
            } else {
                tasks[tasks.count - 1].details.append(strip(detail))
            }
        }
        return tasks
    }

    /// The markdown with the checkbox on `line` set to `done` (unchanged if that line has none).
    static func setting(_ markdown: String, line: Int, done: Bool) -> String {
        var lines = markdown.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return markdown }
        let ns = lines[line] as NSString
        guard let m = checkbox.firstMatch(in: lines[line], range: NSRange(location: 0, length: ns.length)) else { return markdown }
        lines[line] = ns.replacingCharacters(in: m.range(at: 2), with: done ? "x" : " ")
        return lines.joined(separator: "\n")
    }

    /// Removes simple inline emphasis/code markers for display.
    private static func strip(_ s: String) -> String {
        var t = s
        for marker in ["**", "__", "`"] { t = t.replacingOccurrences(of: marker, with: "") }
        return t
    }
}

/// Hearth's own record of a spec: name, idea and which document versions were approved.
struct SpecRecord: Codable, Equatable, Sendable {
    var name: String
    var idea: String = ""
    var created = Date()
    /// Phase → SHA-256 of the document text at approval.
    var approved: [String: String] = [:]
}

/// A spec folder with its documents read from disk.
struct Spec: Identifiable, Sendable {
    let folder: URL
    /// Path relative to the project, e.g. `.hearth/specs/login`.
    let relativePath: String
    var record: SpecRecord
    var documents: [SpecPhase: String]

    var id: String { relativePath }
    var slug: String { folder.lastPathComponent }
    var name: String { record.name.isEmpty ? slug : record.name }

    func url(_ phase: SpecPhase) -> URL { folder.appendingPathComponent(phase.fileName) }
    func path(_ phase: SpecPhase) -> String { relativePath + "/" + phase.fileName }

    func status(_ phase: SpecPhase) -> SpecDocStatus {
        guard let text = documents[phase], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .missing }
        guard let hash = record.approved[phase.rawValue] else { return .draft }
        return hash == SpecLibrary.approvalHash(phase, text) ? .approved : .changed
    }

    var tasks: [SpecTask] { documents[.tasks].map(SpecTasksParser.parse) ?? [] }

    /// The phase that needs work next; nil once all three documents are approved
    /// (the spec is in implementation).
    var currentPhase: SpecPhase? { SpecPhase.allCases.first { status($0) != .approved } }

    /// Whether a document can be written: the one before it is approved.
    func canWrite(_ phase: SpecPhase) -> Bool { phase.previous.map { status($0) == .approved } ?? true }

    var isImplementing: Bool { currentPhase == nil }
    var isComplete: Bool {
        let t = tasks
        return isImplementing && !t.isEmpty && t.allSatisfy(\.done)
    }
}

/// Reading and writing specs and steering documents of a project.
enum SpecLibrary {
    static let specsDir = ".hearth/specs"
    static let kiroSpecsDir = ".kiro/specs"
    static let steeringDir = ".hearth/steering"
    static let recordFile = "spec.json"
    /// Steering documents: what the product is, how it is built, how the code is laid out.
    static let steeringFiles = ["product.md", "tech.md", "structure.md"]

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash recorded at approval. For tasks, ticked boxes don't count: progress is not a
    /// new version of the plan, so the agent ticking tasks keeps the approval.
    static func approvalHash(_ phase: SpecPhase, _ text: String) -> String {
        guard phase == .tasks else { return hash(text) }
        let lines = text.components(separatedBy: "\n").map { line -> String in
            guard let r = line.range(of: #"^\s*[-*+]\s+\[(x|X)\]"#, options: .regularExpression) else { return line }
            return line.replacingCharacters(in: r, with: String(line[r]).replacingOccurrences(of: "[x]", with: "[ ]")
                .replacingOccurrences(of: "[X]", with: "[ ]"))
        }
        return hash(lines.joined(separator: "\n"))
    }

    static func scan(root: String) -> [Spec] {
        let fm = FileManager.default
        var specs: [Spec] = []
        for dir in [specsDir, kiroSpecsDir] {
            let base = URL(fileURLWithPath: root).appendingPathComponent(dir)
            guard let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles]) else { continue }
            for folder in entries where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                var docs: [SpecPhase: String] = [:]
                for phase in SpecPhase.allCases {
                    if let text = try? String(contentsOf: folder.appendingPathComponent(phase.fileName), encoding: .utf8) {
                        docs[phase] = text
                    }
                }
                let record = (try? Data(contentsOf: folder.appendingPathComponent(recordFile)))
                    .flatMap { try? decoder.decode(SpecRecord.self, from: $0) }
                    ?? SpecRecord(name: title(from: docs[.requirements]) ?? folder.lastPathComponent)
                specs.append(Spec(folder: folder, relativePath: dir + "/" + folder.lastPathComponent, record: record, documents: docs))
            }
        }
        return specs.sorted { $0.record.created > $1.record.created || ($0.record.created == $1.record.created && $0.name < $1.name) }
    }

    /// Steering documents that exist, relative to the project.
    static func steering(root: String) -> [String] {
        let base = URL(fileURLWithPath: root).appendingPathComponent(steeringDir)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return files.filter { $0.hasSuffix(".md") }.sorted().map { steeringDir + "/" + $0 }
    }

    /// Folder name for a spec: lowercase ASCII words joined by dashes.
    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .replacingOccurrences(of: "ß", with: "ss")
        let words = folded.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let s = words.joined(separator: "-")
        return s.isEmpty ? "spec" : String(s.prefix(48))
    }

    /// Creates `.hearth/specs/<slug>/spec.json` (a free slug if the name is taken).
    static func create(name: String, idea: String, root: String) throws -> Spec {
        let base = URL(fileURLWithPath: root).appendingPathComponent(specsDir)
        let stem = slug(name)
        var slug = stem
        var n = 2
        while FileManager.default.fileExists(atPath: base.appendingPathComponent(slug).path) {
            slug = "\(stem)-\(n)"; n += 1
        }
        let folder = base.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = SpecRecord(name: name.trimmingCharacters(in: .whitespacesAndNewlines), idea: idea)
        try save(record, in: folder)
        return Spec(folder: folder, relativePath: specsDir + "/" + slug, record: record, documents: [:])
    }

    /// Records the current text of `phase` as approved.
    static func approve(_ phase: SpecPhase, of spec: Spec) throws -> Spec {
        guard let text = spec.documents[phase] else { return spec }
        var s = spec
        s.record.approved[phase.rawValue] = approvalHash(phase, text)
        try save(s.record, in: s.folder)
        return s
    }

    static func revokeApproval(_ phase: SpecPhase, of spec: Spec) throws -> Spec {
        var s = spec
        s.record.approved[phase.rawValue] = nil
        try save(s.record, in: s.folder)
        return s
    }

    /// Ticks or clears a task's checkbox in tasks.md.
    static func setTask(_ task: SpecTask, done: Bool, in spec: Spec) throws {
        let url = spec.url(.tasks)
        let text = try String(contentsOf: url, encoding: .utf8)
        let updated = SpecTasksParser.setting(text, line: task.line, done: done)
        guard updated != text else { return }
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func save(_ record: SpecRecord, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: folder.appendingPathComponent(recordFile), options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func title(from markdown: String?) -> String? {
        guard let line = markdown?.components(separatedBy: "\n").first(where: { $0.hasPrefix("# ") }) else { return nil }
        var t = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        for prefix in ["Requirements Document:", "Requirements:", "Requirements Document", "Anforderungen:"]
        where t.lowercased().hasPrefix(prefix.lowercased()) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return t.isEmpty ? nil : t
    }
}

/// Instructions Hearth types into the agent for each step. They name the files, the
/// format and the rule that the agent stops after its step so the user can review.
enum SpecPrompts {
    /// Language the documents are written in (the app's language).
    static var language: AppLanguage { AppLanguage.active }

    private static func context(_ spec: Spec, steering: [String]) -> String {
        var s = "Spec “\(spec.name)” lives in `\(spec.relativePath)/`."
        if language == .german {
            s += " Write the spec documents in German (keep the EARS keywords WHEN, IF, WHILE, THEN, SHALL in English)."
        }
        if !steering.isEmpty {
            s += " Follow the project's steering documents: " + steering.map { "`\($0)`" }.joined(separator: ", ") + "."
        }
        return s
    }

    static func requirements(_ spec: Spec, steering: [String]) -> String {
        """
        We work spec-driven. \(context(spec, steering: steering)) Write `\(spec.path(.requirements))` for this feature: \
        \(spec.record.idea.isEmpty ? spec.name : spec.record.idea.replacingOccurrences(of: "\n", with: " ")) — \
        Look at the existing code first. Structure: `# Requirements: \(spec.name)`, a short introduction, then \
        `### Requirement N` sections, each with a user story (“As a …, I want …, so that …”) and numbered acceptance \
        criteria in EARS notation (“WHEN … THEN the system SHALL …”, “IF … THEN …”, “WHILE …”). Cover edge cases \
        and errors, keep it implementation-free. List open questions at the end. Only write this file, do not write \
        design, tasks or code; then stop so I can review it.
        """
    }

    static func design(_ spec: Spec, steering: [String]) -> String {
        """
        \(context(spec, steering: steering)) The requirements in `\(spec.path(.requirements))` are approved. \
        Read them and the relevant code, then write `\(spec.path(.design))`: overview, architecture (with a \
        Mermaid diagram if it helps), components and interfaces, data models, error handling and testing strategy, \
        and how each requirement is met. Research what you need, but do not change code and do not write tasks; \
        then stop so I can review the design.
        """
    }

    static func tasks(_ spec: Spec, steering: [String]) -> String {
        """
        \(context(spec, steering: steering)) Requirements and design are approved. Write \
        `\(spec.path(.tasks))`: an implementation plan as a Markdown checklist of small, testable coding steps \
        in a sensible order, numbered `- [ ] 1. …` with sub-tasks `  - [ ] 1.1 …`. Under each task add short \
        bullets with what to do and a line `_Requirements: 1.1, 2.3_` naming the acceptance criteria it covers. \
        Every requirement must be covered; include writing tests. Only coding tasks, no deployment or manual \
        steps. Do not change code yet; then stop so I can review the plan.
        """
    }

    static func revise(_ phase: SpecPhase, of spec: Spec, feedback: String, steering: [String]) -> String {
        """
        \(context(spec, steering: steering)) Please revise `\(spec.path(phase))` with this feedback: \
        \(feedback.replacingOccurrences(of: "\n", with: " ")) — Keep the document's structure\
        \(phase == .tasks ? " and the checkbox format" : ""), and keep the other spec documents consistent \
        if the change affects them. Do not change code; then stop so I can review it again.
        """
    }

    static func run(_ task: SpecTask, of spec: Spec, steering: [String]) -> String {
        """
        \(context(spec, steering: steering)) Implement task \(task.id) “\(task.title)” from `\(spec.path(.tasks))`. \
        First read `\(spec.path(.requirements))`, `\(spec.path(.design))` and the task list. Implement only this \
        task (including its sub-tasks), meet the referenced requirements, add or update tests and run them. \
        When it works, tick the task (and its sub-tasks) in `\(spec.path(.tasks))` with `[x]`. Then stop and \
        summarise what you did; do not start the next task.
        """
    }

    static func runRemaining(of spec: Spec, steering: [String]) -> String {
        """
        \(context(spec, steering: steering)) Read `\(spec.path(.requirements))`, `\(spec.path(.design))` and \
        `\(spec.path(.tasks))`. Then work through the open tasks one after another in order: implement each, \
        add or update tests, run them, and tick the task with `[x]` before you start the next one. If a task is \
        blocked or a requirement is unclear, stop and ask me instead of guessing.
        """
    }

    static func verify(_ spec: Spec, steering: [String]) -> String {
        """
        \(context(spec, steering: steering)) All tasks in `\(spec.path(.tasks))` are ticked. Check the \
        implementation against every acceptance criterion in `\(spec.path(.requirements))`: run the tests, \
        list each criterion as met or not met with a short reason. Fix nothing yet; report the gaps.
        """
    }

    static var steering: String {
        """
        Create steering documents for this repository in `\(SpecLibrary.steeringDir)/`: `product.md` (purpose, \
        users, key features), `tech.md` (languages, frameworks, tools, build, test and lint commands, \
        constraints) and `structure.md` (folder layout, naming and code conventions, where things go). Base \
        them on the actual code and existing docs, keep each short and factual. Do not change code.
        """
    }
}
