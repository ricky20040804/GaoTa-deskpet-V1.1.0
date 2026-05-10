import Foundation

// MARK: - Provider

enum AgentProvider: String, CaseIterable {
    case claude, codex, copilot, gemini, opencode, openclaw, doubao

    private static let defaultsKey = "selectedProvider"

    static var current: AgentProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? "claude"
            return AgentProvider(rawValue: raw) ?? .claude
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var displayName: String {
        switch self {
        case .claude:   return "Claude"
        case .codex:    return "Codex"
        case .copilot:  return "Copilot"
        case .gemini:   return "Gemini"
        case .opencode: return "OpenCode"
        case .openclaw: return "OpenClaw"
        case .doubao:   return "豆包"
        }
    }

    var inputPlaceholder: String {
        "问问 \(displayName)..."
    }

    /// Returns provider name styled per theme format.
    func titleString(format: TitleFormat) -> String {
        switch format {
        case .uppercase:      return displayName.uppercased()
        case .lowercaseTilde: return displayName.lowercased()
        case .capitalized:    return displayName
        }
    }

    var binaryName: String {
        switch self {
        case .claude:   return "claude"
        case .codex:    return "codex"
        case .copilot:  return "copilot"
        case .gemini:   return "gemini"
        case .opencode: return "opencode"
        case .openclaw: return "openclaw"
        case .doubao:   return "doubao"
        }
    }

    /// Cache of provider availability, populated by `detectAvailableProviders`.
    private(set) static var availability: [AgentProvider: Bool] = [:]

    /// Scan PATH for all provider binaries and call completion when done.
    static func detectAvailableProviders(completion: @escaping () -> Void) {
        let all = AgentProvider.allCases
        let group = DispatchGroup()
        for provider in all {
            // Network/API based providers do not require local binaries.
            if provider == .openclaw {
                availability[provider] = OpenClawConfig.load().authToken.isEmpty == false
                continue
            }
            if provider == .doubao {
                availability[provider] = DoubaoConfig.load().isConfigured
                continue
            }
            group.enter()
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            ShellEnvironment.findBinary(name: provider.binaryName, fallbackPaths: [
                "\(home)/.local/bin/\(provider.binaryName)",
                "/usr/local/bin/\(provider.binaryName)",
                "/opt/homebrew/bin/\(provider.binaryName)"
            ]) { path in
                availability[provider] = path != nil
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion()
        }
    }

    var isAvailable: Bool {
        if self == .openclaw { return OpenClawConfig.load().authToken.isEmpty == false }
        if self == .doubao { return DoubaoConfig.load().isConfigured }
        return AgentProvider.availability[self] ?? false
    }

    /// Returns the first available provider, or `.claude` as fallback.
    static var firstAvailable: AgentProvider {
        allCases.first(where: { $0.isAvailable }) ?? .claude
    }

    var installInstructions: String {
        switch self {
        case .claude:
            return "To install, run this in Terminal:\n  curl -fsSL https://claude.ai/install.sh | sh\n\nOr download from https://claude.ai/download"
        case .codex:
            return "To install, run this in Terminal:\n  npm install -g @openai/codex"
        case .copilot:
            return "To install, run this in Terminal:\n  brew install copilot-cli\n\nOr: npm install -g @github/copilot-cli"
        case .gemini:
            return "To install, run this in Terminal:\n  npm install -g @google/gemini-cli\n\nThen authenticate:\n  gemini auth"
        case .opencode:
            return "To install, run this in Terminal:\n  curl -fsSL https://opencode.ai/install | bash"
        case .openclaw:
            return "OpenClaw is a self-hosted AI gateway.\n\nInstall: npm install -g openclaw\nStart:   openclaw gateway run\n\nDocs: https://docs.openclaw.ai"
        case .doubao:
            return "请在菜单栏打开“豆包 API 设置…”并填写 API Key 与 Endpoint / Model。"
        }
    }

    func createSession() -> any AgentSession {
        switch self {
        case .claude:   return ClaudeSession()
        case .codex:    return CodexSession()
        case .copilot:  return CopilotSession()
        case .gemini:   return GeminiSession()
        case .opencode: return OpenCodeSession()
        case .openclaw: return OpenClawSession()
        case .doubao:   return DoubaoSession()
        }
    }
}

// MARK: - Title Format

enum TitleFormat {
    case uppercase       // "CLAUDE"
    case lowercaseTilde  // "claude ~"
    case capitalized     // "Claude"
}

// MARK: - Message

struct AgentMessage {
    enum Role { case user, assistant, error, toolUse, toolResult }
    let role: Role
    let text: String
}

// MARK: - Session Protocol

protocol AgentSession: AnyObject {
    var isRunning: Bool { get }
    var isBusy: Bool { get }
    var history: [AgentMessage] { get set }

    var onText: ((String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onToolUse: ((String, [String: Any]) -> Void)? { get set }
    var onToolResult: ((String, Bool) -> Void)? { get set }
    var onSessionReady: (() -> Void)? { get set }
    var onTurnComplete: (() -> Void)? { get set }
    var onProcessExit: (() -> Void)? { get set }

    func start()
    func send(message: String)
    func terminate()
}
