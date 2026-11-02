import Foundation
import Observation

/// What the inspector shows for the selected session's folder: Git state, directory
/// tree state and a revision that bumps whenever files may have changed.
@MainActor
@Observable
final class WorkspaceState {
    /// Bumped whenever the agent may have changed files. The directory tree and the editor
    /// follow it directly; heavier views use `settledRevision`.
    var revision = 0 { didSet { scheduleSettle() } }
    /// Follows `revision` once changes have paused for `settleDelay`, or at the latest after
    /// `maxSettleDelay` while an agent keeps writing. Tests, diagrams, branches, Git status and
    /// CI/CD reload on this, so they don't restart their work on every file the agent writes.
    private(set) var settledRevision = 0
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSince: ContinuousClock.Instant?
    @ObservationIgnored var settleDelay: Duration = .milliseconds(1500)
    @ObservationIgnored var maxSettleDelay: Duration = .seconds(10)
    var gitSnapshot = GitSnapshot()
    var expandedPaths: Set<String> = []
    var selectedFile: URL?
    var revealID = UUID()
    let dragToken = UUID()
    /// Empty clone targets created by this app instance may be retried, never arbitrary folders.
    var cloneDirectories: Set<String> = []
    /// A test to show in the Tests pane (from Search Everywhere).
    var testFocus: TestFocus?

    struct TestFocus: Equatable {
        var id: String
        var name: String
        var token = UUID()
    }

    /// An explicit reload (refresh button, session switch): everything follows at once.
    func refreshNow() {
        revision += 1
        settle()
    }

    private func scheduleSettle() {
        guard revision != settledRevision else { return }
        let now = ContinuousClock.now
        let since = pendingSince ?? now
        pendingSince = since
        let remaining = maxSettleDelay - (now - since)
        let delay = min(settleDelay, max(remaining, .zero))
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    private func settle() {
        settleTask?.cancel()
        settleTask = nil
        pendingSince = nil
        settledRevision = revision
    }
}

/// Text size per area (chat, inspector, sidebar, single panes), ⌘-scroll / pinch zoom.
@MainActor
@Observable
final class TextZoomStore {
    var scales: [String: Double] = UIStateStore.load(.textScales) ?? [:] {
        didSet { UIStateStore.save(scales, as: .textScales) }
    }
    /// Area under the mouse; ⌘-scroll / pinch zoom applies there.
    var hoveredArea: TextArea?
    var hoveringDiagram = false
    @ObservationIgnored var notify: (String) -> Void = { _ in }

    static let range: ClosedRange<Double> = 0.7...2.2

    func scale(_ area: TextArea) -> Double {
        scales[area.rawValue] ?? (area.base == area ? 1 : scale(area.base))
    }

    func zoom(_ area: TextArea, by factor: Double) {
        let next = min(max(scale(area) * factor, Self.range.lowerBound), Self.range.upperBound)
        guard abs(next - scale(area)) > 0.001 else { return }
        scales[area.rawValue] = next
        let name = switch area {
        case .chat: "Chat"; case .inspector: "Inspector"; case .sidebar: "Sessions"
        case .pane(_, let tab): tab.title
        }
        notify(String(localized: "Text size \(name): \(Int((next * 100).rounded())) %"))
    }

    func zoomAll(by factor: Double) {
        TextArea.allCases.forEach { zoom($0, by: factor) }
        for key in scales.keys where key.hasPrefix("pane:") {
            scales[key] = min(max(scales[key]! * factor, Self.range.lowerBound), Self.range.upperBound)
        }
    }

    func reset(_ area: TextArea) {
        scales[area.rawValue] = nil
        notify(String(localized: "Text size reset"))
    }

    func reset() {
        scales = [:]
        notify(String(localized: "Text size reset"))
    }
}

/// CI access tokens (GitLab, GitHub) per approved HTTPS origin (CI/CD pane), read and write kept apart.
@MainActor
@Observable
final class CIAccounts {
    var readTokens: [CIOrigin: String] = [:]
    var writeTokens: [CIOrigin: String] = [:]
    var loadedOrigins: Set<CIOrigin> = []
    private var credentialRevision: [CIOrigin: Int] = [:]
    private static let approvedKey = "gitlab.approvedOrigins.v2"

    func load(for origin: CIOrigin) async {
        guard !loadedOrigins.contains(origin) else { return }
        loadedOrigins.insert(origin)
        let approved = UserDefaults.standard.stringArray(forKey: Self.approvedKey) ?? []
        guard Snapshotter.directory == nil, approved.contains(origin.value) else { return }
        let revision = credentialRevision[origin, default: 0]
        let (read, write) = await Task.detached {
            (CIToken.load(origin: origin, writing: false), CIToken.load(origin: origin, writing: true))
        }.value
        guard credentialRevision[origin, default: 0] == revision else { return }
        readTokens[origin] = read
        writeTokens[origin] = write
    }

    /// Only call after explicit confirmation of the displayed HTTPS origin.
    func save(_ token: String, for origin: CIOrigin, writing: Bool) -> Bool {
        guard CIToken.save(token, origin: origin, writing: writing) else { return false }
        credentialRevision[origin, default: 0] += 1
        if writing { writeTokens[origin] = token } else { readTokens[origin] = token }
        var approved = Set(UserDefaults.standard.stringArray(forKey: Self.approvedKey) ?? [])
        approved.insert(origin.value)
        UserDefaults.standard.set(Array(approved).sorted(), forKey: Self.approvedKey)
        return true
    }

    func api(for remote: CIRemote, writing: Bool = false) -> (any CIClient)? {
        // A write token is never silently used for polling/read requests.
        guard let token = (writing ? writeTokens : readTokens)[remote.origin] else { return nil }
        return remote.client(CICredential(origin: remote.origin, token: token, allowsWrites: writing))
    }

    func revoke(_ origin: CIOrigin) {
        credentialRevision[origin, default: 0] += 1
        readTokens[origin] = nil
        writeTokens[origin] = nil
        CIToken.delete(origin: origin, writing: false)
        CIToken.delete(origin: origin, writing: true)
        let approved = UserDefaults.standard.stringArray(forKey: Self.approvedKey) ?? []
        UserDefaults.standard.set(approved.filter { $0 != origin.value }, forKey: Self.approvedKey)
    }
}
