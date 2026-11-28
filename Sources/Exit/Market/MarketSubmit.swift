import Foundation

/// Sends an effect to the official market. Settings → Effects has a Submit button for it, and
/// coding agents use the command line:
///
///   Exit --market submit <file.metal | effect id> [--notes TEXT] [--wait] [--dry-run] [--force]
///
/// Both run the market's checks locally, then open a submission issue from the person's GitHub
/// account (Exit's own sign-in, or the GitHub CLI's), or update the open one for the same effect.
/// The market's bot checks the effect again, renders a preview and opens a pull request with the
/// submitter as author.
struct SubmitError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum MarketSubmit {
    static let repo = "kadaliao/exit-effects"
    static let guide = URL(string: "https://github.com/kadaliao/exit-effects/blob/main/AGENTS.md")!
    static let maxBytes = 32 * 1024
    private static let bot = "github-actions[bot]"

    /// The first line of a submission issue: the bot only reads issues that carry it, and a
    /// resubmission finds its open issue by the id in it.
    static func marker(_ id: String) -> String { "<!-- exit-effect-submission id=\(id) -->" }

    // MARK: The effect

    struct Draft {
        let url: URL
        let source: String
        let meta: EffectMeta
        /// What the file is called in the market.
        var id: String
        var byteCount: Int { source.utf8.count }
        var title: String { "[Effect] \(meta.name.isEmpty ? id : meta.name)" }
    }

    static func load(_ url: URL) throws -> Draft {
        let data = try Data(contentsOf: url)
        guard let source = String(data: data, encoding: .utf8) else {
            throw SubmitError(T("\(url.lastPathComponent) is not UTF-8 text.", "\(url.lastPathComponent) 不是 UTF-8 文本。"))
        }
        let meta = EffectMeta.parse(source: source, fallbackName: "")
        return Draft(url: url, source: source, meta: meta, id: defaultID(stem: url.deletingPathExtension().lastPathComponent, name: meta.name))
    }

    /// The file name as a market id, or the effect's name when the file name has no usable letters
    /// (an effect saved under a Chinese name, say).
    static func defaultID(stem: String, name: String) -> String {
        let a = slug(stem)
        return idProblem(a) == nil || slug(name).isEmpty ? a : slug(name)
    }

    /// Why `id` can't be a market file name; nil when it can.
    static func idProblem(_ id: String) -> String? {
        if id.wholeMatch(of: #/[a-z0-9][a-z0-9-]{1,39}/#) == nil || id == "prelude" {
            return T("The market id must be 2–40 lowercase letters, digits and dashes, like paper-plane.",
                     "市场里的 ID 只能用 2–40 个小写字母、数字和短横线，比如 paper-plane。")
        }
        if builtInIDs.contains(id) {
            return T("\(id) is the name of an effect built into Exit; pick another id.", "\(id) 是 Exit 内置特效的名字，换一个 ID。")
        }
        return nil
    }

    /// The market's own rules (file name, header, size, no includes).
    static func ruleProblems(_ d: Draft) -> [String] {
        var problems: [String] = []
        if let p = idProblem(d.id) { problems.append(p) }
        if d.byteCount > maxBytes {
            problems.append(T("The file is \(d.byteCount / 1024) KB; the market takes at most \(maxBytes / 1024) KB.",
                              "文件有 \(d.byteCount / 1024) KB，市场最多收 \(maxBytes / 1024) KB。"))
        }
        if d.source.contains(#/(?m)^\s*#\s*(include|import)\b/#) {
            problems.append(T("Remove #include / #import lines: the prelude already has everything.",
                              "去掉 #include / #import：prelude 里已经什么都有了。"))
        }
        if d.meta.name.isEmpty { problems.append(T("The header needs a `// @name …` line.", "文件头需要一行 `// @name …`。")) }
        if d.meta.description == nil {
            problems.append(T("The header needs a `// @description …` line (one sentence about what the window does).",
                              "文件头需要一行 `// @description …`（一句话说明窗口会怎样）。"))
        }
        return problems
    }

