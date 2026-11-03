import Foundation
import Testing
@testable import Hearth

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ value: Bool, _ message: String) throws {
    if !value { throw TestFailure(description: message) }
}

func need<T>(_ value: T?, _ message: String = "Erwarteter Wert fehlt") throws -> T {
    guard let value else { throw TestFailure(description: message) }
    return value
}

/// A fresh folder under the temporary directory, removed by the caller.
func temporaryFolder(_ name: String = "hearth-test") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

/// In-memory sandbox: every started command plays the same script. Each output read
/// advances one step, like a process producing output over time.
final class FakeCommandRunner: SandboxCommandRunner, @unchecked Sendable {
    enum Step { case output(String), exit(Int32), running }
    private let lock = NSLock()
    private var _requests: [SandboxCommandRequest] = []
    private var _removed: [String] = []
    private var script: [Step] = []
    private var output = ""
    private var state = SandboxCommandState.running
    private var counter = 0
    var failStart = false
    var list: [SandboxCommandInfo] = []

    var requests: [SandboxCommandRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var removed: [String] { lock.lock(); defer { lock.unlock() }; return _removed }

    init(_ steps: [Step] = []) { script = steps }

    func reset(_ steps: [Step]) {
        lock.lock(); defer { lock.unlock() }
        _requests = []; _removed = []; script = steps; output = ""; state = .running; failStart = false
    }

    private func advance() {
        guard !script.isEmpty else { return }
        switch script.removeFirst() {
        case .output(let text): output += text
        case .exit(let code): state = .exited(code)
        case .running: script.insert(.running, at: 0)
        }
    }

    func start(_ request: SandboxCommandRequest) async throws -> String {
        try lock.withLock {
            _requests.append(request)
            if failStart { throw SandboxCommandError("Sandbox not available") }
            counter += 1
            return "sh_\(counter)"
        }
    }

    func state(of id: String) async throws -> SandboxCommandState {
        lock.withLock {
            // A real process keeps working between polls.
            advance()
            return state
        }
    }

    func output(of id: String, from cursor: Int, limit: Int) async throws -> SandboxOutputPage {
        lock.withLock {
            advance()
            let bytes = Array(output.utf8)
            let start = min(max(cursor, 0), bytes.count), end = min(start + limit, bytes.count)
            return SandboxOutputPage(text: String(decoding: bytes[start..<end], as: UTF8.self), next: end, size: bytes.count)
        }
    }

    func remove(_ id: String) async {
        lock.withLock {
            _removed.append(id)
            if state == .running { state = .killed }
        }
    }

    func running() async -> [SandboxCommandInfo] { list }
}

/// Tests that host real AppKit/WebKit views wait for them with fixed delays. Run in parallel, a booting
/// web view starves those delays, so such tests take turns.
actor ViewTestGate {
    static let shared = ViewTestGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }

    func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// `await ViewTestGate.turn()` at the top of a view-hosting test; the returned token ends the turn when released.
struct ViewTurn: Sendable {
    fileprivate init() {}
    func end() { Task { await ViewTestGate.shared.leave() } }
}

extension ViewTestGate {
    static func turn() async -> ViewTurn {
        await shared.enter()
        return ViewTurn()
    }
}
