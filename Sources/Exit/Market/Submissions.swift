import AppKit
import Combine

/// Submitting your own effects from Settings: the GitHub account, what's been sent, and the
/// market bot's answers (Exit keeps checking after the sheet is closed).
@MainActor
final class SubmissionCenter: ObservableObject {
    static let shared = SubmissionCenter()

    struct Account: Equatable {
        let login: String
        let source: GitHubAuth.Source
    }

    struct SignIn: Equatable {
        let userCode: String
        let url: URL
    }

    enum Status: String, Codable {
        /// The bot hasn't answered yet.
        case checking
        /// The bot's checks passed; the maintainer reviews the pull request.
        case accepted
        case needsChanges
        /// The pull request was merged: the effect is in the market.
        case merged
        /// The issue was closed without a merge: turned down, or withdrawn.
        case declined

        /// Exit 0.4.0 saved "closed" for both endings. Reading it as `accepted` makes Exit ask GitHub
        /// again which one it was.
        init(from decoder: Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .accepted
        }

        var isFinal: Bool { self == .merged || self == .declined }
    }

    struct Record: Codable, Equatable {
        var marketID: String
        var number: Int
        var url: String
        var sentAt: Date
        var status: Status
        /// The bot's reply.
        var report: String?

        var webURL: URL? { URL.web(url) }
    }

    /// Which effect the Submit sheet is open for.
    struct SheetItem: Identifiable, Equatable { let id: String }

    @Published private(set) var account: Account?
    @Published private(set) var accountLoading = false
    @Published private(set) var signIn: SignIn?
    @Published var signInError: String?
    /// Local effect id → its latest submission.
    @Published private(set) var records: [String: Record]
    @Published private(set) var sending: Set<String> = []
    @Published var sheet: SheetItem?

    var isBusy: Bool { !sending.isEmpty || signIn != nil }

    private var signInTask: Task<Void, Never>?
    private var watchers: [String: Task<Void, Never>] = [:]
    private var lastStatusRefresh: Date?
    /// How long after sending Exit keeps asking for the bot's answer.
    private static let watchFor: TimeInterval = 30 * 60

    private static var fileURL: URL { Paths.support.appendingPathComponent("submissions.json") }

    private init() {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        records = (try? d.decode([String: Record].self, from: Data(contentsOf: Self.fileURL))) ?? [:]
    }

    func present(_ effect: Effect) {
        sheet = SheetItem(id: effect.id)
    }

    func record(for effectID: String) -> Record? { records[effectID] }

    // MARK: Account

    /// Finds out who submissions would go out as. Asking the GitHub CLI starts a process, so it
    /// happens off the main thread.
    func refreshAccount() async {
        guard !accountLoading else { return }
        accountLoading = true
        defer { accountLoading = false }
        for _ in 0..<2 {
            guard let credential = await Task.detached(operation: { GitHubAuth.credential() }).value else {
                account = nil
                return
            }
            do {
                let login = try await GitHubAPI(token: credential.token).user().login
                account = Account(login: login, source: credential.source)
                return
            } catch GitHubError.http(401, _) where credential.source == .exit {
                // Revoked on GitHub: forget it and see whether the GitHub CLI can step in.
                GitHubAuth.signOut()
            } catch {
                // Offline or GitHub is having a moment: keep what we knew.
                return
            }
        }
        account = nil
    }

