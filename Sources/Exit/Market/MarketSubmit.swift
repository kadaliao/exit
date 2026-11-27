import Foundation

/// Sends an effect to the official market from the command line. Meant for coding agents:
///
///   Exit --market submit <file.metal | effect id> [--notes TEXT] [--wait] [--dry-run] [--force]
///
/// Runs the market's checks locally, then opens a submission issue with the GitHub CLI (`gh`),
/// or updates the open one for the same effect. The market's bot checks the effect again,
/// renders a preview and opens a pull request with the submitter as author. `--wait` stays
/// until the bot has answered and prints its report.
enum MarketSubmit {
    static let repo = "kadaliao/exit-effects"
    static let guide = URL(string: "https://github.com/kadaliao/exit-effects/blob/main/AGENTS.md")!
    private static let maxBytes = 32 * 1024
    private static let bot = "github-actions[bot]"

    /// The first line of a submission issue: the bot only reads issues that carry it, and a
    /// resubmission finds its open issue by the id in it.
    static func marker(_ id: String) -> String { "<!-- exit-effect-submission id=\(id) -->" }

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
        guard let data = try? Data(contentsOf: url) else { print("✗ can't read \(url.path)"); return 2 }
        guard let source = String(data: data, encoding: .utf8) else { print("✗ \(url.lastPathComponent) is not UTF-8 text"); return 1 }

        let stem = url.deletingPathExtension().lastPathComponent
        let id = slug(stem)
        let meta = EffectMeta.parse(source: source, fallbackName: "")
        print("▸ \(meta.name.isEmpty ? stem : meta.name) (\(url.path))")
        if id != stem { print("  submitted as \(id).metal: market file names are lowercase letters, digits and dashes") }

        // The market's rules, then Exit's own checks (compiles, starts as the untouched window, ends clean, fast enough)
        var problems: [String] = []
        if id.wholeMatch(of: #/[a-z0-9][a-z0-9-]{1,39}/#) == nil || id == "prelude" {
            problems.append("The file name can't become a market id; rename it to something like paper-plane.metal.")
        }
        if builtInIDs.contains(id) { problems.append("\(id) is the name of an effect built into Exit; rename the file.") }
        if data.count > maxBytes { problems.append("The file is \(data.count / 1024) KB; the market takes at most \(maxBytes / 1024) KB.") }
        if source.contains(#/(?m)^\s*#\s*(include|import)\b/#) { problems.append("Remove #include / #import lines: the prelude already has everything.") }
        if meta.name.isEmpty { problems.append("The header needs a `// @name …` line.") }
        if meta.description == nil { problems.append("The header needs a `// @description …` line (one sentence about what the window does).") }
        problems += EffectGenerator.validate(source)
        if !problems.isEmpty {
            print("✗ it doesn't pass the market's checks yet:")
            problems.forEach { print("   - " + $0.replacingOccurrences(of: "\n", with: "\n     ")) }
            if !force { print("Fix the file and run this again (or add --force to let the market's bot report instead)."); return 1 }
        } else {
            print("✓ passes the market's checks on this Mac")
        }
        if meta.author == nil { print("  no @author line: the bot will credit your GitHub user name") }

        let title = "[Effect] \(meta.name.isEmpty ? id : meta.name)"
        let body = issueBody(id: id, source: source, notes: notes)
        if dryRun {
            print("\n--dry-run: would send this to github.com/\(repo) as “\(title)”:\n")
            print(body)
            return 0
        }

        // GitHub
        guard let login = gh(["api", "user", "--jq", ".login"]).flatMap({ $0.status == 0 ? $0.out : nil }), !login.isEmpty else {
            print("✗ the GitHub CLI isn't ready. Install it and sign in, then run this again:\n    brew install gh && gh auth login")
            return 1
        }
        let sentAt = Date()
        var number: Int?
        if let r = gh(["issue", "list", "-R", repo, "--author", "@me", "--state", "open", "--limit", "100", "--json", "number,body"]),
           r.status == 0, let list = try? JSONDecoder().decode([OpenIssue].self, from: Data(r.out.utf8)) {
            number = list.first { $0.body.hasPrefix(marker(id)) }?.number
        }
        if let n = number {
            guard let r = gh(["issue", "edit", String(n), "-R", repo, "--title", title, "--body-file", "-"], input: body), r.status == 0 else {
                print("✗ couldn't update issue #\(n)"); return 1
            }
            print("✓ updated your open submission: https://github.com/\(repo)/issues/\(n)")
        } else {
            guard let r = gh(["issue", "create", "-R", repo, "--title", title, "--body-file", "-"], input: body), r.status == 0,
                  let n = Int(r.out.split(separator: "/").last ?? "") else {
                print("✗ couldn't open the submission issue"); return 1
            }
            number = n
            print("✓ submitted as \(login): \(r.out)")
        }
        let n = number!

        guard wait else {
            print("""
              The market's bot checks it again, renders a preview and answers on the issue in about five minutes:
                gh issue view \(n) -R \(repo) --comments
              To change the effect, edit the file and run this command again; it updates the same issue.
            """)
            return 0
        }
        print("  waiting for the market's bot (usually about five minutes)…")
        let deadline = Date().addingTimeInterval(20 * 60)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 15)
            guard let r = gh(["api", "repos/\(repo)/issues/\(n)/comments?per_page=100"]), r.status == 0,
                  let comments = try? JSONDecoder.github.decode([Comment].self, from: Data(r.out.utf8)),
                  let reply = comments.last(where: { $0.user.login == bot && $0.updatedAt > sentAt.addingTimeInterval(-5) })
            else { continue }
            print("\n" + reply.body + "\n")
            let passed = reply.body.contains("✅ All checks passed")
            print(passed ? "✓ the bot accepted it; the maintainer reviews the pull request next" : "✗ the bot found problems; fix them and run this again")
            return passed ? 0 : 1
        }
        print("✗ no answer from the bot after 20 minutes; look at https://github.com/\(repo)/issues/\(n)")
        return 1
    }

    /// Same sections as the market's old issue form, which the bot parses.
    static func issueBody(id: String, source: String, notes: String?) -> String {
        let longest = source.matches(of: #/`{3,}/#).map(\.output.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let stamp = ISO8601DateFormatter().string(from: Date())
        let note = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        \(marker(id))
        Sent with `Exit --market submit` (Exit \(AppVersion.current ?? "dev"), \(stamp)).

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

    private struct OpenIssue: Decodable { let number: Int; let body: String }
    private struct Comment: Decodable {
        struct User: Decodable { let login: String }
        let user: User
        let body: String
        let updatedAt: Date
    }

    /// Runs `gh` from the caller's PATH. nil when it can't be started at all.
    private static func gh(_ args: [String], input: String? = nil) -> (status: Int32, out: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["gh"] + args
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        do { try p.run() } catch { return nil }
        if let input { inp.fileHandleForWriting.write(Data(input.utf8)) }
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 127 { return nil }   // env: gh: No such file or directory
        if p.terminationStatus != 0, let e = String(data: errData, encoding: .utf8), !e.isEmpty,
           !args.starts(with: ["api", "user"]) {
            print("  gh: " + e.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private extension JSONDecoder {
    static let github: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
