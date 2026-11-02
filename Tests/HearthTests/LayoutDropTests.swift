import Foundation
import Testing
@testable import Hearth

/// The blue drop preview while a pane is dragged must never stay behind.
@MainActor
struct LayoutDropTests {
    @Test func onlyOnePreviewAndLateExitsAreIgnored() {
        let layout = LayoutStore()
        let a = UUID(), b = UUID()
        layout.hoverDrop(.left, over: a, buttonDown: { true })
        // SwiftUI may report the new pane before the exit of the old one.
        layout.hoverDrop(.center, over: b, buttonDown: { true })
        layout.endDropHover(leaving: a)
        #expect(layout.dropHover == .init(pane: b, zone: .center))
        #expect(layout.windowDropZone == nil)
        layout.hoverDrop(.windowLeft, over: b, buttonDown: { true })
        #expect(layout.windowDropZone == .windowLeft)
        layout.endDropHover()
        #expect(layout.dropHover == nil && layout.windowDropZone == nil)
    }

    @Test func previewDisappearsWhenTheDragEndsUnreported() async throws {
        let layout = LayoutStore()
        var down = true
        layout.hoverDrop(.right, over: UUID(), buttonDown: { down })
        try await Task.sleep(for: .milliseconds(400))
        #expect(layout.dropHover != nil, "Cleared while the button is still down")
        // Mouse released, but no dropExited/performDrop arrived.
        down = false
        let start = ContinuousClock.now
        while layout.dropHover != nil, ContinuousClock.now - start < .seconds(5) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(layout.dropHover == nil)
    }
}
