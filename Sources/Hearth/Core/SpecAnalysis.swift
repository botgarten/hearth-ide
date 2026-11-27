import Foundation
import Observation

// Reads the spec documents the way a reviewer would: which requirements and acceptance
// criteria exist, whether the criteria are testable (EARS), which open questions are left,
// whether the design covers the usual ground, and – the part that ties it together –
// which criterion is covered by which task and how far its implementation is.

/// One acceptance criterion, e.g. `2.3 WHEN … THEN the system SHALL …`.
struct SpecCriterion: Identifiable, Hashable, Sendable {
    /// "<requirement>.<number>", e.g. "2.3".
    let id: String
    let text: String
    /// Testable form: contains SHALL (EARS keywords stay English in every language).
    var isEARS: Bool { text.range(of: #"\bSHALL\b"#, options: .regularExpression) != nil }
}

struct SpecRequirement: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var hasStory: Bool
    var criteria: [SpecCriterion]
}

struct SpecRequirementsDoc: Sendable {
    var requirements: [SpecRequirement] = []
    var openQuestions: [String] = []
    var criteria: [SpecCriterion] { requirements.flatMap(\.criteria) }
}

/// How far a criterion has come.
enum SpecTraceState: Sendable, Equatable {
    case uncovered, planned, partial, done
}

struct SpecTrace: Identifiable, Sendable {
    let criterion: SpecCriterion
    let tasks: [SpecTask]
    var id: String { criterion.id }

