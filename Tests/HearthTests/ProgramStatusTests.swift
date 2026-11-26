import Foundation
import Testing
@testable import Hearth

/// OSC 7501 (Program Status Protocol) records → inbox status, and the turn timer.
struct ProgramStatusTests {
    typealias R = ReportedProgramStatus

    @Test func blockedWinsOverErrorAndWork() {
        let s = ProgramStatusSummary.summarize([
            R(state: .working, progress: 40),
            R(state: .error, message: "build failed"),
            R(state: .blocked, kind: .permission),
            R(state: .done),
        ])
        #expect(s?.status == .needsInput)
        #expect(s?.detail == String(localized: "Waiting for approval."))
    }

    @Test func errorThenWorkThenNewest() {
        #expect(ProgramStatusSummary.summarize([R(state: .working), R(state: .error, message: "boom")])
                == .init(status: .blocked, detail: "boom", progress: nil))
        #expect(ProgramStatusSummary.summarize([R(state: .done), R(state: .working, progress: 70)])
                == .init(status: .running, detail: nil, progress: 70))
        #expect(ProgramStatusSummary.summarize([R(state: .working), R(state: .done, title: "Tests green")]).map(\.status) == .running)
        #expect(ProgramStatusSummary.summarize([R(state: .done, title: "Tests green")])
                == .init(status: .done, detail: "Tests green", progress: nil))
        #expect(ProgramStatusSummary.summarize([R(state: .idle)])?.status == .idle)
        #expect(ProgramStatusSummary.summarize([]) == nil)
    }

    @Test func messageIsCleanedOfInvisibleFormatting() {
        // Right-to-left override and zero-width space must not reach the inbox.
        let s = ProgramStatusSummary.summarize([R(state: .blocked, kind: .question, message: "Deploy\u{202E}txt.exe\u{200B}?  ")])
        #expect(s?.detail == "Deploytxt.exe?")
        #expect(ProgramStatusSummary.clean("\u{200B} ") == nil)
        #expect(ProgramStatusSummary.clean(String(repeating: "a", count: 500))?.count == 300)
    }

    @Test func turnLastsThroughQuestionsAndEndsWhenDone() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var clock = TurnClock(now: t0)
        clock.transition(from: .idle, to: .running, at: t0.addingTimeInterval(10))
        clock.transition(from: .running, to: .needsInput, at: t0.addingTimeInterval(40))
        #expect(clock.turnStarted == t0.addingTimeInterval(10))
        #expect(clock.statusSince == t0.addingTimeInterval(40))
        clock.transition(from: .needsInput, to: .running, at: t0.addingTimeInterval(60))
        #expect(clock.turnStarted == t0.addingTimeInterval(10))
        clock.transition(from: .running, to: .done, at: t0.addingTimeInterval(130))
        #expect(clock.turnStarted == nil)
        #expect(clock.lastTurn == 120)
        // Seeing the result keeps the last turn's duration.
        clock.transition(from: .done, to: .idle, at: t0.addingTimeInterval(200))
        #expect(clock.lastTurn == 120)
    }

    @Test func formatsDurations() {
        #expect(TurnClock.format(7) == "0:07")
        #expect(TurnClock.format(187) == "3:07")
        #expect(TurnClock.format(3723) == "1:02:03")
        #expect(TurnClock.format(-5) == "0:00")
    }
}
