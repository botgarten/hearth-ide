import Foundation
import Testing
@testable import Hearth

/// Layouts saved by name from the Layout menu.
@MainActor
struct SavedLayoutTests {
    @Test func savedLayoutComesBackWithItsSizesAndFreshIDs() throws {
        let layout = LayoutStore()
        layout.apply(.review)
        layout.addPane(.terminal, atWindowEdge: .windowBottom)
        let tabs = layout.paneTree.panes.map(\.tab)
        guard case .split(let rootID, _, _) = layout.paneTree else { Issue.record("no split"); return }
        layout.splitWeights[rootID] = [0.8, 0.2]

        layout.saveCurrentLayout(as: "  Mine ")
        #expect(layout.savedLayouts.map(\.name) == ["Mine"])

        layout.apply(.standard)
        layout.apply(try #require(layout.savedLayouts.first))
        #expect(layout.paneTree.panes.map(\.tab) == tabs)
        guard case .split(let newRoot, _, _) = layout.paneTree else { Issue.record("no split"); return }
        #expect(newRoot != rootID)
        #expect(layout.weights(for: newRoot, count: 2) == [0.8, 0.2])
    }

    @Test func sameNameReplacesAndDeleteRemoves() throws {
        let layout = LayoutStore()
        layout.apply(.focusChat)
        layout.saveCurrentLayout(as: "Work")
        layout.saveCurrentLayout(as: "")
        let id = try #require(layout.savedLayouts.first?.id)
        layout.apply(.monitoring)
        layout.saveCurrentLayout(as: "work")
        #expect(layout.savedLayouts.count == 1 && layout.savedLayouts[0].id == id)
        #expect(layout.savedLayouts[0].tree.contains(tab: .pipelines))
        layout.deleteSavedLayout(id)
        #expect(layout.savedLayouts.isEmpty)
    }

    @Test func survivesEncoding() throws {
        let (tree, weights) = LayoutPreset.standard.build()
        let data = try JSONEncoder().encode([SavedLayout(name: "A", tree: tree, weights: weights)])
        let back = try JSONDecoder().decode([SavedLayout].self, from: data)
        #expect(back.first?.tree.panes.map(\.tab) == tree.panes.map(\.tab))
        #expect(back.first?.weights == weights)
    }
}
