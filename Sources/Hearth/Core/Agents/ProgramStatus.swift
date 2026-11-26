import Foundation

/// One OSC 7501 record a program reported in its terminal (Program Status Protocol, as used by
/// herdr): `printf '\e]7501;state=working\e\\'`. SwiftTerm parses the sequence; this is the
/// part Hearth needs, so the mapping stays testable without a terminal.
struct ReportedProgramStatus: Equatable, Sendable {
    enum State: String, Sendable { case idle, working, done, blocked, error }
    enum Kind: String, Sendable { case permission, question, auth }

    var state: State
    var kind: Kind?
    var progress: Int?
    var title: String?
    var message: String?
}

/// What the inbox shows for a set of OSC 7501 records.
struct ProgramStatusSummary: Equatable, Sendable {
    var status: AgentStatus
    var detail: String?
    var progress: Int?

    /// Records come oldest first. Something that needs the user wins over an error, an error over
    /// work in progress; otherwise the newest record decides. No records: the program cleared its status.
    static func summarize(_ records: [ReportedProgramStatus]) -> ProgramStatusSummary? {
        guard let newest = records.last else { return nil }
        if let blocked = records.last(where: { $0.state == .blocked }) {
            return Self(status: .needsInput, detail: text(blocked) ?? blockedText(blocked.kind), progress: blocked.progress)
        }
        if let error = records.last(where: { $0.state == .error }) {
            return Self(status: .blocked, detail: text(error), progress: nil)
        }
        if let working = records.last(where: { $0.state == .working }) {
            return Self(status: .running, detail: nil, progress: working.progress)
        }
        switch newest.state {
        case .done: return Self(status: .done, detail: text(newest), progress: nil)
        default: return Self(status: .idle, detail: nil, progress: nil)
        }
    }

    private static func blockedText(_ kind: ReportedProgramStatus.Kind?) -> String {
        switch kind {
        case .permission: String(localized: "Waiting for approval.")
        case .question: String(localized: "Has a question for you.")
        case .auth: String(localized: "Needs you to sign in.")
        case nil: String(localized: "The agent needs your attention.")
        }
    }

    private static func text(_ record: ReportedProgramStatus) -> String? {
        clean(record.message) ?? clean(record.title)
    }

    /// The text comes from the sandboxed program: drop invisible formatting and direction
    /// overrides (Unicode category Cf) and control characters before it appears outside the terminal.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars.filter {
            $0.properties.generalCategory != .format && $0.properties.generalCategory != .control
        }
        let result = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : String(result.prefix(300))
    }
}

/// How long the current turn has been running, how long the current state has lasted
/// and how long the last turn took – for the timer in the inbox and on the board.
struct TurnClock: Equatable, Sendable {
    var statusSince: Date
    var turnStarted: Date?
    var lastTurn: TimeInterval?

    init(now: Date = Date()) { statusSince = now }

    /// A turn starts when the agent starts working and lasts through questions to the user
    /// (approving a tool is part of the turn); it ends when the agent is done, idle, ended or failed.
    mutating func transition(from old: AgentStatus, to new: AgentStatus, at now: Date) {
        guard old != new else { return }
        statusSince = now
        switch new {
        case .running:
            if turnStarted == nil { turnStarted = now }
        case .needsInput:
            break
        case .done, .idle, .inactive, .blocked:
            if let started = turnStarted { lastTurn = now.timeIntervalSince(started) }
            turnStarted = nil
        }
    }

    /// "3:07" or "1:02:03".
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
