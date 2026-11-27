import SwiftUI

struct ContentView: View {
    @StateObject private var store = ChatStore()
    @State private var input = ""
    @State private var showSettings = false
    @State private var cleanResult = ""
    @State private var showAgent = false
    @StateObject private var agent = AgentLoop()

    var body: some View {
        let _ = Breadcrumb.mark("body build")
        return NavigationView {
            VStack(spacing: 0) {
                Text(store.statusLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.messages) { m in
                                MessageBubble(message: m).id(m.id)
                            }
                            if store.busy {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.7)
                                    Text("千问正在回答…").font(.footnote).foregroundColor(.secondary)
                                    Spacer()
                                }.padding(.horizontal, 14)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: store.messages.count) { _ in
                        if let last = store.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                Divider()

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("说点什么，或让它干活…", text: $input)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let text = input
                        input = ""
                        Task { await store.send(text) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(store.busy)
                }
                .padding(10)
            }
            .navigationTitle("MST 助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button("自动操作（看屏·点击）") { showAgent = true }
                        Button("触摸注入自测") {
                            Breadcrumb.mark("tap-test start")
                            let probe = TouchInjector.probe()
                            let ok = TouchInjector.tap(ScreenGeometry.point(nx: 500, ny: 500))
                            Breadcrumb.mark("tap-test probe=\(probe.describe) result=\(ok)")
                            cleanResult = "能力：\(probe.describe)\n屏幕中心注入：\(ok ? "已发出" : "失败")\n\n上一步记录：\n\(Breadcrumb.read().suffix(300))"
                        }
                        Button("清理白色巨魔残留") {
                            cleanResult = Cleaner.cleanStaleTrollStore()
                        }
                        Button("打开「设置」") {
                            _ = AppLauncher.open(bundleID: "com.apple.Preferences")
                        }
                        Button("清空对话记录", role: .destructive) {
                            store.clearHistory()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showAgent) {
                AgentView(agent: agent, config: store.config)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(config: $store.config) { store.save() }
            }
            .alert("清理结果", isPresented: Binding(get: { !cleanResult.isEmpty }, set: { if !$0 { cleanResult = "" } })) {
                Button("好", role: .cancel) { cleanResult = "" }
            } message: {
                Text(cleanResult)
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text.isEmpty ? "…" : message.text)
                .font(.system(size: 15))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(bg)
                .foregroundColor(message.role == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if message.role != .user { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 12)
    }

    private var bg: Color {
        if message.failed { return Color.red.opacity(0.12) }
        return message.role == .user ? Color.accentColor : Color(white: 0.5).opacity(0.16)
    }
}

struct SettingsView: View {
    @Binding var config: ChatConfig
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var current: Provider { config.activeProvider }

    var body: some View {
        let _ = Breadcrumb.mark("body build")
        return NavigationView {
            Form {
                Section(header: Text("服务商（点一下自动填地址和模型）"),
                        footer: Text("密钥只存在本机 Documents/mst/config.json，不上传。")) {
                    ForEach(Provider.allCases) { p in
                        Button {
                            config.use(p)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.title).foregroundColor(.primary)
                                    if !p.endpoint.isEmpty {
                                        Text(p.endpoint).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if current == p {
                                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }

                Section(header: Text("当前配置")) {
                    TextField("接口地址", text: $config.endpoint)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(size: 13))
                    TextField("对话模型", text: $config.model)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("视觉模型（可留空）", text: $config.visionModel)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField(current.keyHint, text: $config.apiKey)
                }

                Section(header: Text("系统提示词")) {
                    TextEditor(text: $config.systemPrompt).frame(minHeight: 90)
                }

                Section(header: Text("采样参数"),
                        footer: Text("各家支持的字段不同；多出来的键（top_k、enable_thinking、repetition_penalty、seed）写进下方额外参数，会原样合并进请求体。")) {
                    HStack {
                        Text("温度 temperature")
                        Spacer()
                        Text(String(format: "%.2f", config.temperature)).foregroundColor(.secondary)
                    }
                    Slider(value: $config.temperature, in: 0...2, step: 0.05)
                    HStack {
                        Text("top_p")
                        Spacer()
                        Text(String(format: "%.2f", config.topP)).foregroundColor(.secondary)
                    }
                    Slider(value: $config.topP, in: 0...1, step: 0.01)
                    HStack {
                        Text("最大输出 tokens")
                        Spacer()
                        TextField("512", value: $config.maxTokens, formatter: NumberFormatter())
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    Stepper("presence_penalty  \(String(format: "%.2f", config.presencePenalty))", value: $config.presencePenalty, in: -2...2, step: 0.1)
                    Stepper("frequency_penalty  \(String(format: "%.2f", config.frequencyPenalty))", value: $config.frequencyPenalty, in: -2...2, step: 0.1)
                }

                Section(header: Text("额外参数（JSON，可留空）")) {
                    TextEditor(text: $config.extraJSON)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 60)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section(footer: Text("数据全部存在本机 Documents/mst/，不上传第三方。")) {
                    Button("保存") { onSave(); dismiss() }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .navigationViewStyle(.stack)
    }
}


struct AgentView: View {
    @ObservedObject var agent: AgentLoop
    let config: ChatConfig
    @State private var task = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = Breadcrumb.mark("body build")
        return NavigationView {
            VStack(spacing: 10) {
                HStack {
                    TextField("让它做什么，例如：打开设置并进入通用", text: $task)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await agent.start(task: task, config: config) }
                    } label: {
                        Label("开始", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(agent.running || task.isEmpty)

                    Button {
                        agent.stop()
                    } label: {
                        Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!agent.running)
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(agent.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .navigationTitle("自动操作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空日志") { agent.log.removeAll() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