    var state: SpecTraceState {
        if tasks.isEmpty { return .uncovered }
        let done = tasks.filter(\.done).count
        return done == tasks.count ? .done : done > 0 ? .partial : .planned
    }
}

/// Something the quality check noticed.
struct SpecFinding: Identifiable, Sendable, Equatable {
    enum Severity: Sendable, Equatable { case issue, hint }
    let id: String
    let severity: Severity
    let phase: SpecPhase
    let message: String
    /// What the agent is asked to do; nil when only the user can act.
    var fix: String?
    /// Special action instead of a fix prompt.
    var answerQuestions = false
}

enum SpecAnalysis {
    private static let requirementHeading = try! NSRegularExpression(
        pattern: #"^#{2,4}\s+(?:Requirement|Anforderung|Requisito|Exigence)\s+(\d+)\s*[:.–-]?\s*(.*)$"#, options: .caseInsensitive)
    private static let numberedHeading = try! NSRegularExpression(pattern: #"^#{3,4}\s+(\d+)[.)]\s+(.+)$"#)
    private static let numberedItem = try! NSRegularExpression(pattern: #"^\s*(\d+)[.)]\s+(.+)$"#)
    private static let anyHeading = try! NSRegularExpression(pattern: #"^#{1,6}\s+(.*)$"#)

    private static func match(_ re: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    static func requirements(_ markdown: String) -> SpecRequirementsDoc {
        var doc = SpecRequirementsDoc()
        var current: SpecRequirement?
        var inQuestions = false
        var inFence = false
        func close() { if let c = current { doc.requirements.append(c) }; current = nil }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            if let m = match(requirementHeading, line) ?? match(numberedHeading, line) {
                close()
                inQuestions = false
                let title = m[1].trimmingCharacters(in: .whitespaces)
                current = SpecRequirement(id: m[0], title: title, hasStory: false, criteria: [])
                continue
            }
            if let h = match(anyHeading, line) {
                let title = h[0].lowercased()
                if title.contains("open question") || title.contains("offene frage") {
                    close()
                    inQuestions = true
                    continue
                }
                // Sub-headings inside a requirement ("Acceptance Criteria") keep it open.
                if line.hasPrefix("## ") || line.hasPrefix("# ") { close(); inQuestions = false }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inQuestions {
                var q = trimmed
                if let m = match(numberedItem, q) { q = m[1] }
                for prefix in ["- ", "* ", "+ "] where q.hasPrefix(prefix) { q.removeFirst(prefix.count) }
                let plain = q.trimmingCharacters(in: CharacterSet(charactersIn: " _*"))
                let none = ["none", "keine", "n/a", "-", "—", "none.", "keine."]
                if !plain.isEmpty, !none.contains(plain.lowercased()), !plain.lowercased().hasPrefix("none ") , !plain.lowercased().hasPrefix("keine ") {
                    doc.openQuestions.append(plain)
                }
                continue
            }
            guard current != nil else { continue }
            let lower = trimmed.lowercased()
            if lower.contains("as a ") || lower.contains("as an ") || lower.contains("als ") && (lower.contains("möchte") || lower.contains("will")) {
                current?.hasStory = true
            }
            if !line.hasPrefix(" "), !line.hasPrefix("\t"), let m = match(numberedItem, line), let req = current {
                let text = m[1].replacingOccurrences(of: "**", with: "")
                current?.criteria.append(SpecCriterion(id: "\(req.id).\(m[0])", text: text))
            }
        }
        close()
        return doc
    }

    /// Requirement or criterion ids a task names ("1" covers all criteria of requirement 1).
    static func trace(_ doc: SpecRequirementsDoc, tasks: [SpecTask]) -> [SpecTrace] {
        // Parent tasks inherit nothing; each task stands for its own references.
        doc.criteria.map { criterion in
            let requirement = String(criterion.id.split(separator: ".").first ?? "")
            let covering = tasks.filter { t in t.requirements.contains { $0 == criterion.id || $0 == requirement } }
            return SpecTrace(criterion: criterion, tasks: covering)
        }
    }

    /// Topics a design is expected to cover, with words that count as covering them.
    static let designTopics: [(String, [String])] = [
        (String(localized: "Overview"), ["overview", "übersicht", "summary", "zusammenfassung"]),
        (String(localized: "Architecture"), ["architecture", "architektur"]),
        (String(localized: "Components and interfaces"), ["component", "komponente", "interface", "schnittstelle"]),
        (String(localized: "Data models"), ["data", "daten", "model", "modell"]),
        (String(localized: "Error handling"), ["error", "fehler"]),
        (String(localized: "Testing strategy"), ["test"]),
    ]

    static func missingDesignTopics(_ markdown: String) -> [String] {
        let headings = markdown.components(separatedBy: "\n").filter { $0.hasPrefix("#") }.map { $0.lowercased() }
        return designTopics.filter { _, words in !headings.contains { h in words.contains { h.contains($0) } } }.map(\.0)
    }

    static func findings(_ spec: Spec) -> [SpecFinding] {
        var out: [SpecFinding] = []
        let doc = spec.documents[.requirements].map(requirements) ?? SpecRequirementsDoc()
        if let text = spec.documents[.requirements], !text.isEmpty {
            if doc.requirements.isEmpty {
                out.append(SpecFinding(id: "req-none", severity: .issue, phase: .requirements,
                                       message: String(localized: "No requirements found (### Requirement N)."),
                                       fix: "There are no `### Requirement N` sections; restructure the document accordingly."))
            }
            let missingCriteria = doc.requirements.filter { $0.criteria.isEmpty }.map(\.id)
            if !missingCriteria.isEmpty {
                out.append(SpecFinding(id: "req-nocriteria", severity: .issue, phase: .requirements,
                                       message: String(localized: "Requirements without acceptance criteria: \(missingCriteria.joined(separator: ", "))"),
                                       fix: "Requirements \(missingCriteria.joined(separator: ", ")) have no numbered acceptance criteria; add testable EARS criteria."))
            }
            let notEARS = doc.criteria.filter { !$0.isEARS }.map(\.id)
            if !notEARS.isEmpty {
                out.append(SpecFinding(id: "req-ears", severity: .issue, phase: .requirements,
                                       message: String(localized: "Not testable (no EARS “SHALL”): \(notEARS.prefix(8).joined(separator: ", "))\(notEARS.count > 8 ? " …" : "")"),
                                       fix: "Acceptance criteria \(notEARS.joined(separator: ", ")) are not in EARS form; rewrite them as WHEN/IF/WHILE … THEN the system SHALL …"))
            }
            if spec.record.kind == .feature {
                let noStory = doc.requirements.filter { !$0.hasStory }.map(\.id)
                if !noStory.isEmpty, !doc.requirements.isEmpty {
                    out.append(SpecFinding(id: "req-story", severity: .hint, phase: .requirements,
                                           message: String(localized: "Without a user story: \(noStory.joined(separator: ", "))"),
                                           fix: "Requirements \(noStory.joined(separator: ", ")) lack a user story (As a …, I want …, so that …); add one."))
                }
            }
            if !doc.openQuestions.isEmpty {
                out.append(SpecFinding(id: "req-questions", severity: .issue, phase: .requirements,
                                       message: String(localized: "\(doc.openQuestions.count) open questions: answer them before you approve."),
                                       answerQuestions: true))
            }
        }
        if let text = spec.documents[.design], !text.isEmpty {
            let missing = missingDesignTopics(text)
            if !missing.isEmpty {
                out.append(SpecFinding(id: "design-topics", severity: .hint, phase: .design,
                                       message: String(localized: "Not covered: \(missing.joined(separator: ", "))"),
                                       fix: "The design has no section on: \(missing.joined(separator: ", ")). Add them where they apply."))
            }
            let mentioned = doc.requirements.filter { r in
                text.range(of: #"(?i)(requirement|anforderung|req\.?|r)\s*\#(r.id)\b"#, options: .regularExpression) != nil
                    || r.criteria.contains { text.contains($0.id) }
            }
            if doc.requirements.count > 1, mentioned.count < doc.requirements.count {
                let left = doc.requirements.filter { r in !mentioned.contains(r) }.map(\.id)
                out.append(SpecFinding(id: "design-trace", severity: .hint, phase: .design,
                                       message: String(localized: "Requirements the design doesn’t mention: \(left.joined(separator: ", "))"),
                                       fix: "The design doesn't say how requirements \(left.joined(separator: ", ")) are met; add that."))
            }
        }
        if spec.documents[.tasks].map({ !$0.isEmpty }) == true {
            let tasks = spec.tasks
            if tasks.isEmpty {
                out.append(SpecFinding(id: "tasks-none", severity: .issue, phase: .tasks,
                                       message: String(localized: "No checkbox tasks found (- [ ] 1. …)."),
                                       fix: "The task list has no `- [ ] 1. …` checkbox items; rewrite it in that format."))
            }
            let traces = trace(doc, tasks: tasks)
            let uncovered = traces.filter { $0.state == .uncovered }.map(\.id)
            if !uncovered.isEmpty {
                out.append(SpecFinding(id: "tasks-uncovered", severity: .issue, phase: .tasks,
                                       message: String(localized: "Criteria no task covers: \(uncovered.prefix(8).joined(separator: ", "))\(uncovered.count > 8 ? " …" : "")"),
                                       fix: "No task covers acceptance criteria \(uncovered.joined(separator: ", ")); add tasks (with _Requirements:_ references) for them."))
            }
            let known = Set(doc.criteria.map(\.id) + doc.requirements.map(\.id))
            let unknown = Set(tasks.flatMap(\.requirements)).subtracting(known).sorted()
            if !unknown.isEmpty, !doc.requirements.isEmpty {
                out.append(SpecFinding(id: "tasks-unknown", severity: .issue, phase: .tasks,
                                       message: String(localized: "Tasks name criteria that don’t exist: \(unknown.joined(separator: ", "))"),
                                       fix: "Tasks reference \(unknown.joined(separator: ", ")), which are not in requirements.md; correct the references."))
            }
            let unlinked = tasks.filter { t in t.requirements.isEmpty && !tasks.contains { $0.depth > t.depth && $0.id.hasPrefix(t.id + ".") } }.map(\.id)
            if !unlinked.isEmpty, !doc.requirements.isEmpty {
                out.append(SpecFinding(id: "tasks-unlinked", severity: .hint, phase: .tasks,
                                       message: String(localized: "Tasks without a requirement: \(unlinked.prefix(8).joined(separator: ", "))"),
                                       fix: "Tasks \(unlinked.joined(separator: ", ")) have no `_Requirements:_` line; add the criteria they serve."))
            }
        }
        return out
    }

    /// What to check before approving, per phase (the guided mode's checklist).
    static func checklist(_ phase: SpecPhase, kind: SpecKind) -> [String] {
        switch phase {
        case .requirements:
            switch kind {
            case .feature: [String(localized: "The stories describe what I actually want"),
                            String(localized: "Edge cases and errors are covered"),
                            String(localized: "Every criterion can be tested"),
                            String(localized: "Nothing is missing and nothing is too much")]
            case .bugfix: [String(localized: "Current and expected behaviour are right"),
                           String(localized: "The steps reproduce the bug"),
                           String(localized: "A regression criterion protects the fix")]
            case .refactor: [String(localized: "The goals are the right ones"),
                             String(localized: "What must not change is stated"),
                             String(localized: "It says how unchanged behaviour is verified")]
            }
        case .design:
            [String(localized: "The approach fits the existing architecture"),
             String(localized: "Interfaces and data models make sense"),
             String(localized: "Errors and edge cases are handled"),
             String(localized: "The testing strategy is enough")]
        case .tasks:
            [String(localized: "Steps are small and in a sensible order"),
             String(localized: "Tests are part of the plan"),
             String(localized: "Nothing outside the spec sneaks in")]
        }
    }
}

/// What the agent is currently doing for a spec, so the guided view can say
/// “writing the design…” and notice when it is done. Lives as long as the app.
@MainActor
@Observable
final class SpecActivity {
    struct Entry: Equatable {
        let runID: String
        let label: String
        let phase: SpecPhase?
        let started: Date
        /// Document text when the request went out, to notice the new version.
        let before: String?
        /// The agent was asked to interview the user first: a finished turn means it waits for answers.
        let interview: Bool
    }

    private(set) var entries: [String: Entry] = [:]

    func started(_ specID: String, runID: String, label: String, phase: SpecPhase?, before: String?, interview: Bool = false) {
        entries[specID] = Entry(runID: runID, label: label, phase: phase, started: Date(), before: before, interview: interview)
    }

    func clear(_ specID: String) { entries[specID] = nil }
}
