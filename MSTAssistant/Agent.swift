import Foundation
import UIKit

/// 自动循环：截屏 → 千问视觉决策 → 执行（点击/打开 App）→ 再截屏，直到 done 或步数用尽
@MainActor
final class AgentLoop: ObservableObject {
    @Published var running = false
    @Published var log: [String] = []
    @Published var task = ""

    private var stopRequested = false

    func note(_ s: String) {
        let t = DateFormatter()
        t.dateFormat = "HH:mm:ss"
        log.append("[\(t.string(from: Date()))] \(s)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    func stop() {
        stopRequested = true
        note("收到停止指令")
    }

    func start(task: String, config: ChatConfig, maxSteps: Int = 12) async {
        guard !running else { return }
        note("接口 \(config.endpoint) · 视觉模型 \(config.visionModel) · 密钥\(config.apiKey.isEmpty ? "未填（按自建服务处理）" : "已填")")
        running = true
        stopRequested = false
        note("开始：\(task)")
        note("注入能力 \(TouchInjector.probe().describe)")

        for step in 1...maxSteps {
            if stopRequested { break }
            guard let img = ScreenCapture.systemImage() else {
                note("第 \(step) 步：截屏失败")
                break
            }
            guard let b64 = ScreenCapture.jpegBase64(img) else {
                note("第 \(step) 步：图像编码失败")
                break
            }
            note("第 \(step) 步：已截屏 \(Int(img.size.width))x\(Int(img.size.height))")

            let decision: [String: Any]
            do {
                decision = try await ask(task: task, image: b64, config: config, step: step)
            } catch {
                note("第 \(step) 步：模型请求失败 \(error.localizedDescription)")
                break
            }

            let action = (decision["action"] as? String ?? "").lowercased()
            let reason = decision["reason"] as? String ?? ""
            if !reason.isEmpty { note("思考：\(reason)") }

            switch action {
            case "tap":
                let nx = decision["x"] as? Double ?? 500
                let ny = decision["y"] as? Double ?? 500
                let pt = ScreenGeometry.point(nx: nx, ny: ny)
                let ok = TouchInjector.tap(pt)
                note("点击 (\(Int(nx)),\(Int(ny))) 屏幕 \(Int(pt.x)),\(Int(pt.y)) → \(ok ? "已注入" : "注入失败")")
                if !ok { note("注入失败，说明这套权限还不足，先别继续"); stopRequested = true }
            case "open":
                let bid = decision["bundle"] as? String ?? ""
                let ok = AppLauncher.open(bundleID: bid)
                note("打开 \(bid) → \(ok ? "成功" : "失败")")
            case "done":
                note("完成：\(reason.isEmpty ? (decision["summary"] as? String ?? "任务结束") : reason)")
                stopRequested = true
            default:
                note("模型返回不可执行的动作：\(decision)")
                stopRequested = true
            }

            if stopRequested { break }
            try? await Task.sleep(nanoseconds: 900_000_000)
        }

        running = false
        note("循环结束")
    }

    private func ask(task: String, image: String, config: ChatConfig, step: Int) async throws -> [String: Any] {
        let resolved = QwenClient.resolve(config.endpoint)
        guard let url = URL(string: resolved) else { throw QwenError.badURL }

        let instruction = """
        你在操作一台 iPad，任务是：\(task)
        这是第 \(step) 步的屏幕截图。屏幕坐标用 0-1000 归一化，左上角是 (0,0)，右下角是 (1000,1000)。
        只输出一个 JSON 对象，不要任何解释文字。可用动作：
        {"action":"tap","x":数字,"y":数字,"reason":"为什么点这里"}
        {"action":"open","bundle":"Bundle ID","reason":"为什么打开它"}
        {"action":"done","summary":"结果"}
        如果界面上已经执行完，就用 done。
        """

        let body: [String: Any] = [
            "model": config.visionModel,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": instruction],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image)"]]
                ]
            ]],
            "stream": false
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 40
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw QwenError.http(code, "请求地址 \(resolved)\n" + (String(data: data, encoding: .utf8) ?? ""))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String else { throw QwenError.empty }

        return parseJSON(from: text)
    }

    private func parseJSON(from text: String) -> [String: Any] {
        var s = text
        if let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}") { s = String(s[a...b]) }
        if let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return o
        }
        return ["action": "unknown", "reason": "无法解析模型输出：\(text.prefix(120))"]
    }
}
