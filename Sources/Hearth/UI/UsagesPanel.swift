import SwiftUI
import AppKit

/// The result list of "Find Usages" below an editor: grouped by file, each row shows the line,
/// the code with the symbol marked and who (class/function) uses it.
struct UsagesPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var scale
    let search: EditorStore.UsageSearch
    let root: String
    @State private var height: CGFloat = 260

    private var shown: [Usage] {
        guard let all = search.result?.usages else { return [] }
        return all.filter { search.shownKinds.contains($0.kind) }
    }

    private var groups: [(path: String, usages: [Usage])] {
        var order: [String] = []
        var map: [String: [Usage]] = [:]
        for u in shown {
            if map[u.path] == nil { order.append(u.path) }
            map[u.path, default: []].append(u)
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            handle
            header
            Divider()
            content
        }
        .frame(height: height)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Header

    private var handle: some View {
        Color.clear.frame(height: 5)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { value in
                height = min(640, max(120, height - value.translation.height))
            })
    }

    private var summary: String {
        guard let result = search.result else { return String(localized: "Searching…") }
        let n = shown.count
        let files = Set(shown.map(\.path)).count
        var text: String
        switch (n, files) {
        case (0, _): text = String(localized: "No usages")
        case (1, _): text = String(localized: "1 usage in 1 file")
        case (_, 1): text = String(localized: "\(n) usages in 1 file")
        default: text = String(localized: "\(n) usages in \(files) files")
        }
        if result.truncated { text += " · " + String(localized: "list is limited") }
        return text
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
            Text("Usages of “\(search.query.text)”").scaledFont(.callout, bold: true).lineLimit(1)
            if search.searching { ProgressView().controlSize(.small) }
            Text(summary).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Menu {
                Picker("Search in", selection: Binding(get: { search.query.scope }, set: { model.editor.changeUsageScope($0) })) {
                    Text("Same language").tag(UsageQuery.Scope.sameLanguage)
                    Text("All files").tag(UsageQuery.Scope.allFiles)
                }
                .pickerStyle(.inline)
            } label: {
                Text(search.query.scope == .sameLanguage ? "Same language" : "All files")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Which files are searched")
            Menu {
                ForEach(Usage.Kind.allCases, id: \.self) { kind in
                    let count = search.result?.usages.filter { $0.kind == kind }.count ?? 0
                    Toggle(isOn: Binding(get: { search.shownKinds.contains(kind) }, set: { on in
                        if on { model.editor.usages?.shownKinds.insert(kind) } else { model.editor.usages?.shownKinds.remove(kind) }
                    })) { Text("\(Self.title(kind)) (\(count))") }
                }
            } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Show or hide kinds of usages")
            Button { model.editor.runUsages(search.query, root: root, pane: search.pane) } label: { Image(systemName: "arrow.clockwise") }
                .help("Search again")
            Button { model.editor.closeUsages() } label: { Image(systemName: "xmark") }
                .help("Close")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    static func title(_ kind: Usage.Kind) -> String {
        switch kind {
        case .definition: String(localized: "Definition")
        case .code: String(localized: "Code")
        case .importLine: String(localized: "Imports")
        case .comment: String(localized: "Comments")
        }
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if search.result == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            ContentUnavailableView {
                Label(search.result?.usages.isEmpty == true ? "No usages found" : "Everything is filtered out", systemImage: "magnifyingglass")
            } description: {
                if search.query.scope == .sameLanguage, search.result?.usages.isEmpty == true {
                    Text("Only files of the same language were searched. Choose “All files” to include the rest.")
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups, id: \.path) { group in
                        Section {
                            ForEach(group.usages) { usage in row(usage) }
                        } header: { fileHeader(group.path, count: group.usages.count) }
                    }
                }
            }
        }
    }

    private func fileHeader(_ path: String, count: Int) -> some View {
        let url = URL(fileURLWithPath: path)
        let dir = (path as NSString).deletingLastPathComponent
        return HStack(spacing: 5) {
            Image(systemName: FileIcon.symbol(for: url)).foregroundStyle(.secondary)
            Text(url.lastPathComponent).scaledFont(.callout, bold: true)
            if !dir.isEmpty { Text(dir).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            Spacer()
            Text("\(count)").scaledFont(.caption, digits: true).foregroundStyle(.secondary)
                .padding(.horizontal, 6).background(Color.primary.opacity(0.08), in: Capsule())
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func row(_ usage: Usage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(usage.line)").scaledFont(.caption, mono: true, digits: true).foregroundStyle(.secondary)
                .frame(width: 40 * scale, alignment: .trailing)
            Image(systemName: Self.icon(usage.kind)).font(.system(size: 10 * scale)).foregroundStyle(.secondary)
                .frame(width: 14 * scale)
            Text(Self.highlighted(usage, size: 12 * scale))
                .lineLimit(1).truncationMode(.tail)
                .opacity(usage.kind == .comment ? 0.65 : 1)
            Spacer(minLength: 8)
            if let who = usage.container {
                Text(who).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .help("Used in \(who)")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .interactiveRow { model.editor.open(usage, in: search.pane, root: root) }
        .contextMenu {
            Button("Copy path and line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(usage.path):\(usage.line)", forType: .string)
            }
            Button("Reveal this file in the directory") {
                model.revealEditorFile(URL(fileURLWithPath: root).appendingPathComponent(usage.path), in: root)
            }
        }
    }

    static func icon(_ kind: Usage.Kind) -> String {
        switch kind {
        case .definition: "scope"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .importLine: "arrow.down.right.square"
        case .comment: "text.bubble"
        }
    }

    static func highlighted(_ usage: Usage, size: CGFloat) -> AttributedString {
        let m = NSMutableAttributedString(string: usage.preview, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), .foregroundColor: NSColor.labelColor,
        ])
        let r = NSRange(location: usage.column, length: usage.length)
        if r.location >= 0, NSMaxRange(r) <= m.length {
            m.addAttributes([.backgroundColor: NSColor.systemOrange.withAlphaComponent(0.3),
                             .font: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)], range: r)
        }
        return (try? AttributedString(m, including: \.appKit)) ?? AttributedString(usage.preview)
    }
}
