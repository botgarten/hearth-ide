import Foundation
import Testing
@testable import Hearth

struct JournalTests {
    private func journal(_ lines: [String]) -> Journal {
        var j = Journal()
        for line in lines {
            if let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] { j.apply(obj) }
        }
        return j
    }

    @Test func buildsTreeAndUpdatesInPlace() {
        let j = journal([
            #"{"t":"step","id":"s1","title":"Export","status":"running"}"#,
            #"{"t":"step","id":"s2","parent":"s1","title":"Model","status":"planned"}"#,
            #"{"t":"decision","id":"d1","parent":"s2","title":"Streaming","why":"big data","rejected":["in memory"]}"#,
            #"{"t":"step","id":"s2","status":"running"}"#,
        ])
        #expect(j.roots.map(\.id) == ["s1"])
        #expect(j.children(of: "s1").map(\.id) == ["s2"])
        #expect(j.node("s2")?.status == .running)
        #expect(j.node("s2")?.title == "Model")
        #expect(j.node("d1")?.rejected == ["in memory"])
        #expect(j.path(of: "d1") == "s1.s2.d1")
        #expect(j.currentID == "s2")
    }

    @Test func questionBecomesAnsweredWithAnswer() {
        let j = journal([#"{"t":"question","id":"q1","title":"Encoding?"}"#,
                         #"{"t":"question","id":"q1","answer":"Latin-1"}"#])
        #expect(j.node("q1")?.status == .answered)
        #expect(j.node("q1")?.answer == "Latin-1")
    }

    @Test func revokeKeepsNodeAndMarksIt() {
        var j = journal([#"{"t":"step","id":"s3","title":"Unit tests"}"#])
        j.apply(["t": "revoke", "target": "s3", "reason": "want integration", "replacedBy": "s4"])
        #expect(j.node("s3")?.revoked?.reason == "want integration")
        #expect(j.node("s3")?.revoked?.replacedBy == "s4")
        #expect(!j.revokePrompt(for: "s3", reason: "x\u{1b}[31m\nrm").contains("\u{1b}"))
        #expect(!j.revokePrompt(for: "s3", reason: "a\nb").contains("\n"))
    }

    @Test func rejectsHostileInput() {
        var j = Journal()
        let results = [j.apply(["t": "step", "id": "../x"]), j.apply(["t": "step", "id": ""]),
                       j.apply(["t": "bogus", "id": "a"]), j.apply(["t": "revoke", "target": "missing"])]
        #expect(results == [false, false, false, false])
        j.apply(["t": "decision", "id": "d", "title": String(repeating: "a", count: 5000), "status": "running"])
        #expect(j.node("d")!.title.count == Journal.maxTextLength)
        #expect(j.node("d")!.status == .planned)   // decisions have no running state
    }

    @Test func cyclesAndUnknownParentsStayVisible() {
        let j = journal([#"{"t":"step","id":"a","parent":"b"}"#,
                         #"{"t":"step","id":"b","parent":"a"}"#,
                         #"{"t":"step","id":"c","parent":"nope"}"#,
                         #"{"t":"step","id":"d","parent":"d"}"#])
        #expect(Set(j.roots.map(\.id)).isSuperset(of: ["c", "d"]))
        #expect(!j.roots.isEmpty)
        _ = j.path(of: "a")   // terminates
    }

    @Test func readerIsIncrementalAndSkipsGarbage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"t\":\"step\",\"id\":\"s1\",\"title\":\"A\"}\nnot json\n{\"t\":\"step\",\"id\":\"s2\"".utf8).write(to: url)
        var reader = JournalReader()
        let r891168 = reader.poll(url: url)
        #expect(r891168)
        #expect(reader.journal.node("s1") != nil)
        #expect(reader.journal.node("s2") == nil)   // line not finished yet
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(",\"title\":\"B\"}\n".utf8))
        try handle.close()
        let r930331 = reader.poll(url: url)
        #expect(r930331)
        #expect(reader.journal.node("s2")?.title == "B")
        let r640738 = reader.poll(url: url)
        #expect(!r640738)
    }

    @Test func helperScriptWritesValidJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("journal-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = try JournalSupport.install(runDirectory: dir)
        let file = JournalSupport.url(runDirectory: dir)
        let p = Process()
        p.executableURL = bin.appendingPathComponent("hearth-journal")
        p.arguments = ["decision", "d1", "--parent", "s1", "--title", "Quote \" and \\ back\nslash",
                       "--why", "weil", "--rejected", "a \"b\"", "--rejected", "c"]
        p.environment = ["HEARTH_JOURNAL": file.path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        var reader = JournalReader()
        let r451354 = reader.poll(url: file)
        #expect(r451354)
        let node = try #require(reader.journal.node("d1"))
        #expect(node.parent == "s1")
        #expect(node.title.hasPrefix("Quote \" and \\ back"))
        #expect(node.rejected == ["a \"b\"", "c"])
    }

    @Test func instructionIsDeliveredToClaudeAndCodex() {
        #expect(JournalSupport.arguments(kind: .claude).first == "--append-system-prompt")
        let codex = JournalSupport.arguments(kind: .codex)
        #expect(codex.first == "-c" && codex[1].hasPrefix("developer_instructions=\""))
        #expect(JournalSupport.arguments(kind: .gemini).isEmpty)
    }
}
