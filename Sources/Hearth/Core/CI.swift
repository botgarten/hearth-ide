import Foundation
import Security

/// A canonical HTTPS origin, independent of any repository-controlled project path.
struct CIOrigin: Hashable, Codable, Sendable {
    let url: URL
    var value: String { url.absoluteString }
    var authority: String { String(value.dropFirst("https://".count)) }

    static func parse(_ value: String) -> CIOrigin? {
        guard let c = URLComponents(string: value), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/",
              c.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        var clean = URLComponents()
        clean.scheme = "https"
        clean.host = host.lowercased()
        clean.port = c.port == 443 ? nil : c.port
        guard let url = clean.url else { return nil }
        return CIOrigin(url: url)
    }
}

/// Which CI system a remote belongs to.
enum CIProvider: String, Sendable {
    case gitLab, gitHub

    var name: String { self == .gitLab ? "GitLab" : "GitHub" }
    /// What one run is called there.
    var runName: String { self == .gitLab ? "Pipeline" : String(localized: "Workflow run") }
}

/// Parsing a remote does NOT authorize this server to receive a token.
struct CIRemote: Hashable, Sendable {
    let origin: CIOrigin
    let path: String          // e.g. "group/project" or "owner/repo"
    var host: String { origin.authority }

    /// github.com and GitHub Enterprise ("github.<company>") are GitHub; everything else GitLab.
    var provider: CIProvider {
        let h = (origin.url.host ?? "").lowercased()
        return h == "github.com" || h.hasPrefix("github.") ? .gitHub : .gitLab
    }

    var webURL: URL { URL(string: "https://\(host)/\(path)")! }

    var apiBase: URL {
        switch provider {
        case .gitLab: URL(string: "https://\(host)/api/v4")!
        case .gitHub: host == "github.com" ? URL(string: "https://api.github.com")! : URL(string: "https://\(host)/api/v3")!
        }
    }

    /// The provider's own page listing pipelines / workflow runs.
    var pipelinesPage: URL { webURL.appendingPathComponent(provider == .gitLab ? "-/pipelines" : "actions") }

    /// Page where the user creates a token with the needed rights.
    func tokenPage(writing: Bool) -> URL {
        switch provider {
        case .gitLab: GitLabAPI.tokenPage(host: host, writing: writing)
        case .gitHub: URL(string: "https://\(host)/settings/personal-access-tokens/new")!
        }
    }

    /// The API client for this remote, bound to the approved credential.
    func client(_ credential: CICredential) -> any CIClient {
        switch provider {
        case .gitLab: GitLabAPI(remote: self, credential: credential)
        case .gitHub: GitHubAPI(remote: self, credential: credential)
        }
    }

    /// Parses git@host:group/repo.git, ssh://git@host[:port]/group/repo.git and https://host/group/repo.git.
    static func parse(_ remote: String) -> CIRemote? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        if let m = s.range(of: #"^[\w.-]+@([^:/]+):(.+)$"#, options: .regularExpression), m.lowerBound == s.startIndex {
            let parts = s.split(separator: "@", maxSplits: 1)[1].split(separator: ":", maxSplits: 1)
            return validated(origin: "https://\(parts[0])", path: String(parts[1]))
        }
        guard let url = URL(string: s), let host = url.host, ["https", "ssh"].contains(url.scheme ?? ""),
              url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme != "https" || url.user == nil else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let port = url.scheme == "https" ? url.port.map { ":\($0)" } ?? "" : ""
        return validated(origin: "https://\(host)\(port)", path: path)
    }

    private static func validated(origin: String, path: String) -> CIRemote? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let origin = CIOrigin.parse(origin), segments.count >= 2,
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                  $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil }) else { return nil }
        return CIRemote(origin: origin, path: path)
    }

    static func of(repo: String) async -> CIRemote? {
        guard let url = await Git.run(["config", "--get", "remote.origin.url"], in: repo) else { return nil }
        return parse(url)
    }
}

struct CICredential: Sendable {
    let origin: CIOrigin
    let token: String
    let allowsWrites: Bool
}

/// Keychain entries scoped to one HTTPS origin and to read or write access.
enum CIToken {
    static let service = "hearth-gitlab"
    private static func account(_ origin: CIOrigin, writing: Bool) -> String {
        origin.value + (writing ? "#write" : "#read")
    }

    static func load(origin: CIOrigin, writing: Bool) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account(origin, writing: writing),
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    @discardableResult
    static func save(_ token: String, origin: CIOrigin, writing: Bool) -> Bool {
        delete(origin: origin, writing: writing)
        let attrs: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account(origin, writing: writing),
                                    kSecAttrLabel as String: "Hearth IDE GitLab \(origin.value) \(writing ? "write" : "read")",
                                    kSecValueData as String: Data(token.utf8)]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func delete(origin: CIOrigin, writing: Bool) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account(origin, writing: writing)] as CFDictionary)
    }
}

