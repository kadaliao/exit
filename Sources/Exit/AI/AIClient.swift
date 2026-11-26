import Foundation
import Security

struct ChatMessage {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
}

enum AIError: LocalizedError {
    case noAPIKey(String)
    case noBaseURL
    case noModel
    case cliNotFound(CLIAgent)
    case refused(String?)
    case http(Int, String)
    case process(String)
    case emptyReply
    case truncated

    var errorDescription: String? {
        switch self {
        case .noAPIKey(let p): T("No API key for \(p) yet. Add one in Settings → Create with AI.", "还没有填写 \(p) 的 API Key，请在 设置 → AI 生成 里填写。")
        case .noBaseURL: T("Enter the service's base URL in Settings → Create with AI.", "请在 设置 → AI 生成 里填写服务的 Base URL。")
        case .noModel: T("Choose a model in Settings → Create with AI.", "请在 设置 → AI 生成 里选择模型。")
        case .cliNotFound(let a): T("\(a.title) (`\(a.command)`) was not found. Install it or pick another service.", "没找到 \(a.title)（`\(a.command)`），请先安装，或换一个服务。")
        case .refused(let why): T("The model declined this request.", "模型拒绝了这个请求。") + (why.map { " (\($0))" } ?? "")
        case .http(let code, let body): "HTTP \(code): \(body.prefix(400))"
        case .process(let msg): msg
        case .emptyReply: T("The model returned an empty reply.", "模型返回了空回复。")
        case .truncated: T("The reply was cut off by the output limit.", "回复超出输出上限，被截断了。")
        }
    }
}

/// Sends one conversation to a model and returns its text reply.
protocol AIBackend {
    func send(system: String, messages: [ChatMessage], model: String, effort: String) async throws -> String
}

enum AIService {
    /// Builds the backend for a provider from the saved settings.
    /// `apiKey` / `baseURL` override the saved ones (used by the `--ai-ping` dev tool).
    static func backend(for provider: AIProvider, settings: Settings = .shared,
                        apiKey: String? = nil, baseURL: String? = nil) throws -> AIBackend {
        switch provider {
        case .cli(let agent):
            guard let exe = CLILocator.locate(agent) else { throw AIError.cliNotFound(agent) }
            return CLIBackend(agent: agent, executable: exe)
        case .api(let preset):
            let base = baseURL ?? settings.aiBaseURL(for: provider)
            guard !base.isEmpty else { throw AIError.noBaseURL }
            let key = apiKey ?? Keychain.read(account: Keychain.apiKeyAccount(preset.id)) ?? ""
            // Local OpenAI-compatible servers (Ollama, LM Studio) don't need a key.
            if key.isEmpty && !(preset.format == .openai && isLocal(base)) { throw AIError.noAPIKey(preset.title) }
            switch preset.format {
            case .anthropic: return AnthropicBackend(apiKey: key, baseURL: base)
            case .openai: return OpenAIBackend(apiKey: key, baseURL: base)
            }
        }
    }

    /// The model to request: the saved one, or the provider's default. Empty means the CLI's own default.
    static func model(for provider: AIProvider, settings: Settings = .shared) throws -> String {
        let m = settings.aiModel(for: provider).trimmingCharacters(in: .whitespaces)
        if m.isEmpty, case .api = provider { throw AIError.noModel }
        return m
    }

