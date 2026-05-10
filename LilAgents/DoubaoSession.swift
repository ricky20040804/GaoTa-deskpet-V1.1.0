import AppKit
import Foundation

struct DoubaoConfig {
    var baseURL: String
    var apiKey: String
    var modelID: String
    var systemPrompt: String

    private static let defaults = UserDefaults.standard
    private static let defaultBaseURL = "https://ark.cn-beijing.volces.com/api/v3"
    private static let defaultSystemPrompt = "你是豆包，是桌面宠物里的 AI 助手。请用自然、友好的中文与用户对话，并优先给出直接、有帮助的回答。"

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func load() -> DoubaoConfig {
        let env = ProcessInfo.processInfo.environment

        let savedBaseURL = defaults.string(forKey: "doubaoBaseURL") ?? defaultBaseURL
        let savedAPIKey = defaults.string(forKey: "doubaoAPIKey") ?? ""
        let savedModelID = defaults.string(forKey: "doubaoModelID") ?? ""
        let savedSystemPrompt = defaults.string(forKey: "doubaoSystemPrompt") ?? defaultSystemPrompt

        return DoubaoConfig(
            baseURL: env["ARK_BASE_URL"] ?? env["DOUBAO_BASE_URL"] ?? savedBaseURL,
            apiKey: env["ARK_API_KEY"] ?? env["DOUBAO_API_KEY"] ?? savedAPIKey,
            modelID: env["ARK_MODEL"] ?? env["DOUBAO_MODEL"] ?? savedModelID,
            systemPrompt: env["DOUBAO_SYSTEM_PROMPT"] ?? savedSystemPrompt
        )
    }

    func save() {
        let defaults = Self.defaults
        defaults.set(baseURL, forKey: "doubaoBaseURL")
        defaults.set(apiKey, forKey: "doubaoAPIKey")
        defaults.set(modelID, forKey: "doubaoModelID")
        defaults.set(systemPrompt, forKey: "doubaoSystemPrompt")
    }
}