/// The CI operations the Pipelines pane uses, for GitLab and GitHub Actions alike.
/// Status strings follow GitLab's vocabulary (success, failed, running, pending, …).
protocol CIClient: Sendable {
    var remote: CIRemote { get }
    func pipelines(ref: String?) async throws -> [CIPipeline]
    func jobs(pipeline: Int) async throws -> [CIJob]
    func log(job: Int) async throws -> String
    func retry(pipeline: Int) async throws
    func cancel(pipeline: Int) async throws
    func retry(job: Int) async throws
    /// Starts a job waiting for a manual start (GitLab only).
    func play(job: Int) async throws
    /// Workflows that can be started by hand (GitHub); empty for GitLab.
    func workflows() async throws -> [CIWorkflow]
    /// Starts a new pipeline (GitLab) or the given workflow (GitHub) for a branch.
    func run(ref: String, workflow: CIWorkflow?) async throws
    /// Opens a merge request (GitLab) or pull request (GitHub) and returns its page.
    func createChangeRequest(_ request: ChangeRequest) async throws -> URL
}

struct ChangeRequest: Sendable, Equatable {
    var title: String
    var description: String
    var source: String
    var target: String
    var draft: Bool

    static func valid(_ value: String) -> Bool { SandboxGitOperation.validRef(value) }
}

struct CIWorkflow: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let path: String
}

struct CIPipeline: Identifiable, Hashable, Sendable {
    let id: Int
    let iid: Int
    let ref: String
    let sha: String
    let status: String
    let source: String
    let createdAt: Date?
    let webURL: URL?
    /// Workflow name (GitHub).
    var name: String?

    init(id: Int, iid: Int, ref: String, sha: String, status: String, source: String,
         createdAt: Date?, webURL: URL?, name: String? = nil) {
        self.id = id; self.iid = iid; self.ref = ref; self.sha = sha; self.status = status
        self.source = source; self.createdAt = createdAt; self.webURL = webURL; self.name = name
    }

    init?(json j: JSON) {
        guard let id = j["id"]?.double.map(Int.init) else { return nil }
        self.id = id
        iid = j["iid"]?.double.map(Int.init) ?? id
        ref = j["ref"]?.string ?? ""
        sha = j["sha"]?.string ?? ""
        status = j["status"]?.string ?? "unknown"
        source = j["source"]?.string ?? ""
        createdAt = j["created_at"]?.string.flatMap(GitLabAPI.date)
        webURL = j["web_url"]?.string.flatMap(URL.init(string:))
    }
}

struct CIJob: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let stage: String
    let status: String
    let duration: Double?
    let allowFailure: Bool
    let webURL: URL?

    init(id: Int, name: String, stage: String, status: String, duration: Double?, allowFailure: Bool = false, webURL: URL?) {
        self.id = id; self.name = name; self.stage = stage; self.status = status
        self.duration = duration; self.allowFailure = allowFailure; self.webURL = webURL
    }

    init?(json j: JSON) {
        guard let id = j["id"]?.double.map(Int.init) else { return nil }
        self.id = id
        name = j["name"]?.string ?? "job"
        stage = j["stage"]?.string ?? ""
        status = j["status"]?.string ?? "unknown"
        duration = j["duration"]?.double
        allowFailure = j["allow_failure"] == .bool(true)
        webURL = j["web_url"]?.string.flatMap(URL.init(string:))
    }
}

/// Minimal GitLab REST client for pipelines and jobs.
struct GitLabAPI: CIClient {
    let remote: CIRemote
    let credential: CICredential
    var session: URLSession = NoRedirectTransport.session

    enum APIError: LocalizedError {
        case http(Int, String)
        case unauthorizedOrigin, readOnly
        var errorDescription: String? {
            switch self {
            case .unauthorizedOrigin: String(localized: "This HTTPS origin is not approved for this token.")
            case .readOnly: String(localized: "For write actions, approve a separate token with the api scope for this server.")
            case .http(401, _): String(localized: "GitLab rejects the token (401). Expired, or missing the read_api/api scope?")
            case .http(403, _): String(localized: "No permission (403). Starting or retrying needs a token with the “api” scope and at least Developer access – protected branches or environments can be locked as well.")
            case .http(404, _): String(localized: "Project not found or no permission (404).")
            case .http(let c, let b): String(localized: "GitLab error \(c): \(b.prefix(160))")
            }
        }
    }

    static func date(_ s: String) -> Date? { ISO8601.date(s) }

    private var project: String {
        remote.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? remote.path
    }

