import SwiftUI

/// Colours shared by every diff in the Git pane.
enum DiffStyle {
    static let added = Color.green
    static let removed = Color.red
    static func rowBackground(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: added.opacity(0.12)
        case .removed: removed.opacity(0.12)
        case .hunk: Color.accentColor.opacity(0.07)
        default: .clear
        }
    }
    static func gutterBackground(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: added.opacity(0.2)
        case .removed: removed.opacity(0.2)
        case .hunk: Color.accentColor.opacity(0.1)
        default: Color.primary.opacity(0.03)
        }
    }
}

/// Unified diff lines with old/new line numbers. Not scrolling by itself, so several files
/// can be stacked in one scroll view. `below` adds content under a line (comment threads,
/// a comment composer); `onComment` shows a "+" on hover to start a comment on that line.
struct DiffLinesView<Below: View>: View {
    @Environment(\.textScale) private var scale
    let lines: [DiffLine]
    var onComment: ((DiffLine) -> Void)?
    @ViewBuilder var below: (DiffLine) -> Below

    init(lines: [DiffLine], onComment: ((DiffLine) -> Void)? = nil, @ViewBuilder below: @escaping (DiffLine) -> Below) {
        self.lines = lines
        self.onComment = onComment
        self.below = below
    }

    /// git's own header lines say nothing a reader needs next to the file header.
    static func visible(_ line: DiffLine) -> Bool {
        guard line.kind == .meta else { return true }
        let t = line.text
        return !(t.hasPrefix("index ") || t.hasPrefix("--- ") || t.hasPrefix("+++ ") || t.hasPrefix("similarity index")
                 || t.hasPrefix("new file mode") || t.hasPrefix("deleted file mode") || t.hasPrefix("old mode") || t.hasPrefix("new mode"))
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines.filter(Self.visible)) { line in
                DiffRow(line: line, scale: scale, onComment: onComment)
                below(line)
            }
        }
        .textSelection(.enabled)
    }
}

extension DiffLinesView where Below == EmptyView {
    init(lines: [DiffLine]) {
        self.init(lines: lines, onComment: nil) { _ in EmptyView() }
    }
}

private struct DiffRow: View {
    let line: DiffLine
    let scale: Double
    let onComment: ((DiffLine) -> Void)?
    @State private var hovering = false

    private var size: CGFloat { 11.5 * scale }
    private var gutter: CGFloat { 38 * scale }

    var body: some View {
        switch line.kind {
        case .meta where line.text.hasPrefix("diff --git "):
            fileHeader
        case .meta:
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: size, design: .monospaced)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 0.5)
        case .hunk:
            HStack(spacing: 0) {
                Image(systemName: "ellipsis").font(.system(size: size * 0.85)).foregroundStyle(.tertiary)
                    .frame(width: gutter * 2 + 14)
                Text(line.text).font(.system(size: size * 0.92, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .background(DiffStyle.rowBackground(.hunk))
        case .note:
            Text(line.text).font(.system(size: size * 0.9, design: .monospaced)).italic().foregroundStyle(.tertiary)
                .padding(.leading, gutter * 2 + 18).padding(.vertical, 1)
        default:
            codeLine
        }
    }

    private var fileHeader: some View {
        let path = line.text.components(separatedBy: " b/").last ?? line.text
        return HStack(spacing: 6) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(path).font(.system(size: size, weight: .semibold, design: .monospaced))
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.05))
        .overlay(alignment: .top) { Divider() }
        .padding(.top, 8)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: " "
        }
    }

    private var codeLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    number(line.oldLine)
                    number(line.newLine)
                }
                if hovering, let onComment {
                    Button { onComment(line) } label: {
                        Image(systemName: "plus.bubble.fill")
                            .font(.system(size: size))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Comment on this line")
                    .padding(.leading, 4)
                }
            }
            .frame(width: gutter * 2, alignment: .leading)
            .background(DiffStyle.gutterBackground(line.kind))
            Text(marker)
                .font(.system(size: size, weight: .semibold, design: .monospaced))
                .foregroundStyle(line.kind == .added ? DiffStyle.added : line.kind == .removed ? DiffStyle.removed : .secondary)
                .frame(width: 16)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: size, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 0.5)
        .background(DiffStyle.rowBackground(line.kind))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: size * 0.88, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.trailing, 6)
            .frame(width: gutter, alignment: .trailing)
    }
}

/// A complete diff (local file, commit, stash) in its own scroll view.
struct DiffScrollView: View {
    let text: String?
    var emptyMessage: String = String(localized: "No changes")

    var body: some View {
        if let text {
            let lines = UnifiedDiff.parse(text)
            if lines.isEmpty {
                ContentUnavailableView(emptyMessage, systemImage: "checkmark.circle")
            } else {
                ScrollView {
                    DiffLinesView(lines: lines)
                        .padding(.bottom, 12)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Small rounded label for states and counts.
struct Badge: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .scaledFont(.caption2, bold: true)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

/// "+12 −3" as used in file lists.
struct LineCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        if added + removed > 0 {
            HStack(spacing: 4) {
                Text("+\(added)").foregroundStyle(DiffStyle.added)
                Text("−\(removed)").foregroundStyle(DiffStyle.removed)
            }
            .scaledFont(.caption, digits: true)
            .fixedSize()
        }
    }
}