    /// Every check, the market's rules and Exit's own (compiles, starts as the untouched window,
    /// ends clean, fast enough). Renders test frames, so keep it off the main thread.
    static func problems(_ d: Draft) -> [String] {
        ruleProblems(d) + EffectGenerator.validate(d.source)
    }

    /// The header with `// @author <name>` after the name lines, replacing any author line.
    /// `name` nil or empty removes it (the market's bot then credits the GitHub user name).
    static func settingAuthor(_ source: String, _ name: String?) -> String {
        let name = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        var lines = source.components(separatedBy: "\n")
        let header = #/^\s*//\s*@author\b/#
        let end = min(lines.count, 60)
        lines = lines.prefix(end).filter { !$0.contains(header) } + lines.dropFirst(end)
        guard !name.isEmpty else { return lines.joined(separator: "\n") }
        var at = 0
        for (i, l) in lines.prefix(60).enumerated() where l.contains(#/^\s*//\s*@name(\.zh)?\b/#) { at = i + 1 }
        lines.insert("// @author \(name)", at: at)
        return lines.joined(separator: "\n")
    }

    /// The file's author, unless it's the "Exit" that AI-made effects used to copy from the examples.
    static func realAuthor(_ meta: EffectMeta) -> String? {
        guard let a = meta.author?.trimmingCharacters(in: .whitespaces), !a.isEmpty, a.lowercased() != "exit" else { return nil }
        return a
    }

    /// Same sections as the market's old issue form, which the bot parses.
    static func issueBody(id: String, source: String, notes: String?, via: String) -> String {
        let longest = source.matches(of: #/`{3,}/#).map(\.output.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let stamp = ISO8601DateFormatter().string(from: Date())
        let note = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        \(marker(id))
        Sent with \(via) (Exit \(AppVersion.current ?? "dev"), \(stamp)).

        ### Effect ID · 特效 ID

        \(id)

        ### Shader source · 源码

        \(fence)metal
        \(source.trimmingCharacters(in: .newlines))
        \(fence)

        ### Notes · 说明

        \(note?.isEmpty == false ? note! : "_No response_")

        ### License · 许可

        - [X] I wrote this effect (or may share it) and release it under the MIT License. · 这是我写的（或我有权分享），同意以 MIT 许可证发布。
        """
    }

    /// "Paper Plane" → paper-plane, as the market does.
    static func slug(_ text: String) -> String {
        let s = text.lowercased().replacing(#/[^a-z0-9]+/#, with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(s.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static var builtInIDs: Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.builtInEffects, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "metal" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    // MARK: GitHub

    struct Sent {
        let number: Int
        let url: String
        let login: String
        /// An open submission for the same id was updated instead of opening a new one.
        let updated: Bool
    }

    /// Opens the submission issue, or updates the open one for the same id.
    static func send(id: String, title: String, body: String, api: GitHubAPI) async throws -> Sent {
        let login = try await api.user().login
        let mine = try await api.openIssues(repo, creator: login)
        if let open = mine.first(where: { ($0.body ?? "").hasPrefix(marker(id)) }) {
            let issue = try await api.updateIssue(repo, open.number, title: title, body: body)
            return Sent(number: issue.number, url: issue.htmlUrl, login: login, updated: true)
        }
        let issue = try await api.createIssue(repo, title: title, body: body)
        return Sent(number: issue.number, url: issue.htmlUrl, login: login, updated: false)
    }

    struct BotReply {
        let body: String
        var passed: Bool { body.contains("✅ All checks passed") }
        /// The bot merged it right away: a new effect, or an update to your own.
        var merged: Bool { passed && body.contains("Merged in #") }
    }

    /// The bot's answer on issue `number` written after `since`, if there is one yet.
    static func botReply(_ number: Int, since: Date, api: GitHubAPI) async throws -> BotReply? {
        let comments = try await api.comments(repo, number)
        guard let c = comments.last(where: { $0.user.login == bot && $0.updatedAt > since.addingTimeInterval(-5) }) else { return nil }
        return BotReply(body: c.body)
    }

    // MARK: Command line

    static func run(target: String, notes: String?, wait: Bool, dryRun: Bool, force: Bool) -> Int32 {
        // The effect
        let path = (target as NSString).expandingTildeInPath
        let url: URL
        if FileManager.default.fileExists(atPath: path) {
            url = URL(fileURLWithPath: path)
        } else if let effect = EffectLibrary.shared.effect(id: target) {
            guard effect.origin == .user else {
                print("✗ \(target) is \(effect.origin == .builtIn ? "built into Exit" : "already in the market"); only your own effects can be submitted")
                return 2
            }
            url = effect.url
        } else {
            print("✗ no file or effect called \(target). Pass a .metal file or the id of one of your effects (Exit --check lists them).")
            return 2
        }
        let draft: Draft
        do { draft = try load(url) } catch { print("✗ can't read \(url.path): \(error.localizedDescription)"); return 1 }

        let stem = url.deletingPathExtension().lastPathComponent
        print("▸ \(draft.meta.name.isEmpty ? stem : draft.meta.name) (\(url.path))")
        if draft.id != stem { print("  submitted as \(draft.id).metal: market file names are lowercase letters, digits and dashes") }

        let problems = problems(draft)
        if !problems.isEmpty {
            print("✗ it doesn't pass the market's checks yet:")
            problems.forEach { print("   - " + $0.replacingOccurrences(of: "\n", with: "\n     ")) }
            if !force { print("Fix the file and run this again (or add --force to let the market's bot report instead)."); return 1 }
        } else {
            print("✓ passes the market's checks on this Mac")
        }
        var source = draft.source
        if realAuthor(draft.meta) == nil {
            print("  no @author line: the bot will credit your GitHub user name")
            source = settingAuthor(source, nil)   // not "Exit" from the examples
        }

        let body = issueBody(id: draft.id, source: source, notes: notes, via: "`Exit --market submit`")
        if dryRun {
            print("\n--dry-run: would send this to github.com/\(repo) as “\(draft.title)”:\n")
            print(body)
            return 0
        }

        // GitHub
        guard let credential = GitHubAuth.credential() else {
            print("✗ not signed in to GitHub. Either sign in from Exit (Settings → Effects → Submit to Market) or use the GitHub CLI:\n    brew install gh && gh auth login")
            return 1
        }
        let api = GitHubAPI(token: credential.token)
        let sentAt = Date()
        let sent: Sent
        do {
            sent = try blocking { try await send(id: draft.id, title: draft.title, body: body, api: api) }
        } catch {
            print("✗ couldn't send it: \(error.localizedDescription)")
            return 1
        }
        print(sent.updated ? "✓ updated your open submission: \(sent.url)" : "✓ submitted as \(sent.login): \(sent.url)")

        guard wait else {
            print("""
              The market's bot checks it again, renders a preview and answers on the issue in about five minutes:
                \(sent.url)
              To change the effect, edit the file and run this command again; it updates the same issue.
            """)
            return 0
        }
        print("  waiting for the market's bot (usually about five minutes)…")
        let deadline = Date().addingTimeInterval(20 * 60)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 15)
            guard let reply = try? blocking({ try await botReply(sent.number, since: sentAt, api: api) }) else { continue }
            print("\n" + reply.body + "\n")
            print(reply.merged ? "✓ the bot merged it: it reaches everyone's Market within minutes"
                  : reply.passed ? "✓ the bot accepted it; the maintainer reviews the pull request next"
                  : "✗ the bot found problems; fix them and run this again")
            return reply.passed ? 0 : 1
        }
        print("✗ no answer from the bot after 20 minutes; look at \(sent.url)")
        return 1
    }

    /// Runs async work from the synchronous command line.
    private static func blocking<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>(), done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