final class DoubaoSession: AgentSession {
    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let stream: Bool
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: ContentValue
            }

            let message: Message
        }

        let choices: [Choice]
    }

    private enum ContentValue: Decodable {
        case string(String)
        case array([ContentPart])

        struct ContentPart: Decodable {
            let type: String?
            let text: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .string(string)
                return
            }
            if let array = try? container.decode([ContentPart].self) {
                self = .array(array)
                return
            }
            throw DecodingError.typeMismatch(
                ContentValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported message content format")
            )
        }

        var textValue: String {
            switch self {
            case .string(let value):
                return value
            case .array(let parts):
                return parts.compactMap { part in
                    if let type = part.type, type != "text" {
                        return nil
                    }
                    return part.text
                }.joined()
            }
        }
    }

    private var currentTask: URLSessionDataTask?

    private(set) var isRunning = false
    private(set) var isBusy = false
    var history: [AgentMessage] = []

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?

    func start() {
        isRunning = true
        onSessionReady?()
    }

    func send(message: String) {
        guard isRunning, !isBusy else { return }

        let config = DoubaoConfig.load()
        guard config.isConfigured else {
            let guidance = """
            豆包还没有配置完成。

            请在菜单栏里打开 `豆包 API 设置…`，至少填写：
            1. API Key
            2. Endpoint / Model

            也可以通过环境变量提供：
            `ARK_API_KEY` / `DOUBAO_API_KEY`
            `ARK_MODEL` / `DOUBAO_MODEL`
            """
            reportError(guidance)
            return
        }

        guard let requestURL = normalizedRequestURL(from: config.baseURL) else {
            reportError("Doubao Base URL 无效：\(config.baseURL)")
            return
        }

        isBusy = true
        history.append(AgentMessage(role: .user, text: message))

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let payload = ChatRequest(
            model: config.modelID,
            messages: buildMessages(for: config),
            stream: false
        )

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            reportError("豆包请求编码失败：\(error.localizedDescription)")
            return
        }

        currentTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                defer {
                    self.currentTask = nil
                    self.isBusy = false
                }

                if let error {
                    self.reportError("豆包请求失败：\(error.localizedDescription)")
                    self.onTurnComplete?()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      let data else {
                    self.reportError("豆包没有返回可读取的数据。")
                    self.onTurnComplete?()
                    return
                }

                guard (200..<300).contains(httpResponse.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    self.reportError(self.userFriendlyErrorMessage(statusCode: httpResponse.statusCode, body: body, modelID: config.modelID))
                    self.onTurnComplete?()
                    return
                }

                do {
                    let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
                    let content = decoded.choices.first?.message.content.textValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    guard !content.isEmpty else {
                        self.reportError("豆包返回成功，但回复内容为空。")
                        self.onTurnComplete?()
                        return
                    }

                    self.history.append(AgentMessage(role: .assistant, text: content))
                    self.onText?(content)
                    self.onTurnComplete?()
                } catch {
                    let raw = String(data: data, encoding: .utf8) ?? ""
                    self.reportError("豆包响应解析失败：\(error.localizedDescription)\n\(raw)")
                    self.onTurnComplete?()
                }
            }
        }

        currentTask?.resume()
    }

    func terminate() {
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
        isBusy = false
        onProcessExit?()
    }

    private func buildMessages(for config: DoubaoConfig) -> [ChatRequest.Message] {
        var messages: [ChatRequest.Message] = []

        let prompt = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            messages.append(.init(role: "system", content: prompt))
        }

        for item in history {
            switch item.role {
            case .user:
                messages.append(.init(role: "user", content: item.text))
            case .assistant:
                messages.append(.init(role: "assistant", content: item.text))
            case .error, .toolUse, .toolResult:
                continue
            }
        }

        return messages
    }

    private func normalizedRequestURL(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed)
        }

        let normalizedBase = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: normalizedBase + "/chat/completions")
    }

    private func reportError(_ message: String) {
        onError?(message)
        history.append(AgentMessage(role: .error, text: message))
    }

    private func userFriendlyErrorMessage(statusCode: Int, body: String, modelID: String) -> String {
        if statusCode == 404,
           body.contains("InvalidEndpointOrModel.NotFound") {
            return """
            豆包返回了错误：
            当前的 Endpoint / Model 不存在，或者你的账号没有访问权限。

            现在填写的是：
            `\(modelID)`

            请去火山方舟控制台确认：
            1. 这个推理接入点 ID 是否真实存在
            2. 你的 API Key 是否属于有权限访问它的账号
            3. 如果你用的是模型名而不是接入点 ID，它是否支持当前 API

            原始返回：
            HTTP 404
            \(body)
            """
        }

        let message = body.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode)\n\(body)"
        return "豆包返回了错误：\n\(message)"
    }

    static func showSettingsPanel(onSave: (() -> Void)? = nil) {
        let config = DoubaoConfig.load()

        let alert = NSAlert()
        alert.messageText = "豆包 API 设置"
        alert.informativeText = "配置豆包 API 后，这只桌面宠物会只通过豆包与用户对话。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 238))

        func addRow(
            _ label: String,
            value: String,
            placeholder: String,
            tooltip: String,
            y: CGFloat,
            secure: Bool = false
        ) -> NSTextField {
            let title = NSTextField(labelWithString: label)
            title.frame = NSRect(x: 0, y: y + 2, width: 128, height: 20)
            title.font = .systemFont(ofSize: 13)
            title.toolTip = tooltip
            container.addSubview(title)

            let field = secure ? NSSecureTextField(frame: .zero) : NSTextField(frame: .zero)
            field.frame = NSRect(x: 132, y: y, width: 288, height: 24)
            field.stringValue = value
            field.placeholderString = placeholder
            field.toolTip = tooltip
            container.addSubview(field)
            return field
        }

        let baseURLField = addRow(
            "Base URL:",
            value: config.baseURL,
            placeholder: "https://ark.cn-beijing.volces.com/api/v3",
            tooltip: "火山方舟兼容 OpenAI 的 API Base URL。默认会拼接 /chat/completions。",
            y: 194
        )
        let apiKeyField = addRow(
            "API Key:",
            value: config.apiKey,
            placeholder: "输入你的 Ark API Key",
            tooltip: "在火山方舟控制台创建的 API Key，会通过 Authorization: Bearer 发送。",
            y: 154,
            secure: true
        )
        let modelField = addRow(
            "Endpoint / Model:",
            value: config.modelID,
            placeholder: "填写火山方舟里可用的推理接入点 ID",
            tooltip: "推荐填写你在火山方舟控制台创建并可访问的推理接入点 ID；它会作为 model 字段发送。",
            y: 114
        )
        let promptField = addRow(
            "System Prompt:",
            value: config.systemPrompt,
            placeholder: "可选：给宠物一个固定人设",
            tooltip: "可选系统提示词，用来约束豆包的回答风格。",
            y: 74
        )

        let hint = NSTextField(wrappingLabelWithString: "你也可以通过环境变量配置：ARK_API_KEY、ARK_BASE_URL、ARK_MODEL。")
        hint.frame = NSRect(x: 0, y: 8, width: 420, height: 44)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        container.addSubview(hint)

        alert.accessoryView = container

        if alert.runModal() == .alertFirstButtonReturn {
            let saved = DoubaoConfig(
                baseURL: baseURLField.stringValue.isEmpty ? DoubaoConfig.load().baseURL : baseURLField.stringValue,
                apiKey: apiKeyField.stringValue,
                modelID: modelField.stringValue,
                systemPrompt: promptField.stringValue.isEmpty ? DoubaoConfig.load().systemPrompt : promptField.stringValue
            )
            saved.save()
            onSave?()
        }
    }
}
