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
    /// OpenAI 兼容 /chat/completions（DashScope 千问、vLLM 自托管都走这套）
    static func chat(config: ChatConfig, history: [ChatMessage]) async throws -> String {
        guard let url = URL(string: config.endpoint) else { throw QwenError.badURL }

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
