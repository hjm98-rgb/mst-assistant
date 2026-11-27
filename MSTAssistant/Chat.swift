import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant, system }
    var id: UUID = UUID()
    var role: Role
    var text: String
    var date: Date = Date()
    var failed: Bool = false
}

struct ChatConfig: Codable {
    // 默认直连本机 Ollama，加载开源权重 qwen2.5vl:3b（无需密钥）
    var endpoint: String = "http://127.0.0.1:11434/api/chat"
    var model: String = "qwen2.5:3b"
    var visionModel: String = "qwen2.5vl:3b"
    var apiKey: String = ""
    var systemPrompt: String = "你是 MST 助手，运行在用户的越狱 iPad 上。回答简洁、直接、可执行。"

    // 采样参数
    var temperature: Double = 0.7
    var topP: Double = 0.9
    var maxTokens: Int = 512
    var presencePenalty: Double = 0.0
    var frequencyPenalty: Double = 0.0
    /// 额外请求字段（JSON 对象文本），如 {"top_k":20,"enable_thinking":false}
    var extraJSON: String = ""

    enum CodingKeys: String, CodingKey {
        case endpoint, model, visionModel, apiKey, systemPrompt
        case temperature, topP, maxTokens, presencePenalty, frequencyPenalty, extraJSON
    }

    init() {}

    // 兼容旧 config.json：缺字段就用默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChatConfig()
        endpoint = (try? c.decodeIfPresent(String.self, forKey: .endpoint)) ?? d.endpoint
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? d.model
        visionModel = (try? c.decodeIfPresent(String.self, forKey: .visionModel)) ?? d.visionModel
        apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? d.apiKey
        systemPrompt = (try? c.decodeIfPresent(String.self, forKey: .systemPrompt)) ?? d.systemPrompt
        temperature = (try? c.decodeIfPresent(Double.self, forKey: .temperature)) ?? d.temperature
        topP = (try? c.decodeIfPresent(Double.self, forKey: .topP)) ?? d.topP
        maxTokens = (try? c.decodeIfPresent(Int.self, forKey: .maxTokens)) ?? d.maxTokens
        presencePenalty = (try? c.decodeIfPresent(Double.self, forKey: .presencePenalty)) ?? d.presencePenalty
        frequencyPenalty = (try? c.decodeIfPresent(Double.self, forKey: .frequencyPenalty)) ?? d.frequencyPenalty
        extraJSON = (try? c.decodeIfPresent(String.self, forKey: .extraJSON)) ?? d.extraJSON
    }

    /// 采样参数合并进请求体；空 extraJSON 或非法 JSON 时忽略，不影响主流程
    func applySampling(to body: inout [String: Any], isOllama: Bool) {
        if isOllama {
            var opts: [String: Any] = ["temperature": temperature, "top_p": topP, "num_predict": maxTokens]
            if presencePenalty != 0 { opts["presence_penalty"] = presencePenalty }
            if frequencyPenalty != 0 { opts["frequency_penalty"] = frequencyPenalty }
            body["options"] = opts
        } else {
            body["temperature"] = temperature
            body["top_p"] = topP
            if maxTokens > 0 { body["max_tokens"] = maxTokens }
            if presencePenalty != 0 { body["presence_penalty"] = presencePenalty }
            if frequencyPenalty != 0 { body["frequency_penalty"] = frequencyPenalty }
        }
        let e = extraJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty, let d = e.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in obj { body[k] = v }
        }
    }
}

/// 本地持久化：/Documents/mst/chat.json + config.json
final class ChatStore: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var config = ChatConfig()
    @Published var busy = false
    @Published var statusLine = ""

    private var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mst", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }
    private var chatFile: URL { dir.appendingPathComponent("chat.json") }
    private var configFile: URL { dir.appendingPathComponent("config.json") }

    init() { load() }

    func load() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: configFile), let c = try? dec.decode(ChatConfig.self, from: d) { config = c }
        if let d = try? Data(contentsOf: chatFile), let m = try? dec.decode([ChatMessage].self, from: d) { messages = m }
        statusLine = DeviceInfo.summary()
    }

    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(messages) { try? d.write(to: chatFile) }
        if let d = try? enc.encode(config) { try? d.write(to: configFile) }
    }

    func clearHistory() { messages = []; save() }

    @MainActor
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: trimmed))
        let assistant = ChatMessage(role: .assistant, text: "")
        messages.append(assistant)
        let idx = messages.count - 1
        save()
        busy = true
        defer { busy = false }

        if config.apiKey.isEmpty && config.endpoint.contains("dashscope") {
            messages[idx].text = "DashScope 托管服务必须带密钥；如果用自己的 vLLM/llama.cpp 部署，把地址改成自建的，密钥留空就行。"
            messages[idx].failed = true
            save()
            return
        }

        do {
            let answer = try await QwenClient.chat(config: config, history: messages.filter { $0.text.isEmpty == false && $0.id != assistant.id })
            messages[idx].text = answer
        } catch {
            messages[idx].text = "请求失败：\(error.localizedDescription)"
            messages[idx].failed = true
        }
        save()
    }
}
