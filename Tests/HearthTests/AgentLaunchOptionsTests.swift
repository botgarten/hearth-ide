import Foundation
import Testing
@testable import Hearth

/// Model, effort and restarts: the levers on an agent session's token use.
struct AgentLaunchOptionsTests {
    @Test func claudeGetsModelAndEffortBeforeResume() {
        let args = AgentKind.claude.arguments(resume: "abc", options: .init(model: "sonnet", effort: "low"))
        #expect(args == ["--model", "sonnet", "--effort", "low", "--resume", "abc"])
        #expect(AgentKind.claude.arguments(resume: nil, options: .none).isEmpty)
    }

    @Test func codexGetsReasoningEffortOnly() {
        let args = AgentKind.codex.arguments(resume: nil, options: .init(model: "sonnet", effort: "high"))
        #expect(args == ["-c", "model_reasoning_effort=\"high\""])
        #expect(AgentKind.gemini.arguments(resume: nil, options: .init(model: "opus", effort: "low")).isEmpty)
    }

    @Test func unknownValuesAreDropped() {
        // Options are read back from Hearth's session list: nothing outside the offered choices passes.
        let args = AgentKind.claude.arguments(options: .init(model: "--dangerously-skip-permissions", effort: "extreme"))
        #expect(args.isEmpty)
    }

    @Test func busySessionsRestartWhenTheirTurnEnds() {
        #expect(!AgentHost.restartsNow(.running))
        #expect(!AgentHost.restartsNow(.needsInput))
        #expect(AgentHost.restartsNow(.idle) && AgentHost.restartsNow(.done) && AgentHost.restartsNow(.blocked))
    }
}
