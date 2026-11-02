import SwiftUI

/// The Search Everywhere popup (double Shift): category tabs, one search field and the
/// results, grouped by category under "All". ↑/↓ select, ↩ opens, ⇥ next category, ⎋ closes.
struct SearchEverywhereView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themePalette) private var palette
    private let focused = FocusState<Bool>()

    private var store: SearchEverywhereStore { model.search }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { store.close() }
                panel
                    .frame(width: min(max(geo.size.width - 80, 360), 860))
                    .frame(maxHeight: max(geo.size.height * 0.72, 260))
                    .padding(.top, 36)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .onAppear { focused.wrappedValue = true }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            tabs
            Divider()
            field
            Divider()
            results
        }
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }

    private var background: Color {
        palette.map { Color(nsColor: $0.editorBackground) } ?? Color(nsColor: .windowBackgroundColor)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(SearchScope.allCases) { scope in
                let selected = store.scope == scope
                Button { store.scope = scope; focused.wrappedValue = true } label: {
                    Text(scope.title)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor.opacity(0.7) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            if store.searching { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("", text: Binding(get: { store.query }, set: { store.query = $0 }), prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(.title3)
                .focused(focused.projectedValue)
                .onSubmit { store.activateSelection() }
                .onExitCommand { store.close() }
                .onKeyPress(.upArrow) { store.move(-1); return .handled }
                .onKeyPress(.downArrow) { store.move(1); return .handled }
                .onKeyPress(.tab, phases: .down) { press in
                    store.nextScope(backwards: press.modifiers.contains(.shift))
                    return .handled
                }
            Text("⇥ next category").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var prompt: String {
        switch store.scope {
        case .all: String(localized: "Search files, symbols, sessions, chat, tests and actions")
        case .files: String(localized: "File name or path")
        case .symbols: String(localized: "Class, function or type")
        case .text: String(localized: "Text in the project's files")
        case .chat: String(localized: "Text in the agents' chats")
        case .sessions: String(localized: "Agent session")
        case .tests: String(localized: "Test name")
        case .actions: String(localized: "Action")
        }
    }

    @ViewBuilder
    private var results: some View {
        let items = store.results
        if items.isEmpty {
            VStack(spacing: 6) {
                Text(emptyText).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if store.scope == .all, index == 0 || items[index - 1].scope != item.scope {
                                Text(item.scope.title)
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 12).padding(.top, index == 0 ? 2 : 8).padding(.bottom, 2)
                            }
                            row(item, selected: index == store.selection)
                                .id(item.id)
                                .onTapGesture { store.activate(item) }
                                .onHover { if $0 { store.selection = index } }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: store.selection) { _, i in
                    guard items.indices.contains(i) else { return }
                    proxy.scrollTo(items[i].id)
                }
            }
        }
    }

    private var emptyText: String {
        let q = store.query.trimmingCharacters(in: .whitespaces)
        if store.searching { return String(localized: "Searching…") }
        if model.workspaceRoot == nil, [.files, .symbols, .text, .tests].contains(store.scope) {
            return String(localized: "Select an agent session to search its folder.")
        }
        if q.count < 2, [.text, .chat].contains(store.scope) { return String(localized: "Type at least two characters.") }
        if q.isEmpty, store.scope == .symbols { return String(localized: "Type a name.") }
        return String(localized: "Nothing found")
    }

    private func row(_ item: SearchItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbol)
                .foregroundStyle(selected ? Color.white : iconColor(item))
                .frame(width: 18)
            Text(item.title)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if !item.detail.isEmpty {
                Text(item.detail)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                    .lineLimit(1).truncationMode(.head)
            }
        }
        .font(item.scope == .text || item.scope == .chat ? .system(.callout, design: .monospaced) : .body)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func iconColor(_ item: SearchItem) -> Color {
        switch item.scope {
        case .files: .blue
        case .symbols: .purple
        case .text: .secondary
        case .chat, .sessions: .orange
        case .tests: item.symbol == "xmark.circle" ? .red : .green
        case .actions, .all: .accentColor
        }
    }
}
