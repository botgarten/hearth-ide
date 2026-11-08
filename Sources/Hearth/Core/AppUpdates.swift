import Foundation
import Observation

/// Stable release tags published by scripts/release.sh (vMAJOR.MINOR.PATCH).
struct ReleaseVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    var description: String { "\(major).\(minor).\(patch)" }

    init?(_ value: String) {
        guard value.count <= 96, value.range(of: #"^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil else { return nil }
        let parts = value.drop(while: { $0 == "v" }).split(separator: ".")
        guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct InstalledAppVersion: Sendable {
    let label: String
    let release: ReleaseVersion?

    init(label: String, channel: String? = nil) {
        self.label = label
        // A post-tag git-describe build may already contain unreleased changes.
        // Never recommend replacing it based on the old tag's numeric prefix.
        release = channel == "development" ? nil : ReleaseVersion(label)
    }
    static var current: Self {
        Self(label: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "development build"),
             channel: Bundle.main.object(forInfoDictionaryKey: "HearthBuildChannel") as? String)
    }
}

struct UpdateResult: Equatable, Sendable {
    enum Relation: Sendable { case updateAvailable, current, ahead, development }
    let latest: ReleaseVersion
    let relation: Relation
    init(installed: InstalledAppVersion, latest: ReleaseVersion) {
        self.latest = latest
        if let current = installed.release {
            relation = current < latest ? .updateAvailable : current == latest ? .current : .ahead
        } else { relation = .development }
    }
}

struct UpdateService: Sendable {
    static let feed = URL(string: "https://github.com/botgarten/hearth-ide/releases/latest/download/latest-version.txt")!
    static let download = URL(string: "https://github.com/botgarten/hearth-ide/releases/latest/download/hearth-macos-arm64.zip")!
    static let installerCommand = "curl -fsSL https://github.com/botgarten/hearth-ide/releases/latest/download/install.sh | bash"
    var session: URLSession = UpdateTransport.session

    static let changelogURL = URL(string: "https://github.com/botgarten/hearth-ide/releases/latest/download/CHANGELOG.md")!

    /// Release notes published with each release (nil when missing, e.g. for old releases).
    func changelog(maxBytes: Int = 200_000) async -> String? {
        var components = URLComponents(url: Self.changelogURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "t", value: UUID().uuidString)]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maxBytes else { return nil }
                data.append(byte)
            }
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    static func downloadURL(for version: ReleaseVersion?) -> URL {
        var components = URLComponents(url: download, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "version", value: version?.description ?? UUID().uuidString)]
        return components.url!
    }

    enum Failure: LocalizedError {
        case invalidFeed, http(Int), unreachable
        var errorDescription: String? {
            switch self {
            case .invalidFeed: String(localized: "The update server returned no valid release version.")
            case .http(let code): String(localized: "Update check failed (HTTP \(code)). Check your network connection.")
            case .unreachable: String(localized: "The update server cannot be reached. Check your network connection and try again.")
            }
        }
    }

    static func request() -> URLRequest {
        var components = URLComponents(url: feed, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "t", value: UUID().uuidString)]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        return request
    }

    func latest() async throws -> ReleaseVersion {
        do {
            let (bytes, response) = try await session.bytes(for: Self.request())
            defer { bytes.task.cancel() }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw Failure.http(status) }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 128 else { throw Failure.invalidFeed }
                data.append(byte)
            }
            guard let text = String(data: data, encoding: .utf8),
                  let version = ReleaseVersion(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw Failure.invalidFeed }
            return version
        } catch let error as Failure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw Failure.unreachable }
    }
}

/// An independent unauthenticated transport. No cookies, credentials or cache.
/// GitHub answers `releases/latest/download/<file>` with a redirect to the tagged
/// release and then to its asset host, so redirects are followed only over HTTPS
/// to those GitHub hosts; any other target is refused.
final class UpdateTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let allowedRedirectHosts: Set<String> = ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
    static func allowsRedirect(to url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.port == nil, url.user == nil, let host = url.host?.lowercased() else { return false }
        return allowedRedirectHosts.contains(host)
    }
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: UpdateTransport(), delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allowsRedirect(to: request.url) ? request : nil)
    }
}

