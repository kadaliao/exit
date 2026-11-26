import AppKit
import SwiftUI

struct AIPane: View {
    @ObservedObject var settings = Settings.shared
    @StateObject private var generator = EffectGenerator()
    @State private var prompt = ""
    @State private var forOpen = false
    @State private var apiKey = Keychain.read() ?? ""
    @State private var showCode = false
    @State private var cliPath: String?

    private let ideas: [String] = Lang.isChinese
        ? ["窗口像气球一样被戳破，碎片和彩带四散", "像一滴墨落进水里，晕开后消失", "黑客帝国式的绿色代码雨把窗口冲走",
           "窗口被折成纸飞机飞出屏幕", "像老式胶片烧穿，边缘卷曲发光", "被一圈圈涟漪荡开，最后归于平静"]
        : ["The window pops like a balloon, scraps and streamers flying", "Ink dropped in water: it blooms and dissolves",
           "Matrix-style green code rain washes it away", "Folds into a paper plane and flies off-screen",
           "Old film burning through, edges curling and glowing", "Rippled away by expanding rings until calm"]

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(T("Describe the effect you want", "描述你想要的效果")).font(.headline)
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(minHeight: 70, maxHeight: 110)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(ideas, id: \.self) { idea in
                                Button(idea) { prompt = idea }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    HStack {
                        Picker("", selection: $forOpen) {
                            Text(T("For closing / quitting", "用于关闭 / 退出")).tag(false)
                            Text(T("For opening (decorates)", "用于打开（装饰）")).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360)
                        Spacer()
                        if generator.isWorking {
                            Text(T("Usually takes a few minutes", "通常需要几分钟"))
                                .font(.caption).foregroundStyle(.secondary)
                            ProgressView().controlSize(.small)
                            Button(T("Cancel", "取消")) { generator.cancel() }
                        } else {
                            Button {
                                generator.generate(description: prompt, events: forOpen ? [.open] : [.close, .quit, .minimize])
                            } label: {
                                Label(T("Generate", "生成"), systemImage: "wand.and.stars")
                            }
                            .keyboardShortcut(.return, modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }

            if !generator.steps.isEmpty || generator.errorText != nil {
                Section(T("Progress", "进度")) {
                    ForEach(generator.steps) { step in
                        HStack(alignment: .top) {
                            Group {
                                switch step.ok {
                                case .some(true): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                case .some(false): Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                                case .none: ProgressView().controlSize(.mini)
                                }
                            }
                            .frame(width: 18)
                            Text(step.text).font(.callout).textSelection(.enabled)
                        }
                    }
                    if let err = generator.errorText {
                        Text(err).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let id = generator.savedEffectID, let effect = EffectLibrary.shared.effect(id: id) {
                        GeneratedResult(effect: effect, forOpen: forOpen)
                    }
                    if !generator.source.isEmpty {
                        DisclosureGroup(T("Shader source", "着色器源码"), isExpanded: $showCode) {
                            ScrollView {
                                Text(generator.source).font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 260)
                        }
                    }
                }
            }

            Section(T("Claude", "Claude")) {
                Picker(T("Use", "调用方式"), selection: $settings.aiProvider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }
                if settings.aiProvider == .api {
                    SecureField(T("API key", "API Key"), text: $apiKey)
                        .onSubmit { Keychain.write(apiKey) }
                        .onChange(of: apiKey) { _, v in Keychain.write(v) }
                    Text(T("Stored in your login Keychain. Requests go straight to api.anthropic.com.",
                           "保存在登录钥匙串里，请求直接发往 api.anthropic.com。"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent(T("Claude Code", "Claude Code")) {
                        Text(cliPath ?? T("not found — install Claude Code or use an API key", "未找到——请安装 Claude Code 或改用 API Key"))
                            .foregroundStyle(cliPath == nil ? .red : .secondary)
                            .font(.callout)
                    }
                    Text(T("Runs `claude -p` with all tools disabled, using your existing Claude Code login.",
                           "以禁用全部工具的方式运行 `claude -p`，使用你已经登录的 Claude Code 账号。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField(T("Model", "模型"), text: $settings.aiModel)
                Picker(T("Thinking", "思考强度"), selection: $settings.aiEffort) {
                    Text(T("Quick", "快速")).tag("low")
                    Text(T("Balanced", "均衡")).tag("medium")
                    Text(T("Best (slow)", "最佳（较慢）")).tag("high")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            let path = await Task.detached { ClaudeCodeBackend.locate()?.path }.value
            cliPath = path
        }
    }
}

struct GeneratedResult: View {
    @ObservedObject var effect: Effect
    let forOpen: Bool

    var body: some View {
        HStack(spacing: 14) {
            EffectThumbnail(effect: effect)
                .frame(width: 200, height: 125)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(effect.meta.displayName).font(.title3.bold())
                if let d = effect.meta.displayDescription { Text(d).foregroundStyle(.secondary) }
                HStack {
                    Button { ExitEngine.shared.preview(effect) } label: { Label(T("Play", "播放"), systemImage: "play.fill") }
                    Button {
                        let s = Settings.shared
                        if forOpen { s.assignments[.open] = .effect(effect.id) } else { s.assignments[.close] = .effect(effect.id) }
                    } label: {
                        Label(forOpen ? T("Use for opening", "设为打开特效") : T("Use for closing", "设为关闭特效"), systemImage: "checkmark")
                    }
                    Button { NSWorkspace.shared.open(effect.url) } label: { Label(T("Edit", "编辑"), systemImage: "pencil") }
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}