    func authorizedRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) throws -> URLRequest {
        guard CIOrigin.parse(remote.origin.value) == remote.origin,
              remote.origin == credential.origin else { throw APIError.unauthorizedOrigin }
        guard method == "GET" || credential.allowsWrites else { throw APIError.readOnly }
        var comps = URLComponents(url: remote.apiBase, resolvingAgainstBaseURL: false)!
        comps.percentEncodedPath = remote.apiBase.path + path
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue(credential.token, forHTTPHeaderField: "PRIVATE-TOKEN")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        req.timeoutInterval = 20
        return req
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
        let req = try authorizedRequest(method, path, query: query, body: body)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }

    func pipelines(ref: String?) async throws -> [CIPipeline] {
        var q = [URLQueryItem(name: "per_page", value: "15"), URLQueryItem(name: "order_by", value: "id")]
        if let ref { q.append(URLQueryItem(name: "ref", value: ref)) }
        let data = try await request("GET", "/projects/\(project)/pipelines", query: q)
        return (JSON.parse(data)?.array ?? []).compactMap(CIPipeline.init(json:))
    }

    func jobs(pipeline: Int) async throws -> [CIJob] {
        let data = try await request("GET", "/projects/\(project)/pipelines/\(pipeline)/jobs",
                                     query: [URLQueryItem(name: "per_page", value: "100"),
                                             URLQueryItem(name: "include_retried", value: "false")])
        return (JSON.parse(data)?.array ?? []).compactMap(CIJob.init(json:)).sorted { $0.id < $1.id }
    }

    func log(job: Int) async throws -> String {
        let raw = String(decoding: try await request("GET", "/projects/\(project)/jobs/\(job)/trace"), as: UTF8.self)
        // GitLab section markers carry no content for a reader.
        return raw.strippingANSI
            .replacingOccurrences(of: #"section_(start|end):\d+:[^\n\r]*?(\r|\n)?"#, with: "", options: .regularExpression)
    }

    func workflows() async throws -> [CIWorkflow] { [] }

    func createChangeRequest(_ cr: ChangeRequest) async throws -> URL {
        guard ChangeRequest.valid(cr.source), ChangeRequest.valid(cr.target) else { throw APIError.http(422, "invalid branch") }
        let title = cr.draft && !cr.title.lowercased().hasPrefix("draft:") ? "Draft: " + cr.title : cr.title
        let data = try await request("POST", "/projects/\(project)/merge_requests", body: [
            "source_branch": cr.source, "target_branch": cr.target, "title": title, "description": cr.description])
        guard let web = JSON.parse(data)?["web_url"]?.string, let url = URL(string: web), url.scheme == "https" else {
            throw APIError.http(502, "no web_url in response")
        }
        return url
    }

    func run(ref: String, workflow: CIWorkflow?) async throws { try await runPipeline(ref: ref) }

    func retry(pipeline: Int) async throws { _ = try await request("POST", "/projects/\(project)/pipelines/\(pipeline)/retry") }
    func cancel(pipeline: Int) async throws { _ = try await request("POST", "/projects/\(project)/pipelines/\(pipeline)/cancel") }
    func retry(job: Int) async throws { _ = try await request("POST", "/projects/\(project)/jobs/\(job)/retry") }

    /// Starts a job waiting in "manual" state.
    func play(job: Int) async throws { _ = try await request("POST", "/projects/\(project)/jobs/\(job)/play") }

    /// Creates a new pipeline for a branch or tag.
    func runPipeline(ref: String) async throws {
        _ = try await request("POST", "/projects/\(project)/pipeline", query: [URLQueryItem(name: "ref", value: ref)])
    }

    /// Page where the user can create a token with the right scope prefilled.
    static func tokenPage(host: String, writing: Bool = false) -> URL {
        URL(string: "https://\(host)/-/user_settings/personal_access_tokens?name=hearth&scopes=\(writing ? "api" : "read_api")")!
    }
}

/// No credential forwarding through redirects, even to another path on the same host.
final class NoRedirectTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirectTransport(), delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum CIStatus {
    static func isActive(_ s: String) -> Bool {
        ["running", "pending", "created", "preparing", "waiting_for_resource", "scheduled"].contains(s)
    }

    static func symbol(_ s: String) -> String {
        switch s {
        case "success": "checkmark.circle.fill"
        case "failed": "xmark.circle.fill"
        case "running": "arrow.triangle.2.circlepath.circle.fill"
        case "pending", "created", "preparing", "waiting_for_resource", "scheduled": "clock.fill"
        case "canceled", "canceling": "slash.circle.fill"
        case "skipped": "forward.circle.fill"
        case "manual": "gearshape.circle.fill"
        default: "questionmark.circle.fill"
        }
    }

    static func label(_ s: String) -> String {
        switch s {
        case "success": String(localized: "succeeded")
        case "failed": String(localized: "failed")
        case "running": String(localized: "running")
        case "pending", "created", "preparing", "waiting_for_resource": String(localized: "waiting")
        case "scheduled": String(localized: "scheduled")
        case "canceled", "canceling": String(localized: "cancelled")
        case "skipped": String(localized: "skipped")
        case "manual": String(localized: "manual")
        default: s
        }
    }
}