    /// GitHub's device flow: show a code, open github.com/login/device, wait for the person to enter it.
    func startSignIn() {
        guard signIn == nil else { return }
        signInError = nil
        signInTask?.cancel()
        signInTask = Task {
            do {
                let code = try await GitHubAuth.requestDeviceCode()
                let url = URL.web(code.verificationUri) ?? URL(string: "https://github.com/login/device")!
                signIn = SignIn(userCode: code.userCode, url: url)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                NSWorkspace.shared.open(url)
                let token = try await GitHubAuth.waitForToken(code)
                GitHubAuth.save(token)
                signIn = nil
                await refreshAccount()
            } catch is CancellationError {
                signIn = nil
            } catch {
                signIn = nil
                signInError = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signIn = nil
    }

    /// Forgets Exit's own sign-in (a signed-in GitHub CLI still works afterwards).
    func signOut() {
        GitHubAuth.signOut()
        account = nil
        Task { await refreshAccount() }
    }

    // MARK: Sending

    /// Sends `draft` (already checked) and starts waiting for the bot.
    func submit(effectID: String, draft: MarketSubmit.Draft, author: String, notes: String) async throws {
        sending.insert(effectID)
        defer { sending.remove(effectID) }
        guard let credential = await Task.detached(operation: { GitHubAuth.credential() }).value else { throw GitHubError.signedOut }
        let source = MarketSubmit.settingAuthor(draft.source, author)
        let body = MarketSubmit.issueBody(id: draft.id, source: source, notes: notes, via: "Exit's Submit button")
        let sentAt = Date()
        let sent = try await MarketSubmit.send(id: draft.id, title: draft.title, body: body, api: GitHubAPI(token: credential.token))
        records[effectID] = Record(marketID: draft.id, number: sent.number, url: sent.url, sentAt: sentAt, status: .checking)
        save()
        watch(effectID)
    }

    /// Asks for the bot's answer every 20 seconds until it comes (or half an hour has passed).
    private func watch(_ effectID: String) {
        watchers[effectID]?.cancel()
        watchers[effectID] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let r = self.records[effectID], r.status == .checking,
                      Date().timeIntervalSince(r.sentAt) < Self.watchFor else { break }
                try? await Task.sleep(for: .seconds(20))
                await self.poll(effectID)
            }
            self?.watchers[effectID] = nil
        }
    }

    private func poll(_ effectID: String) async {
        guard let r = records[effectID],
              let credential = await Task.detached(operation: { GitHubAuth.credential() }).value else { return }
        let api = GitHubAPI(token: credential.token)
        var updated = r
        if r.status == .checking, let reply = try? await MarketSubmit.botReply(r.number, since: r.sentAt, api: api) {
            updated.status = reply.passed ? .accepted : .needsChanges
            updated.report = reply.body
        }
        if updated.status != .checking, let issue = try? await api.issue(MarketSubmit.repo, r.number), issue.state == "closed",
           let merged = try? await api.closedByMerge(MarketSubmit.repo, r.number) {
            updated.status = merged ? .merged : .declined
        }
        // Another submission may have replaced this one meanwhile.
        guard records[effectID]?.number == r.number, records[effectID]?.sentAt == r.sentAt, updated != r else { return }
        records[effectID] = updated
        save()
    }

    /// Catches up on submissions when Settings opens: answers that came while Exit wasn't looking,
    /// reviews that finished.
    func refreshStatuses() {
        if let lastStatusRefresh, Date().timeIntervalSince(lastStatusRefresh) < 300 { return }
        lastStatusRefresh = Date()
        for (id, r) in records where !r.status.isFinal && watchers[id] == nil {
            if r.status == .checking && Date().timeIntervalSince(r.sentAt) < Self.watchFor {
                watch(id)
            } else if Date().timeIntervalSince(r.sentAt) < 60 * 86400 {
                Task { await poll(id) }
            }
        }
    }

    private func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? e.encode(records) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    // MARK: The bot's report

    struct CheckLine: Hashable {
        let ok: Bool
        let check: String
        let result: String
    }

    /// The table rows of a bot reply ("| ✅ | File name · 文件名 | `effects/x.metal` |").
    static func checkLines(_ report: String) -> [CheckLine] {
        report.split(separator: "\n").compactMap { raw in
            let cells = raw.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 4, ["✅", "❌", "⚠️"].contains(cells[1]) else { return nil }
            return CheckLine(ok: cells[1] == "✅", check: pick(cells[2]), result: plain(cells[3]))
        }
    }

    /// "Speed · 性能" → the half in the current language.
    private static func pick(_ text: String) -> String {
        let parts = text.components(separatedBy: " · ")
        return plain(parts.count == 2 ? parts[Lang.isChinese ? 1 : 0] : text)
    }

    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "<br>", with: " ")
    }
}
