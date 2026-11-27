import Foundation
import Testing
@testable import Hearth

/// The spec quality check and the coverage of acceptance criteria by tasks.
struct SpecAnalysisTests {
    static let requirements = """
    # Requirements: CSV export

    ### Requirement 1: Export the table

    **User story:** As an analyst, I want to export the table, so that I can use a spreadsheet.

    #### Acceptance criteria

    1. WHEN the user clicks Export THEN the system SHALL download the visible rows.
    2. WHEN a filter is active THEN the system SHALL export only the filtered rows.
    3. The file name contains the date.

    ### Requirement 2: Large tables

    1. IF the table has more than 50 000 rows THEN the system SHALL export in the background.

    ### Requirement 3: Nothing yet

    ## Open questions

    1. Should hidden columns be exported?
    - Separator?
    """

    private func spec(_ docs: [SpecPhase: String], kind: SpecKind = .feature) -> Spec {
        Spec(folder: URL(fileURLWithPath: "/tmp/x"), relativePath: ".hearth/specs/x",
             record: SpecRecord(name: "X", kind: kind), documents: docs)
    }

    @Test func readsRequirementsCriteriaAndOpenQuestions() {
        let doc = SpecAnalysis.requirements(Self.requirements)
        #expect(doc.requirements.map(\.id) == ["1", "2", "3"])
        #expect(doc.requirements[0].title == "Export the table" && doc.requirements[0].hasStory)
        #expect(!doc.requirements[1].hasStory)
        #expect(doc.criteria.map(\.id) == ["1.1", "1.2", "1.3", "2.1"])
        #expect(doc.criteria.filter { !$0.isEARS }.map(\.id) == ["1.3"])
        #expect(doc.openQuestions == ["Should hidden columns be exported?", "Separator?"])
        let none = SpecAnalysis.requirements("### Requirement 1\n1. WHEN a THEN the system SHALL b\n## Open questions\n\nNone.\n")
        #expect(none.openQuestions.isEmpty)
    }

    @Test func findingsNameWhatToFix() {
        let ids = SpecAnalysis.findings(spec([.requirements: Self.requirements])).map(\.id)
        #expect(ids.contains("req-ears") && ids.contains("req-nocriteria") && ids.contains("req-questions") && ids.contains("req-story"))
        let questions = SpecAnalysis.findings(spec([.requirements: Self.requirements])).first { $0.id == "req-questions" }
        #expect(questions?.answerQuestions == true && questions?.fix == nil)
        // A bugfix spec doesn't need user stories.
        #expect(!SpecAnalysis.findings(spec([.requirements: Self.requirements], kind: .bugfix)).map(\.id).contains("req-story"))
    }

    @Test func coverageTracesCriteriaToTasks() {
        let tasks = """
        - [x] 1. Export
          - _Requirements: 1.1, 1.2_
        - [ ] 2. Background export
          - [x] 2.1 Worker
            - _Requirements: 2.1_
          - [ ] 2.2 Progress
            - _Requirements: 2.1, 9.9_
        - [ ] 3. Polish
        """
        let doc = SpecAnalysis.requirements(Self.requirements)
        let traces = SpecAnalysis.trace(doc, tasks: SpecTasksParser.parse(tasks))
        let state = Dictionary(uniqueKeysWithValues: traces.map { ($0.id, $0.state) })
        #expect(state == ["1.1": .done, "1.2": .done, "1.3": .uncovered, "2.1": .partial])
        let ids = SpecAnalysis.findings(spec([.requirements: Self.requirements, .tasks: tasks])).filter { $0.phase == .tasks }.map(\.id)
        #expect(ids.contains("tasks-uncovered") && ids.contains("tasks-unknown") && ids.contains("tasks-unlinked"))
        // A reference to a whole requirement covers all its criteria.
        let whole = SpecAnalysis.trace(doc, tasks: SpecTasksParser.parse("- [ ] 1. All of it\n  - _Requirements: 1_\n"))
        #expect(whole.filter { $0.id.hasPrefix("1.") }.allSatisfy { $0.state == .planned })
    }

    @Test func designTopics() {
        let design = "# Design\n## Overview\n## Architecture\n## Components and Interfaces\n## Error Handling\n"
        #expect(SpecAnalysis.missingDesignTopics(design) == [String(localized: "Data models"), String(localized: "Testing strategy")])
    }

    @Test func olderRecordsStillLoadAndNewFieldsPersist() throws {
        let old = #"{"name":"Old","idea":"x","created":"2026-11-01T10:00:00Z","approved":{}}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let record = try d.decode(SpecRecord.self, from: Data(old.utf8))
        #expect(record.kind == .feature && record.guided && record.checks.isEmpty)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spec-\(UUID().uuidString)").path
        var spec = try SpecLibrary.create(name: "Crash on start", idea: "", kind: .bugfix, guided: false, root: root)
        spec = try SpecLibrary.update(spec) { $0.checks["requirements"] = [0, 2] }
        let loaded = try #require(SpecLibrary.scan(root: root).first)
        #expect(loaded.record.kind == .bugfix && !loaded.record.guided && loaded.record.checks["requirements"] == [0, 2])
    }

    @Test func promptsFollowTheKindAndTheInterview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spec-\(UUID().uuidString)").path
        let bug = try SpecLibrary.create(name: "Crash", idea: "App crashes on start", kind: .bugfix, root: root)
        let p = SpecPrompts.requirements(bug, steering: [], clarify: true)
        #expect(p.contains("Current behaviour") && p.contains("regression") && p.contains("ask me the questions"))
        #expect(p.contains("Open questions"))
        let feature = try SpecLibrary.create(name: "Search", idea: "", root: root)
        #expect(!SpecPrompts.requirements(feature, steering: []).contains("ask me"))
        #expect(SpecAnalysis.checklist(.requirements, kind: .bugfix).count == 3)
    }
}