    /// Lists model IDs for an API provider.
    static func listModels(for provider: AIProvider, apiKey: String, baseURL: String) async throws -> [String] {
        guard case .api(let preset) = provider else { return [] }
        guard !baseURL.isEmpty else { throw AIError.noBaseURL }
        var req: URLRequest
        switch preset.format {
        case .anthropic:
            req = URLRequest(url: try AnthropicBackend.url(baseURL, path: "models?limit=1000"))
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue(AnthropicBackend.version(for: baseURL), forHTTPHeaderField: "anthropic-version")
            if !AnthropicBackend.isOfficial(baseURL) { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        case .openai:
            req = URLRequest(url: try OpenAIBackend.url(baseURL, path: "models"))
            if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        }
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            throw AIError.process(T("This service doesn't offer a model list. Type the model name instead.",
                                    "这个服务不提供模型列表，请直接输入模型名称。"))
        }
        guard status == 200 else { throw AIError.http(status, String(data: data, encoding: .utf8) ?? "") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let ids = (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return ids.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Sends a tiny request to check that the provider answers.
    static func ping(_ provider: AIProvider, apiKey: String? = nil, baseURL: String? = nil,
                     model: String? = nil) async throws -> String {
        let backend = try backend(for: provider, apiKey: apiKey, baseURL: baseURL)
        let model = try model ?? Self.model(for: provider)
        let reply = try await backend.send(system: "You are a connectivity check. Reply with the single word OK.",
                                           messages: [ChatMessage(role: .user, text: "Reply with OK.")],
                                           model: model, effort: provider.supportsEffort ? "low" : "")
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isLocal(_ base: String) -> Bool {
        guard let host = URL(string: base)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }
}

// MARK: - Anthropic Messages API (and compatible endpoints)

/// Messages API over HTTPS. On api.anthropic.com it also uses adaptive thinking, effort and
/// server-side refusal fallbacks; compatible third-party endpoints get a plain request.
struct AnthropicBackend: AIBackend {
    let apiKey: String
    let baseURL: String

    static func isOfficial(_ base: String) -> Bool { URL(string: base)?.host?.lowercased() == "api.anthropic.com" }
    static func version(for base: String) -> String { isOfficial(base) ? "2026-10-21" : "2023-06-01" }

    /// Accepts `https://host`, `https://host/v1` or the full `…/v1/messages` URL.
    static func url(_ base: String, path: String) throws -> URL {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/messages") { b.removeLast("/messages".count) }
        if !b.hasSuffix("/v1") { b += "/v1" }
        guard let url = URL(string: "\(b)/\(path)") else { throw AIError.noBaseURL }
        return url
    }

    func send(system: String, messages: [ChatMessage], model: String, effort: String) async throws -> String {
        let official = Self.isOfficial(baseURL)
        var req = URLRequest(url: try Self.url(baseURL, path: "messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.version(for: baseURL), forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        if official {
            // Server-side fallback: if a safety classifier declines, the API retries on its
            // recommended fallback model within the same call.
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["thinking"] = ["type": "adaptive"]
            if !effort.isEmpty { body["output_config"] = ["effort": effort] }
            if !model.hasPrefix("claude-haiku") { body["fallbacks"] = "default" }
        } else {
            // Some compatible gateways only read a bearer token.
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AIError.http(status, String(data: data, encoding: .utf8) ?? "") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.emptyReply }
        if json["stop_reason"] as? String == "refusal" {
            let details = json["stop_details"] as? [String: Any]
            throw AIError.refused(details?["category"] as? String)
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            throw json["stop_reason"] as? String == "max_tokens" ? AIError.truncated : AIError.emptyReply
        }
        return text
    }
}

// MARK: - OpenAI-compatible Chat Completions

/// Chat Completions, as spoken by OpenAI, Gemini, OpenRouter, DeepSeek, Ollama and most others.
struct OpenAIBackend: AIBackend {
    let apiKey: String
    let baseURL: String

    /// Accepts the base URL (`…/v1`) or the full `…/chat/completions` URL.
    static func url(_ base: String, path: String) throws -> URL {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/chat/completions") { b.removeLast("/chat/completions".count) }
        guard let url = URL(string: "\(b)/\(path)") else { throw AIError.noBaseURL }
        return url
    }

    func send(system: String, messages: [ChatMessage], model: String, effort: String) async throws -> String {
        do {
            return try await request(system: system, messages: messages, model: model, effort: effort)
        } catch AIError.http(let code, _) where !effort.isEmpty && (code == 400 || code == 422) {
            // Not every model or gateway accepts `reasoning_effort`; try once without it.
            return try await request(system: system, messages: messages, model: model, effort: "")
        }
    }

    private func request(system: String, messages: [ChatMessage], model: String, effort: String) async throws -> String {
        var req = URLRequest(url: try Self.url(baseURL, path: "chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system]]
                + messages.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        if !effort.isEmpty { body["reasoning_effort"] = effort }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AIError.http(status, String(data: data, encoding: .utf8) ?? "") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first else { throw AIError.emptyReply }
        let message = choice["message"] as? [String: Any]
        if let refusal = message?["refusal"] as? String, !refusal.isEmpty { throw AIError.refused(refusal) }
        var text = ""
        if let s = message?["content"] as? String {
            text = s
        } else if let parts = message?["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined()
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw choice["finish_reason"] as? String == "length" ? AIError.truncated : AIError.emptyReply
        }
        return text
    }
}

// MARK: - Signed-in CLIs

/// Runs a coding-agent CLI once, non-interactively, in an empty temporary folder.
struct CLIBackend: AIBackend {
    let agent: CLIAgent
    let executable: URL

    func send(system: String, messages: [ChatMessage], model: String, effort: String) async throws -> String {
        let conversation = Self.fold(messages)
        // CLIs without a system-prompt flag get the instructions at the top of the prompt.
        let combined = "<instructions>\n\(system)\n</instructions>\n\n\(conversation)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exit-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var args: [String] = []
        var input = ""
        var env: [String: String] = [:]
        var replyFile: URL?
        switch agent {
        case .claude:
            args = ["-p", "--output-format", "text", "--tools", "", "--no-session-persistence",
                    "--strict-mcp-config", "--system-prompt", system]
            if !model.isEmpty { args += ["--model", model] }
            if !effort.isEmpty { args += ["--effort", effort] }
            input = conversation
        case .codex:
            let out = dir.appendingPathComponent("reply.md")
            replyFile = out
            args = ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--color", "never",
                    "--output-last-message", out.path]
            if !model.isEmpty { args += ["--model", model] }
            if !effort.isEmpty { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
            args.append("-")   // prompt from stdin
            input = combined
        case .gemini:
            if !model.isEmpty { args += ["--model", model] }
            input = combined
        case .opencode:
            args = ["run", "--agent", "plan"]
            if !model.isEmpty { args += ["--model", model] }
            args.append(combined)
            env["OPENCODE_CONFIG_CONTENT"] = #"{"permission":{"edit":"deny","bash":"deny","webfetch":"deny"}}"#
        case .pi:
            args = ["-p", "--no-tools", "--no-session", "--no-skills", "--no-context-files", "--no-prompt-templates",
                    "--no-mcp", "--system-prompt", system]
            if !model.isEmpty { args += ["--model", model] }
            if !effort.isEmpty { args += ["--thinking", effort] }
            input = conversation
        }

        let result = try await ProcessRunner.run(executable, args, input: input, directory: dir, extraEnv: env)
        var out = result.stdout
        if let replyFile, let s = try? String(contentsOf: replyFile, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out = s
        }
        out = Self.stripANSI(out)
        guard result.status == 0, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let err = Self.stripANSI(result.stderr)
            throw AIError.process("\(agent.command) exited \(result.status): \((err.isEmpty ? out : err).suffix(600))")
        }
        return out
    }

    /// The CLIs are single-turn here, so earlier turns are folded into one prompt.
    static func fold(_ messages: [ChatMessage]) -> String {
        if messages.count == 1 { return messages[0].text }
        var prompt = ""
        for m in messages {
            prompt += m.role == .user ? "<user>\n\(m.text)\n</user>\n\n" : "<assistant>\n\(m.text)\n</assistant>\n\n"
        }
        return prompt + "Reply to the last <user> message."
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}

/// Finds CLIs in the usual install folders, then through the user's login shell.
enum CLILocator {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [CLIAgent: URL] = [:]
    nonisolated(unsafe) private static var shellScanned = false

    static func locate(_ agent: CLIAgent) -> URL? {
        if let hit = lock.withLock({ cache[agent] }), FileManager.default.isExecutableFile(atPath: hit.path) { return hit }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["\(home)/.local/bin", "\(home)/.opencode/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
                    "\(home)/.local/share/fnm/aliases/default/bin",
                    "\(home)/Library/Application Support/fnm/aliases/default/bin",
                    "\(home)/.volta/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        if agent == .claude { dirs.insert("\(home)/.claude/local", at: 1) }
        for d in dirs {
            let p = "\(d)/\(agent.command)"
            if FileManager.default.isExecutableFile(atPath: p) {
                let url = URL(fileURLWithPath: p)
                lock.withLock { cache[agent] = url }
                return url
            }
        }
        scanLoginShell()
        return lock.withLock { cache[agent] }
    }

    /// Clears the cache so newly installed CLIs show up.
    static func refresh() {
        lock.withLock { cache = [:]; shellScanned = false }
    }

    /// Asks the login shell (which knows about nvm, fnm, asdf…) where every CLI lives, once.
    private static func scanLoginShell() {
        guard lock.withLock({ !shellScanned }) else { return }
        defer { lock.withLock { shellScanned = true } }
        let shell = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let names = CLIAgent.allCases.map(\.command).joined(separator: " ")
        let isFish = shell.hasSuffix("/fish")
        let script = isFish ? "for c in \(names); command -v $c; end" : "for c in \(names); do command -v $c; done"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        // -i so zsh/bash read the rc files where version managers usually hook in.
        p.arguments = isFish ? ["-l", "-c", script] : ["-l", "-i", "-c", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let lines = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        lock.withLock {
            for line in lines where line.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: line) {
                let url = URL(fileURLWithPath: line)
                if let agent = CLIAgent.allCases.first(where: { $0.command == url.lastPathComponent }), cache[agent] == nil {
                    cache[agent] = url
                }
            }
        }
    }

    /// true / false when the CLI can tell whether it's signed in, nil when it can't.
    static func isSignedIn(_ agent: CLIAgent) async -> Bool? {
        guard let args = agent.statusArguments, let exe = locate(agent) else { return nil }
        let dir = FileManager.default.temporaryDirectory
        guard let r = try? await ProcessRunner.run(exe, args, input: "", directory: dir, timeout: 15) else { return nil }
        return r.status == 0
    }
}

enum ProcessRunner {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs a program, feeding `input` on stdin. Cancelling the task terminates the process.
    static func run(_ exe: URL, _ args: [String], input: String, directory: URL,
                    extraEnv: [String: String] = [:], timeout: TimeInterval? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // GUI apps get a bare PATH; put the CLI's own folder first so `#!/usr/bin/env node` finds its node.
        env["PATH"] = [exe.deletingLastPathComponent().path, "\(home)/.local/bin", "/opt/homebrew/bin",
                       "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        env["NO_COLOR"] = "1"
        for (k, v) in extraEnv { env[k] = v }
        process.environment = env
        process.currentDirectoryURL = directory

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
                let outBuf = DataBox(), errBuf = DataBox()
                let group = DispatchGroup()
                group.enter(); group.enter()
                stdout.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil; group.leave() } else { outBuf.append(d) }
                }
                stderr.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil; group.leave() } else { errBuf.append(d) }
                }
                process.terminationHandler = { p in
                    group.notify(queue: .global()) {
                        cont.resume(returning: Result(status: p.terminationStatus,
                                                      stdout: String(data: outBuf.data, encoding: .utf8) ?? "",
                                                      stderr: String(data: errBuf.data, encoding: .utf8) ?? ""))
                    }
                }
                do {
                    try process.run()
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: AIError.process(error.localizedDescription))
                    return
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
                }
                // Write from a background queue: a large prompt can fill the pipe before the CLI reads it.
                let data = Data(input.utf8)
                DispatchQueue.global().async {
                    if !data.isEmpty { try? stdin.fileHandleForWriting.write(contentsOf: data) }
                    try? stdin.fileHandleForWriting.close()
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ d: Data) { lock.withLock { storage.append(d) } }
    var data: Data { lock.withLock { storage } }
}

/// Minimal Keychain wrapper for API keys, one item per service.
enum Keychain {
    private static let service = "io.github.kadaliao.Exit"

    /// The Anthropic key keeps its original account name so existing keys carry over.
    static func apiKeyAccount(_ presetID: String) -> String {
        presetID == "anthropic" ? "anthropic-api-key" : "api-key.\(presetID)"
    }

    static func read(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = value.data(using: .utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
