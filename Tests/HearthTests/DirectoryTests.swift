import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Hearth

@MainActor
struct DirectoryTests {
    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw WorkspaceFiles.Failure(message) }
    }

    @Test func nativeDragDropAndReveal() async throws {
        let turn = await ViewTestGate.turn()
        defer { turn.end() }
        _ = NSApplication.shared
        let fm = FileManager.default
        let base = { () -> URL in
            let raw = ProcessInfo.processInfo.environment["HEARTH_SECURITY_FIXTURES"] ?? NSTemporaryDirectory()
            // Foundation strips /private when resolving; directory listings keep it.
            guard let real = realpath(raw, nil) else { return URL(fileURLWithPath: raw) }
            defer { free(real) }
            return URL(fileURLWithPath: String(cString: real))
        }()
            .appendingPathComponent("directory-native-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let folder = base.appendingPathComponent("target")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = base.appendingPathComponent("source.txt")
        try Data("preserved".utf8).write(to: file)
        let token = UUID()
        var selections = 0
        var moves = 0
        func tree(selected: URL? = nil, expanded: Set<String> = [], revision: Int = 0) -> NativeDirectoryTree {
            NativeDirectoryTree(root: base.path, markers: [:], expandedPaths: expanded, selectedFile: selected,
                revealID: UUID(), revision: revision, scale: 1, dragToken: token,
                select: { _ in selections += 1 }, expand: { _, _ in }, move: { source, directory in
                    do {
                        let destination = try WorkspaceFiles.moveDestination(source: source, directory: directory, root: base)
                        try fm.moveItem(at: source, to: destination)
                        moves += 1
                        return true
                    } catch { return false }
                }, menu: { _ in NSMenu() })
        }
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: tree())
        window.contentView = hosting
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        func find(_ view: NSView) -> NativeDirectoryTree.DirectoryOutline? {
            if let outline = view as? NativeDirectoryTree.DirectoryOutline { return outline }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let outline = find(hosting), let coordinator = outline.dataSource as? NativeDirectoryTree.Coordinator,
              let target = outline.item(atRow: 0) as? NativeDirectoryTree.Node,
              let source = outline.item(atRow: 1) as? NativeDirectoryTree.Node else {
            throw WorkspaceFiles.Failure("Native directory callbacks not installed")
        }
        try require(outline.frame.width > 100 && outline.numberOfRows == 2, "Directory layout is empty")
        try require(outline.registeredDraggedTypes.contains(WorkspaceFileDrag.pasteboardType), "Drop type not registered")
        for selector in ["outlineView:pasteboardWriterForItem:", "outlineView:validateDrop:proposedItem:proposedChildIndex:", "outlineView:acceptDrop:item:childIndex:"] {
            try require(coordinator.responds(to: NSSelectorFromString(selector)), "AppKit cannot dispatch callback: \(selector)")
        }
        try require(target.file.isDirectory && source.file.url.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path, "Unexpected native row order")
        guard let writer = coordinator.outlineView(outline, pasteboardWriterForItem: source) as? NSPasteboardItem,
              let data = writer.data(forType: WorkspaceFileDrag.pasteboardType) else {
            throw WorkspaceFiles.Failure("Native drag does not provide a payload")
        }
        try require(coordinator.accept(data, onto: target), "Native drop rejected a valid move")
        let moved = folder.appendingPathComponent(file.lastPathComponent)
        try require(fm.fileExists(atPath: moved.path) && !fm.fileExists(atPath: file.path), "Drop did not move file")
        try require(moves == 1, "Move callback count")

        coordinator.parent = tree(selected: moved, expanded: [folder.path], revision: 1)
        coordinator.synchronize()
        try require(outline.selectedRow >= 0 && (outline.item(atRow: outline.selectedRow) as? NativeDirectoryTree.Node)?.file.url.path == moved.path,
                    "Reveal did not expand/select nested file: row \(outline.selectedRow) rows \(outline.numberOfRows) \((0..<outline.numberOfRows).map { (outline.item(atRow: $0) as? NativeDirectoryTree.Node)?.file.url.path ?? "?" }) expected \(moved.path)")
        try require(selections == 0, "Programmatic reveal reopened editor document")
        let movedNode = outline.item(atRow: outline.selectedRow) as! NativeDirectoryTree.Node
        let rootData = (coordinator.outlineView(outline, pasteboardWriterForItem: movedNode) as! NSPasteboardItem).data(forType: WorkspaceFileDrag.pasteboardType)
        try require(coordinator.accept(rootData, onto: nil), "Drop onto workspace root failed")
        try require(fm.fileExists(atPath: file.path), "Root drop did not move file back")
        let sourceFolder = base.appendingPathComponent("sourceFolder")
        try fm.createDirectory(at: sourceFolder, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: sourceFolder.appendingPathComponent("nested.txt"))
        let folderNode = NativeDirectoryTree.Node(FileNode(url: sourceFolder, isDirectory: true), reveal: nil)
        let folderData = (coordinator.outlineView(outline, pasteboardWriterForItem: folderNode) as! NSPasteboardItem).data(forType: WorkspaceFileDrag.pasteboardType)
        try require(coordinator.accept(folderData, onto: target), "Folder drop failed")
        try require(fm.fileExists(atPath: folder.appendingPathComponent("sourceFolder/nested.txt").path), "Folder contents not preserved")
        let foreign = WorkspaceFileDrag(source: file, root: base.path, token: UUID())
        try require(!coordinator.accept(foreign.pasteboardItem.data(forType: WorkspaceFileDrag.pasteboardType), onto: target), "Foreign drag accepted")

        let payload = WorkspaceFileDrag(source: file, root: base.path, token: token)
        let providerData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            payload.provider.loadDataRepresentation(forTypeIdentifier: WorkspaceFileDrag.type.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? WorkspaceFiles.Failure("Missing provider data")) }
            }
        }
        try require(WorkspaceFileDrag.decode(providerData, root: base.path, token: token)?.source == file, "SwiftUI root-drop data bridge failed")
    }

}