@MainActor
@Observable
final class UpdateChecker {
    let installed: InstalledAppVersion
    var automaticChecks: Bool {
        didSet { defaults.set(automaticChecks, forKey: "updates.checkOnLaunch") }
    }
    private(set) var checking = false
    private(set) var result: UpdateResult?
    private(set) var error: String?
    private(set) var lastCheckedAt: Date?
    /// Set right before quitting for an update; the helper starts in applicationWillTerminate.
    var installOnQuit = false
    /// Message about the previous update attempt (shown once after launch).
    var installMessage: String?
    var canInstall: Bool { result?.relation == .updateAvailable && error == nil }
    var service: UpdateService { serviceValue }
    private var dismissedVersion: ReleaseVersion?
    private let serviceValue: UpdateService
    private let defaults: UserDefaults
    private var launchChecked = false
    private var task: Task<Void, Never>?

    init(installed: InstalledAppVersion = .current, service: UpdateService = UpdateService(), defaults: UserDefaults = .standard) {
        self.installed = installed; self.serviceValue = service; self.defaults = defaults
        automaticChecks = defaults.object(forKey: "updates.checkOnLaunch") as? Bool ?? true
        lastCheckedAt = defaults.object(forKey: "updates.lastCheckedAt") as? Date
    }

    func reportPreviousInstall(_ outcome: AppUpdateInstaller.Outcome?) {
        switch outcome {
        case .failed?: installMessage = String(localized: "The last update failed; the previous version keeps running. Details: ~/Library/Logs/Hearth IDE/update.log")
        case .aborted?: installMessage = String(localized: "The last update was cancelled because the app did not quit.")
        case .succeeded?: installMessage = String(localized: "Hearth IDE was updated to \(installed.label).")
        case nil: break
        }
    }

    var notice: ReleaseVersion? {
        guard error == nil, result?.relation == .updateAvailable, let version = result?.latest, version != dismissedVersion else { return nil }
        return version
    }
    func dismissNotice() { dismissedVersion = result?.latest }

    func checkOnLaunch() async {
        guard !launchChecked else { return }
        launchChecked = true
        guard automaticChecks else { return }
        await check()
    }

    func check() async {
        if let task { await task.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.checking = true
            self.error = nil
            defer { self.checking = false }
            do {
                let version = try await self.serviceValue.latest()
                guard !Task.isCancelled else { return }
                self.result = UpdateResult(installed: self.installed, latest: version)
            } catch {
                guard !Task.isCancelled else { return }
                self.result = nil
                self.error = error.localizedDescription
            }
            self.lastCheckedAt = Date()
            self.defaults.set(self.lastCheckedAt, forKey: "updates.lastCheckedAt")
        }
        self.task = task
        await task.value
        self.task = nil
    }
}

/// Sections of CHANGELOG.md ("## 1.2.3 · date" + bullet list), newest first.
enum ReleaseNotes {
    struct Section: Equatable, Sendable {
        let version: ReleaseVersion
        let title: String
        let items: [String]
    }

    static func parse(_ markdown: String) -> [Section] {
        var sections: [Section] = []
        var current: (ReleaseVersion, String, [String])?
        func flush() { if let c = current { sections.append(Section(version: c.0, title: c.1, items: c.2)) } }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false).prefix(5000) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush(); current = nil
                let title = String(line.dropFirst(3))
                let first = title.split(whereSeparator: { $0 == " " || $0 == "·" }).first.map(String.init) ?? ""
                if let version = ReleaseVersion(first) { current = (version, String(title.prefix(80)), []) }
            } else if line.hasPrefix("- ") || line.hasPrefix("* "), current != nil, current!.2.count < 80 {
                current!.2.append(String(line.dropFirst(2).prefix(300)))
            }
        }
        flush()
        return sections
    }

    /// Notes for versions newer than `installed` up to and including `latest`.
    static func between(_ sections: [Section], installed: ReleaseVersion?, latest: ReleaseVersion) -> [Section] {
        sections.filter { section in
            section.version <= latest && (installed.map { section.version > $0 } ?? (section.version == latest))
        }
        .sorted { $0.version > $1.version }
    }
}
