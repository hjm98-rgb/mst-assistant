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
    var endpoint: String = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
    var model: String = "qwen-plus"
    var apiKey: String = ""
    var systemPrompt: String = "你是 MST 助手，运行在用户的越狱 iPad 上。回答简洁、直接、可执行。"
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

        if config.apiKey.isEmpty {
            messages[idx].text = "还没填 API Key。点右上角齿轮，填入 DashScope（或任意 OpenAI 兼容）地址、模型名和密钥。"
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
