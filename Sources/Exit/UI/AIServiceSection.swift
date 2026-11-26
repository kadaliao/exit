import AppKit
import SwiftUI

/// Picks where AI generation runs: a CLI that's already signed in, or an API key for any provider.
struct AIServiceSection: View {
    @ObservedObject var settings = Settings.shared

    @State private var installed: [CLIAgent: String] = [:]
    @State private var scanned = false
    @State private var signedIn: [CLIAgent: Bool] = [:]
    @State private var apiKey = ""
    @State private var keyAccount = ""
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelsError: String?
    @State private var test: TestState = .idle
    @State private var testTask: Task<Void, Never>?

    enum TestState: Equatable { case idle, running, ok(String), failed(String) }

    private var provider: AIProvider { settings.aiProvider }

    var body: some View {
        Section {
            Picker(T("Use", "使用"), selection: providerBinding) {
                Section(T("Signed in on this Mac", "本机已登录的工具")) {
                    ForEach(CLIAgent.allCases) { a in
                        Text(cliLabel(a)).tag(AIProvider.cli(a).id)
                    }
                }
                Section(T("Your own API key", "自己的 API Key")) {
                    ForEach(APIPreset.all, id: \.id) { p in
                        Text(p.title).tag(AIProvider.api(p).id)
                    }
                }
            }

            switch provider {
            case .cli(let agent): cliDetails(agent)
            case .api(let preset): apiDetails(preset)
            }

            modelRow

            if provider.supportsEffort {
                Picker(T("Thinking", "思考强度"), selection: $settings.aiEffort) {
                    Text(T("Quick", "快速")).tag("low")
                    Text(T("Balanced", "均衡")).tag("medium")
                    Text(T("Best (slow)", "最佳（较慢）")).tag("high")
                }
            }

            testRow
        } header: {
            Text(T("AI service", "AI 服务"))
        }
        .task { await scan() }
        .onAppear { loadKey() }
        .onChange(of: settings.aiProviderID) { _, _ in
            loadKey()
            models = []
            modelsError = nil
            testTask?.cancel()
            test = .idle
        }
        .onChange(of: apiKey) { _, v in
            if !keyAccount.isEmpty, v != (Keychain.read(account: keyAccount) ?? "") { Keychain.write(v, account: keyAccount) }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func cliDetails(_ agent: CLIAgent) -> some View {
        LabeledContent(T("Location", "位置")) {
            if let path = installed[agent] {
                Text(path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            } else if scanned {
                HStack(spacing: 8) {
                    Text(T("Not installed", "未安装")).foregroundStyle(.red)
                    Link(T("Get \(agent.title)", "获取 \(agent.title)"), destination: agent.homepage)
                    Button(T("Look again", "重新查找")) { Task { await scan(refresh: true) } }
                }
                .font(.callout)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        if installed[agent] != nil, let ok = signedIn[agent] {
            LabeledContent(T("Account", "账号")) {
                if ok {
                    Label(T("Signed in", "已登录"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                } else {
                    Text(T("Not signed in. Run `\(agent.loginCommand)` in Terminal.", "还没登录，请在终端运行 `\(agent.loginCommand)`。"))
                        .foregroundStyle(.orange).font(.callout).textSelection(.enabled)
                }
            }
        }
        Text(agent.howItRuns).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func apiDetails(_ preset: APIPreset) -> some View {
        TextField(T("Base URL", "Base URL"), text: baseURLBinding, prompt: Text(preset.baseURLPlaceholder))
        SecureField(T("API key", "API Key"), text: $apiKey,
                    prompt: Text(preset.format == .openai && preset.isCustom ? T("Optional for local servers", "本地服务可不填") : ""))
        let host = URL(string: settings.aiBaseURL(for: provider))?.host
        Text(host.map { T("The key is stored in your login Keychain. Requests go straight to \($0).", "Key 保存在登录钥匙串里，请求直接发往 \($0)。") }
             ?? T("The key is stored in your login Keychain.", "Key 保存在登录钥匙串里。"))
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var modelRow: some View {
        TextField(T("Model", "模型"), text: modelBinding, prompt: Text(modelPlaceholder))
        if case .api = provider {
            HStack(spacing: 8) {
                if let modelsError {
                    Text(modelsError).font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                if loadingModels { ProgressView().controlSize(.small) }
                if !models.isEmpty {
                    Menu(T("Choose from \(models.count) models", "从 \(models.count) 个模型中选")) {
                        ForEach(models, id: \.self) { m in
                            Button(m) { settings.aiModels[provider.id] = m }
                        }
                    }
                    .fixedSize()
                }
                Button(models.isEmpty ? T("Load model list", "获取模型列表") : T("Reload", "刷新")) { loadModels() }
                    .disabled(loadingModels)
            }
        }
    }

    private var testRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(T("Test", "测试")) { runTest() }
                .disabled(test == .running)
            switch test {
            case .idle:
                Text(T("Sends a one-word request to check the setup.", "发一个很短的请求，检查能否正常调用。"))
                    .font(.caption).foregroundStyle(.secondary)
            case .running:
                ProgressView().controlSize(.small)
                Text(T("Waiting for a reply…", "等待回复…")).font(.caption).foregroundStyle(.secondary)
            case .ok(let msg):
                Label(msg, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
            case .failed(let msg):
                Text(msg).font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
            }
            Spacer()
        }
    }

    // MARK: Bindings

    private var providerBinding: Binding<String> {
        Binding(get: { settings.aiProviderID },
                set: { if let p = AIProvider(id: $0) { settings.aiProvider = p } })
    }

    private var modelBinding: Binding<String> {
        Binding(get: { settings.aiModels[provider.id] ?? provider.defaultModel },
                set: { settings.aiModels[provider.id] = $0 })
    }

    private var baseURLBinding: Binding<String> {
        Binding(get: { settings.aiBaseURLs[provider.id] ?? settings.aiBaseURL(for: provider) },
                set: { settings.aiBaseURLs[provider.id] = $0 })
    }

    private var modelPlaceholder: String {
        switch provider {
        case .cli(let a): a.modelPlaceholder
        case .api(let p): p.defaultModel.isEmpty ? T("Required. Type it or load the list below.", "必填，可直接输入或在下面获取列表。") : p.defaultModel
        }
    }

    private func cliLabel(_ a: CLIAgent) -> String {
        guard scanned, installed[a] == nil else { return a.title }
        return a.title + T(" (not installed)", "（未安装）")
    }

    // MARK: Actions

    private func loadKey() {
        guard case .api(let preset) = provider else { keyAccount = ""; apiKey = ""; return }
        keyAccount = Keychain.apiKeyAccount(preset.id)
        apiKey = Keychain.read(account: keyAccount) ?? ""
    }

    private func scan(refresh: Bool = false) async {
        let found = await Task.detached { () -> [CLIAgent: String] in
            if refresh { CLILocator.refresh() }
            var result: [CLIAgent: String] = [:]
            for a in CLIAgent.allCases { result[a] = CLILocator.locate(a)?.path }
            return result
        }.value
        installed = found
        scanned = true
        // First run: if the default CLI isn't here, start with one that is.
        if !settings.hasChosenAIProvider, case .cli(let current) = provider, found[current] == nil,
           let first = CLIAgent.allCases.first(where: { found[$0] != nil }) {
            settings.aiProviderID = AIProvider.cli(first).id
        }
        for a in CLIAgent.allCases where found[a] != nil && a.statusArguments != nil {
            signedIn[a] = await CLILocator.isSignedIn(a)
        }
    }

    private func loadModels() {
        let p = provider
        let key = apiKey, base = settings.aiBaseURL(for: p)
        loadingModels = true
        modelsError = nil
        Task {
            do {
                let list = try await AIService.listModels(for: p, apiKey: key, baseURL: base)
                guard p == provider else { return }
                models = list
                if list.isEmpty { modelsError = T("The service returned no models.", "服务没有返回任何模型。") }
            } catch {
                if p == provider { modelsError = error.localizedDescription }
            }
            loadingModels = false
        }
    }

    private func runTest() {
        let p = provider
        test = .running
        testTask = Task {
            let start = Date()
            do {
                if case .cli(let a) = p { _ = await Task.detached { CLILocator.locate(a) }.value }
                let reply = try await AIService.ping(p)
                guard !Task.isCancelled else { return }
                let secs = String(format: "%.1f", Date().timeIntervalSince(start))
                test = .ok(T("Works. Replied “\(reply.prefix(40))” in \(secs) s.", "可以用，\(secs) 秒后回复了“\(reply.prefix(40))”。"))
            } catch {
                guard !Task.isCancelled else { return }
                test = .failed(error.localizedDescription)
            }
        }
    }
}
