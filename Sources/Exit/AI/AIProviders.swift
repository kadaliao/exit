import Foundation

/// A coding-agent CLI the user is already signed in to. Exit runs it non-interactively,
/// with tools disabled where the CLI allows it, in an empty temporary folder.
enum CLIAgent: String, CaseIterable, Identifiable {
    case claude, codex, gemini, opencode, pi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .opencode: "OpenCode"
        case .pi: "Pi"
        }
    }

    var command: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        case .opencode: "opencode"
        case .pi: "pi"
        }
    }

    var homepage: URL {
        switch self {
        case .claude: URL(string: "https://github.com/anthropics/claude-code")!
        case .codex: URL(string: "https://github.com/openai/codex")!
        case .gemini: URL(string: "https://github.com/google-gemini/gemini-cli")!
        case .opencode: URL(string: "https://opencode.ai")!
        case .pi: URL(string: "https://github.com/earendil-works/pi")!
        }
    }

    /// What to run in Terminal to sign in.
    var loginCommand: String {
        switch self {
        case .claude: "claude auth login"
        case .codex: "codex login"
        case .gemini: "gemini"
        case .opencode: "opencode auth login"
        case .pi: "pi auth login <provider>"
        }
    }

    /// Arguments of a command that exits 0 when the CLI is signed in, if it has one.
    var statusArguments: [String]? {
        switch self {
        case .claude: ["auth", "status"]
        case .codex: ["login", "status"]
        default: nil
        }
    }

    var supportsEffort: Bool { self == .claude || self == .codex || self == .pi }

    var modelPlaceholder: String {
        switch self {
        case .claude: T("CLI default (e.g. claude-opus-5-5)", "CLI 默认（如 claude-opus-5-5）")
        case .opencode, .pi: T("CLI default (provider/model)", "CLI 默认（provider/model）")
        default: T("CLI default", "CLI 默认")
        }
    }

    /// How Exit runs it, shown under the picker.
    var howItRuns: String {
        switch self {
        case .claude:
            T("Runs `claude -p` with every tool disabled, using your Claude Code login.",
              "以禁用全部工具的方式运行 `claude -p`，使用你已登录的 Claude Code 账号。")
        case .codex:
            T("Runs `codex exec` in a read-only sandbox inside an empty temporary folder, using your Codex login.",
              "在空的临时文件夹里以只读沙盒运行 `codex exec`，使用你已登录的 Codex 账号。")
        case .gemini:
            T("Runs `gemini` non-interactively inside an empty temporary folder, using your Gemini CLI login.",
              "在空的临时文件夹里以非交互方式运行 `gemini`，使用你已登录的 Gemini CLI 账号。")
        case .opencode:
            T("Runs `opencode run` in plan mode with edits, shell and web access denied, inside an empty temporary folder.",
              "在空的临时文件夹里以 plan 模式运行 `opencode run`，禁止修改文件、执行命令和联网。")
        case .pi:
            T("Runs `pi -p` with every tool disabled, using the providers you signed in to with Pi.",
              "以禁用全部工具的方式运行 `pi -p`，使用你在 Pi 里登录过的服务商。")
        }
    }
}

enum APIFormat: String {
    case anthropic   // POST {base}/v1/messages
    case openai      // POST {base}/chat/completions
}

/// A service reached with the user's own API key.
struct APIPreset: Hashable {
    let id: String
    let title: String
    let format: APIFormat
    let baseURL: String
    let defaultModel: String
    var isCustom: Bool { id.hasPrefix("custom") }

    static let all: [APIPreset] = [
        APIPreset(id: "anthropic", title: "Anthropic", format: .anthropic,
                  baseURL: "https://api.anthropic.com", defaultModel: "claude-opus-5-5"),
        APIPreset(id: "openai", title: "OpenAI", format: .openai,
                  baseURL: "https://api.openai.com/v1", defaultModel: ""),
        APIPreset(id: "gemini", title: "Google Gemini", format: .openai,
                  baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModel: ""),
        APIPreset(id: "openrouter", title: "OpenRouter", format: .openai,
                  baseURL: "https://openrouter.ai/api/v1", defaultModel: ""),
        APIPreset(id: "deepseek", title: "DeepSeek", format: .openai,
                  baseURL: "https://api.deepseek.com", defaultModel: ""),
        APIPreset(id: "moonshot", title: T("Moonshot (Kimi)", "月之暗面（Kimi）"), format: .openai,
                  baseURL: "https://api.moonshot.cn/v1", defaultModel: ""),
        APIPreset(id: "qwen", title: T("Alibaba Qwen (DashScope)", "阿里通义千问（百炼）"), format: .openai,
                  baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", defaultModel: ""),
        APIPreset(id: "zhipu", title: T("Zhipu GLM", "智谱 GLM"), format: .openai,
                  baseURL: "https://open.bigmodel.cn/api/paas/v4", defaultModel: ""),
        APIPreset(id: "custom-openai", title: T("Custom (OpenAI-compatible)", "自定义（OpenAI 兼容）"), format: .openai,
                  baseURL: "", defaultModel: ""),
        APIPreset(id: "custom-anthropic", title: T("Custom (Anthropic-compatible)", "自定义（Anthropic 兼容）"), format: .anthropic,
                  baseURL: "", defaultModel: ""),
    ]

    var baseURLPlaceholder: String {
        switch id {
        case "custom-openai": "http://localhost:11434/v1"
        case "custom-anthropic": "https://example.com/anthropic"
        default: baseURL
        }
    }
}

/// Where AI generation runs: a signed-in CLI or an API key.
enum AIProvider: Hashable, Identifiable {
    case cli(CLIAgent)
    case api(APIPreset)

    var id: String {
        switch self {
        case .cli(let a): "cli.\(a.rawValue)"
        case .api(let p): "api.\(p.id)"
        }
    }

    init?(id: String) {
        if id.hasPrefix("cli."), let a = CLIAgent(rawValue: String(id.dropFirst(4))) {
            self = .cli(a)
        } else if id.hasPrefix("api."), let p = APIPreset.all.first(where: { $0.id == id.dropFirst(4) }) {
            self = .api(p)
        } else {
            return nil
        }
    }

    static var all: [AIProvider] { CLIAgent.allCases.map { .cli($0) } + APIPreset.all.map { .api($0) } }

    var title: String {
        switch self {
        case .cli(let a): a.title
        case .api(let p): p.title
        }
    }

    var defaultModel: String {
        switch self {
        case .cli: ""
        case .api(let p): p.defaultModel
        }
    }

    var supportsEffort: Bool {
        switch self {
        case .cli(let a): a.supportsEffort
        case .api(let p): p.id != "custom-anthropic"
        }
    }
}
