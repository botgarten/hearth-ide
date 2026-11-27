import Foundation
import Testing
@testable import Hearth

/// Spec-driven development: documents in `.hearth/specs/<slug>/`, approvals in spec.json.
struct SpecWorkflowTests {
    static let tasksMarkdown = """
    # Implementation plan

    - [x] 1. Set up the parser
      - Read `tasks.md` line by line
      - _Requirements: 1.1, 1.2_
    - [ ] 2. Show the tasks
      - [X] 2.1 List view
      - [ ] 2.2 **Run** buttons
        - _Requirements: 2.1_
    - [ ] Write the docs

    ```
    - [ ] 9. not a task (code block)
    ```
    """

    private func tempRoot() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    @Test func parsesNumberedNestedTasksWithDetailsAndRequirements() {
        let tasks = SpecTasksParser.parse(Self.tasksMarkdown)
        #expect(tasks.map(\.id) == ["1", "2", "2.1", "2.2", "L10"])
        #expect(tasks.map(\.done) == [true, false, true, false, false])
        #expect(tasks.map(\.depth) == [0, 0, 1, 1, 0])
        #expect(tasks[0].title == "Set up the parser")
        #expect(tasks[0].details == ["Read tasks.md line by line"])
        #expect(tasks[0].requirements == ["1.1", "1.2"])
        #expect(tasks[3].title == "Run buttons")
        #expect(tasks[3].requirements == ["2.1"])
        #expect(tasks[4].title == "Write the docs")
    }

    @Test func togglingRewritesOnlyThatCheckbox() {
        let tasks = SpecTasksParser.parse(Self.tasksMarkdown)
        let updated = SpecTasksParser.setting(Self.tasksMarkdown, line: tasks[1].line, done: true)
        #expect(SpecTasksParser.parse(updated).map(\.done) == [true, true, true, false, false])
        #expect(updated.components(separatedBy: "\n").count == Self.tasksMarkdown.components(separatedBy: "\n").count)
        // A line without a checkbox stays as it is.
        #expect(SpecTasksParser.setting(Self.tasksMarkdown, line: 0, done: true) == Self.tasksMarkdown)
    }

    @Test func slugsAreFolderSafe() {
        #expect(SpecLibrary.slug("Passwort zurücksetzen!") == "passwort-zurucksetzen")
        #expect(SpecLibrary.slug("Größe & Maß") == "grosse-mass")
        #expect(SpecLibrary.slug("  ") == "spec")
    }

    @Test func phasesUnlockOneAfterAnotherAndEditsNeedAnotherApproval() throws {
        let root = try tempRoot()
        var spec = try SpecLibrary.create(name: "Password reset", idea: "Users reset via email", root: root)
        #expect(spec.relativePath == ".hearth/specs/password-reset")
        #expect(spec.currentPhase == .requirements)
        #expect(spec.canWrite(.requirements) && !spec.canWrite(.design))

        try "# Requirements: Password reset\n".write(to: spec.url(.requirements), atomically: true, encoding: .utf8)
        spec = try #require(SpecLibrary.scan(root: root).first)
        #expect(spec.name == "Password reset" && spec.record.idea == "Users reset via email")
        #expect(spec.status(.requirements) == .draft)

        spec = try SpecLibrary.approve(.requirements, of: spec)
        spec = try #require(SpecLibrary.scan(root: root).first)
        #expect(spec.status(.requirements) == .approved)
        #expect(spec.currentPhase == .design && spec.canWrite(.design))

        try "# Requirements: Password reset\nmore\n".write(to: spec.url(.requirements), atomically: true, encoding: .utf8)
        spec = try #require(SpecLibrary.scan(root: root).first)
        #expect(spec.status(.requirements) == .changed)
        #expect(spec.currentPhase == .requirements)

        spec = try SpecLibrary.revokeApproval(.requirements, of: spec)
        #expect(spec.status(.requirements) == .draft)
    }

    @Test func tickingTasksKeepsTheApprovalAndCompletesTheSpec() throws {
        let root = try tempRoot()
        var spec = try SpecLibrary.create(name: "Board", idea: "", root: root)
        for phase in SpecPhase.allCases {
            let text = phase == .tasks ? "- [ ] 1. Build it\n- [ ] 2. Test it\n" : "# \(phase.title)\n"
            try text.write(to: spec.url(phase), atomically: true, encoding: .utf8)
            spec = try #require(SpecLibrary.scan(root: root).first)
            spec = try SpecLibrary.approve(phase, of: spec)
        }
        spec = try #require(SpecLibrary.scan(root: root).first)
        #expect(spec.isImplementing && !spec.isComplete)

        for task in spec.tasks { try SpecLibrary.setTask(task, done: true, in: spec) }
        spec = try #require(SpecLibrary.scan(root: root).first)
        #expect(spec.status(.tasks) == .approved)
        #expect(spec.isComplete)

        // A new task is a new plan.
        try (spec.documents[.tasks]! + "- [ ] 3. Ship it\n").write(to: spec.url(.tasks), atomically: true, encoding: .utf8)
        spec = try #require(SpecLibrary.scan(root: root).first)
        #expect(spec.status(.tasks) == .changed && !spec.isImplementing)
    }

    @Test func takenNamesGetAFreeFolderAndKiroSpecsAreRead() throws {
        let root = try tempRoot()
        _ = try SpecLibrary.create(name: "Login", idea: "", root: root)
        let second = try SpecLibrary.create(name: "Login", idea: "", root: root)
        #expect(second.slug == "login-2")

        let kiro = URL(fileURLWithPath: root).appendingPathComponent(".kiro/specs/export")
        try FileManager.default.createDirectory(at: kiro, withIntermediateDirectories: true)
        try "# Requirements Document: CSV export\n".write(to: kiro.appendingPathComponent("requirements.md"), atomically: true, encoding: .utf8)
        let specs = SpecLibrary.scan(root: root)
        let imported = try #require(specs.first { $0.relativePath == ".kiro/specs/export" })
        #expect(imported.name == "CSV export")
        #expect(imported.status(.requirements) == .draft)
    }

    @Test func promptsNameTheFilesAndStopAfterTheirStep() throws {
        let root = try tempRoot()
        let spec = try SpecLibrary.create(name: "Search", idea: "Find files fast", root: root)
        let steering = [".hearth/steering/tech.md"]
        let req = SpecPrompts.requirements(spec, steering: steering)
        #expect(req.contains(".hearth/specs/search/requirements.md") && req.contains("EARS") && req.contains("Find files fast"))
        #expect(req.contains(".hearth/steering/tech.md") && req.contains("stop"))
        let task = SpecTask(id: "2.1", title: "List view", done: false, depth: 1, line: 3)
        let run = SpecPrompts.run(task, of: spec, steering: [])
        #expect(run.contains("task 2.1") && run.contains("[x]") && run.contains("do not start the next task"))
    }

    @MainActor
    @Test func specLayoutShowsSpecsNextToTheChat() {
        let layout = LayoutStore()
        layout.apply(.specs)
        #expect(layout.paneTree.panes.map(\.tab) == [.sessions, .chat, .specs, .hooks, .git])
        #expect(InspectorTab.specs.needsWorkspace)
    }
}
