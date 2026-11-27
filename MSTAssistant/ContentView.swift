import SwiftUI

struct ContentView: View {
    @StateObject private var store = ChatStore()
    @State private var input = ""
    @State private var showSettings = false
    @State private var cleanResult = ""

    var body: some View {
        NavigationView {
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

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("千问接口（OpenAI 兼容）")) {
                    TextField("接口地址", text: $config.endpoint)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("模型名，如 qwen-plus", text: $config.model)
                        .autocapitalization(.none)
                    SecureField("API Key", text: $config.apiKey)
                }
                Section(header: Text("系统提示词")) {
                    TextEditor(text: $config.systemPrompt).frame(minHeight: 90)
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
