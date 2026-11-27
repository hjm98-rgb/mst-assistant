import Foundation

enum QwenError: LocalizedError {
    case badURL, http(Int, String), empty

    var errorDescription: String? {
        switch self {
        case .badURL: return "接口地址不合法"
        case let .http(code, body): return "HTTP \(code)：\(body.prefix(200))"
        case .empty: return "模型返回为空"
        }
    }
}

enum QwenClient {
    /// 把用户填的地址补成真实接口地址：
    /// - 根地址 → +/v1/chat/completions
    /// - 以 /v1 结尾 → +/chat/completions
    /// - Ollama(/api/chat 或 11434) → 原样
    static func resolve(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        if isOllama(s) { return s }
        if s.hasSuffix("/chat/completions") { return s }
        if s.hasSuffix("/v1") { return s + "/chat/completions" }
        if s.hasSuffix("/v1/") { return s + "chat/completions" }
        if let u = URL(string: s) {
            let path = u.path
            if path.isEmpty || path == "/" {
                return s.hasSuffix("/") ? s + "v1/chat/completions" : s + "/v1/chat/completions"
            }
        }
        return s
    }

    static func isOllama(_ endpoint: String) -> Bool {
        endpoint.contains("/api/chat") || endpoint.contains(":11434")
    }

    /// Ollama 原生 /api/chat：本地开源权重，不需要密钥
    static func chatOllama(config: ChatConfig, history: [ChatMessage]) async throws -> String {
        guard let url = URL(string: config.endpoint) else { throw QwenError.badURL }
        var msgs: [[String: Any]] = []
        if !config.systemPrompt.isEmpty { msgs.append(["role": "system", "content": config.systemPrompt]) }
        for m in history.suffix(20) where !m.text.isEmpty && !m.failed {
            msgs.append(["role": m.role.rawValue, "content": m.text])
        }
        let body: [String: Any] = ["model": config.model, "messages": msgs, "stream": false]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw QwenError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["message"] as? [String: Any],
              let content = msg["content"] as? String else { throw QwenError.empty }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// OpenAI 兼容 /chat/completions（vLLM 自托管、DashScope 托管都走这套）
    static func chat(config: ChatConfig, history: [ChatMessage]) async throws -> String {
        if isOllama(config.endpoint) { return try await chatOllama(config: config, history: history) }
        let resolved = resolve(config.endpoint)
        guard let url = URL(string: resolved) else { throw QwenError.badURL }

        var body: [String: Any] = [
            "model": config.model,
            "messages": messagesPayload(config: config, history: history),
            "stream": false
        ]
        // DashScope 兼容模式接受 temperature；给个温和值
        body["temperature"] = 0.4

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw QwenError.http(code, String(data: data, encoding: .utf8) ?? "")
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw QwenError.empty
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func messagesPayload(config: ChatConfig, history: [ChatMessage]) -> [[String: Any]] {
        var arr: [[String: Any]] = []
        if !config.systemPrompt.isEmpty {
            arr.append(["role": "system", "content": config.systemPrompt])
        }
        // 只带最近 20 轮，避免上下文过长
        for m in history.suffix(20) where !m.text.isEmpty && !m.failed {
            arr.append(["role": m.role.rawValue, "content": m.text])
        }
        return arr
    }
}
