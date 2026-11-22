import Foundation

/// The agent CLIs Hearth can run in a sandbox. Each brings its own login; Hearth
/// only grants the paths and hosts that agent needs.
enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, copilot, opencode, gemini, shell

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .copilot: "GitHub Copilot CLI"
        case .opencode: "OpenCode"
        case .gemini: "Gemini CLI"
        case .shell: String(localized: "Sandbox shell")
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .copilot: "person.2.wave.2"
        case .opencode: "curlybraces"
        case .gemini: "diamond"
        case .shell: "terminal"
        }
    }

    /// Executable looked up on the login shell's PATH.
    var executable: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .copilot: "copilot"
        case .opencode: "opencode"
        case .gemini: "gemini"
        case .shell: "zsh"
        }
    }

    var installHint: String {
        switch self {
        case .claude: "npm install -g @anthropic-ai/claude-code"
        case .codex: "npm install -g @openai/codex"
        case .copilot: "npm install -g @github/copilot"
        case .opencode: "brew install opencode"
        case .gemini: "npm install -g @google/gemini-cli"
        case .shell: ""
        }
    }

    /// How the agent tells Hearth that it is working, waiting or finished.
    enum StatusSource { case hooks, notify, terminal }

    var statusSource: StatusSource {
        switch self {
        case .claude: .hooks
        case .codex: .notify
        default: .terminal
        }
    }

    /// Models offered when starting a session: aliases the CLI resolves to its latest model,
    /// cheapest useful one first. Empty: the agent's own default only.
    var modelChoices: [String] {
        self == .claude ? ["sonnet", "haiku", "opus", "fable"] : []
    }

    /// Reasoning effort levels offered when starting a session (empty: no choice).
    var effortChoices: [String] {
        switch self {
        case .claude: ["low", "medium", "high", "xhigh", "max"]
        case .codex: ["low", "medium", "high"]
        default: []
        }
    }

    /// Arguments for the chosen model and effort. Unknown values are dropped (the options
    /// are read back from Hearth's session list, so they are checked, not trusted).
    func arguments(options: AgentLaunchOptions) -> [String] {
        var args: [String] = []
        let model = options.model.flatMap { modelChoices.contains($0) ? $0 : nil }
        let effort = options.effort.flatMap { effortChoices.contains($0) ? $0 : nil }
        switch self {
        case .claude:
            if let model { args += ["--model", model] }
            if let effort { args += ["--effort", effort] }
        case .codex:
            if let effort { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
        default: break
        }
        return args
    }

    /// Arguments for a fresh session, or one continuing `sessionID` when the agent supports it.
    func arguments(resume sessionID: String?, options: AgentLaunchOptions) -> [String] {
        arguments(options: options) + arguments(resume: sessionID)
    }

    /// Arguments for a fresh session, or one continuing `sessionID` when the agent supports it.
    func arguments(resume sessionID: String?) -> [String] {
        switch self {
        case .claude: sessionID.map { ["--resume", $0] } ?? []
        case .codex: sessionID.map { ["resume", $0] } ?? []
        case .opencode: sessionID.map { ["--session", $0] } ?? []
        case .shell: ["-f", "-i"]   // no rc files: shell configs are denied inside the sandbox anyway
        default: []
        }
    }

    /// Arguments that start the agent's own login flow (nil: log in from inside the agent).
    var loginArguments: [String]? {
        switch self {
        case .claude: ["auth", "login"]
        case .codex: ["login"]
        case .opencode: ["auth", "login"]
        default: nil
        }
    }

    var loginHint: String {
        switch self {
        case .claude: String(localized: "Runs “claude auth login” in the sandbox. Or type /login in a session.")
        case .codex: String(localized: "Runs “codex login” in the sandbox.")
        case .copilot: String(localized: "Type /login in a session.")
        case .opencode: String(localized: "Runs “opencode auth login” and asks for the provider.")
        case .gemini: String(localized: "Gemini asks you to sign in on first start.")
        case .shell: ""
        }
    }

    var sandbox: AgentSandboxSpec {
        switch self {
        case .claude:
            AgentSandboxSpec(groups: ["claude_code_macos"],
                             domains: ["statsig.anthropic.com", "console.anthropic.com"],
                             keychain: true,
                             openURLOrigins: ["https://claude.ai", "https://platform.claude.com", "https://console.anthropic.com"],
                             environment: ["DISABLE_AUTOUPDATER": "1"])
        case .codex:
            AgentSandboxSpec(groups: ["codex_macos"],
                             domains: ["chatgpt.com", "auth.openai.com", "ab.chatgpt.com"],
                             keychain: true,
                             openURLOrigins: ["https://auth.openai.com", "https://chatgpt.com"],
                             allowLocalhost: true, openPorts: [1455])
        case .copilot:
            AgentSandboxSpec(domains: ["api.githubcopilot.com", "api.individual.githubcopilot.com",
                                       "api.business.githubcopilot.com", "api.enterprise.githubcopilot.com",
                                       "copilot-proxy.githubusercontent.com", "telemetry.individual.githubcopilot.com",
                                       "origin-tracker.githubusercontent.com"],
                             keychain: true,
                             openURLOrigins: ["https://github.com"])
        case .opencode:
            AgentSandboxSpec(domains: ["models.dev", "opencode.ai", "api.githubcopilot.com", "api.individual.githubcopilot.com"],
                             openURLOrigins: ["https://github.com", "https://opencode.ai"],
                             environment: ["OPENCODE_DISABLE_AUTOUPDATE": "1"])
        case .gemini:
            AgentSandboxSpec(domains: ["cloudcode-pa.googleapis.com", "oauth2.googleapis.com", "www.googleapis.com",
                                       "accounts.google.com", "play.googleapis.com"],
                             openURLOrigins: ["https://accounts.google.com"], allowLocalhost: true)
        case .shell:
            AgentSandboxSpec()
        }
    }
}

/// Model and reasoning effort a session starts with (nil: the agent's own default).
/// A smaller model or lower effort is the biggest lever on token use for routine work.
struct AgentLaunchOptions: Codable, Equatable, Sendable {
    var model: String?
    var effort: String?

    static let none = AgentLaunchOptions()

    private static func key(_ directory: String) -> String { "agents.launchOptions." + directory }

    /// The choice last used in `directory`.
    static func last(in directory: String) -> AgentLaunchOptions {
        guard let data = UserDefaults.standard.data(forKey: key(directory)),
              let options = try? JSONDecoder().decode(AgentLaunchOptions.self, from: data) else { return .none }
        return options
    }

    static func remember(_ options: AgentLaunchOptions, in directory: String) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        UserDefaults.standard.set(data, forKey: key(directory))
    }
}

/// What one agent needs on top of Hearth's base sandbox (project folder, toolchains).
/// Its configuration folder comes from AgentHome.
struct AgentSandboxSpec: Sendable {
    var groups: [String] = []
    var domains: [String] = []
    /// Login keychain access (Claude Code, Codex and Copilot keep their login there).
    var keychain = false
    var openURLOrigins: [String] = []
    var allowLocalhost = false
    var openPorts: [Int] = []
    var environment: [String: String] = [:]
}
