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
    /// 首选地址（兼容旧调用点）
    static func resolve(_ raw: String) -> String {
        candidates(raw).first ?? raw
    }

    /// 候选接口地址：按顺序试，404/405 自动换下一个。
    /// 覆盖 OpenAI(/v1)、火山方舟豆包(/api/v3)、vLLM 自定义、Ollama(/api/chat)
    static func candidates(_ raw: String) -> [String] {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return [] }
        if s.hasSuffix("/chat/completions") { return [s] }
        if s.contains("/api/chat") { return [s] }
        var base = s.hasSuffix("/") ? String(s.dropLast()) : s
        var out: [String] = []
        // 阿里云百炼/MaaS 工作空间：/compatible-mode/v1 是基址，必须再补 /chat/completions
        if base.contains("/compatible-mode") {
            if base.hasSuffix("/compatible-mode") { return [base + "/v1/chat/completions"] }
            if base.hasSuffix("/v1") { return [base + "/chat/completions"] }
            return [base + "/chat/completions", base + "/v1/chat/completions"]
        }
        if base.contains("aliyuncs.com") || base.contains("dashscope") || base.contains("maas") {
            out.append(base + "/compatible-mode/v1/chat/completions")
        }
        // 用户已写到版本段（/v1、/v3、/api/v3、/api）时只补 chat/completions
        let pathParts = base.components(separatedBy: "/")
        let looksVersioned = base.contains("/api/v") || base.contains("/compatible-mode")
            || (pathParts.last.map { $0.hasPrefix("v") && $0.dropFirst().allSatisfy { $0.isNumber } } ?? false)
        if looksVersioned { out.append(base + "/chat/completions") }
        out.append(base + "/v1/chat/completions")
        out.append(base + "/api/v3/chat/completions")
        out.append(base + "/api/chat")
        if !looksVersioned { out.insert(base, at: 1) }
        return Array(NSOrderedSet(array: out)) as? [String] ?? out
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
        var body: [String: Any] = ["model": config.model, "messages": msgs, "stream": false]
        config.applySampling(to: &body, isOllama: true)
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
        if config.activeProvider.isAnthropic || config.endpoint.contains("anthropic.com") {
            return try await chatAnthropic(config: config, history: history)
        }
        if isOllama(config.endpoint) { return try await chatOllama(config: config, history: history) }
        var tried: [String] = []
        var lastCode = 0
        var lastBody = ""
        for cand in candidates(config.endpoint) {
            tried.append(cand)
            guard let url = URL(string: cand) else { continue }
            var body: [String: Any] = [
                "model": config.model,
                "messages": messagesPayload(config: config, history: history),
                "stream": false
            ]
            if cand.contains("/api/chat") {
                body.removeValue(forKey: "messages")
                body["messages"] = messagesPayload(config: config, history: history)
                config.applySampling(to: &body, isOllama: true)
            } else {
                config.applySampling(to: &body, isOllama: false)
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 60
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !config.apiKey.isEmpty { req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                if cand.contains("/api/chat") {
                    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let msg = obj["message"] as? [String: Any],
                          let content = msg["content"] as? String else { throw QwenError.empty }
                    return content.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
                  let content = msg["content"] as? String else { throw QwenError.empty }
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            lastCode = code
            lastBody = String(data: data, encoding: .utf8) ?? ""
            // 401/403/429/5xx 说明地址是对的，不用再猜路径
            if code != 404 && code != 405 { break }
        }
        throw QwenError.http(lastCode, "试过的地址：\n" + tried.joined(separator: "\n") + "\n\n响应：" + String(lastBody.prefix(160)))
    }


    /// Anthropic Messages API：/v1/messages + x-api-key + anthropic-version，
    /// system 单独字段，messages 只能有 user/assistant
    static func chatAnthropic(config: ChatConfig, history: [ChatMessage]) async throws -> String {
        let raw = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        let urlStr: String
        if base.hasSuffix("/messages") {
            urlStr = base
        } else if base.hasSuffix("/v1") {
            urlStr = base + "/messages"
        } else if base.contains("/v1") {
            urlStr = base
        } else {
            urlStr = base + "/v1/messages"
        }
        guard let url = URL(string: urlStr) else { throw QwenError.badURL }

        var msgs: [[String: Any]] = []
        for m in history.suffix(20) where !m.text.isEmpty && !m.failed && m.role != .system {
            msgs.append(["role": m.role == .assistant ? "assistant" : "user",
                         "content": m.text])
        }
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": max(1, config.maxTokens),
            "messages": msgs,
            "temperature": config.temperature,
            "top_p": config.topP
        ]
        if !config.systemPrompt.isEmpty { body["system"] = config.systemPrompt }
        let e = config.extraJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty, let d = e.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in obj { body[k] = v }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !config.apiKey.isEmpty { req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw QwenError.http(code, "请求地址 \(urlStr)\n" + (String(data: data, encoding: .utf8) ?? ""))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = obj["content"] as? [[String: Any]] else { throw QwenError.empty }
        let text = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw QwenError.empty }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
