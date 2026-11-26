import Foundation
import Security

struct ChatMessage {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
}

enum ClaudeError: LocalizedError {
    case noAPIKey
    case cliNotFound
    case refused(String?)
    case http(Int, String)
    case process(String)
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .noAPIKey: T("No Anthropic API key. Add one in Settings → AI.", "还没有 Anthropic API Key，请在 设置 → AI 里填写。")
        case .cliNotFound: T("Claude Code CLI (`claude`) was not found.", "没找到 Claude Code 命令行（`claude`）。")
        case .refused(let why): T("Claude declined this request.", "Claude 拒绝了这个请求。") + (why.map { " (\($0))" } ?? "")
        case .http(let code, let body): "HTTP \(code): \(body.prefix(400))"
        case .process(let msg): msg
        case .emptyReply: T("Claude returned an empty reply.", "Claude 返回了空回复。")
        }
    }
}

/// Talks to Claude either through the Messages API (raw HTTP) or the local Claude Code CLI.
protocol ClaudeBackend {
    func send(system: String, messages: [ChatMessage], model: String, effort: String) async throws -> String
}

/// Messages API over HTTPS. The key lives in the login Keychain.
struct AnthropicAPIBackend: ClaudeBackend {
    let apiKey: String

    func send(system: String, messages: [ChatMessage], model: String, effort: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // Server-side fallback: if a safety classifier declines, the API retries on its
        // recommended fallback model within the same call.
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": effort],
            "system": system,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        if !model.hasPrefix("claude-haiku") { body["fallbacks"] = "default" }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ClaudeError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeError.emptyReply }
        if json["stop_reason"] as? String == "refusal" {
            let details = json["stop_details"] as? [String: Any]
            throw ClaudeError.refused(details?["category"] as? String)
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw ClaudeError.emptyReply }
        return text
    }
}

/// Runs `claude -p` with no tools, so it uses the user's existing Claude Code login.
struct ClaudeCodeBackend: ClaudeBackend {
    let executable: URL

    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return URL(fileURLWithPath: c) }
        // Fall back to the login shell's PATH.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    func send(system: String, messages: [ChatMessage], model: String, effort: String) async throws -> String {
        // The CLI is single-turn here, so earlier turns are folded into one prompt.
        var prompt = ""
        if messages.count == 1 {
            prompt = messages[0].text
        } else {
            for m in messages {
                prompt += m.role == .user ? "<user>\n\(m.text)\n</user>\n\n" : "<assistant>\n\(m.text)\n</assistant>\n\n"
            }
            prompt += "Reply to the last <user> message."
        }

        let process = Process()
        process.executableURL = executable
        var args = ["-p", "--output-format", "text", "--tools", "", "--no-session-persistence",
                    "--strict-mcp-config", "--system-prompt", system]
        if !model.isEmpty { args += ["--model", model] }
        if !effort.isEmpty { args += ["--effort", effort] }
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(executable.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withCheckedThrowingContinuation { cont in
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
                    let out = String(data: outBuf.data, encoding: .utf8) ?? ""
                    if p.terminationStatus == 0, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        cont.resume(returning: out)
                    } else {
                        let err = String(data: errBuf.data, encoding: .utf8) ?? ""
                        cont.resume(throwing: ClaudeError.process("claude exited \(p.terminationStatus): \((err.isEmpty ? out : err).prefix(500))"))
                    }
                }
            }
            do {
                try process.run()
                stdin.fileHandleForWriting.write(prompt.data(using: .utf8)!)
                try? stdin.fileHandleForWriting.close()
            } catch {
                cont.resume(throwing: ClaudeError.process(error.localizedDescription))
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ d: Data) { lock.withLock { storage.append(d) } }
    var data: Data { lock.withLock { storage } }
}

/// Minimal Keychain wrapper for the API key.
enum Keychain {
    private static let service = "io.github.kadaliao.Exit"
    private static let account = "anthropic-api-key"

    static func read() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = value.data(using: .utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
