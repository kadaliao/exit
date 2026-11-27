import AppKit
import Foundation

/// Who submissions go out as. Exit's own sign-in (a GitHub App that may only touch issues in the
/// market repository) comes first; a signed-in GitHub CLI works too, so people who have one never
/// see a sign-in step.
enum GitHubAuth {
    /// The "Exit Effect Market" GitHub App. Public: device flow needs no secret.
    static let clientID = "Iv23lihOaZwxeNq9nfa7"
    private static let keychainAccount = "github.user-token"

    enum Source: String { case exit, gh }

    struct Credential {
        let token: String
        let source: Source
    }

    /// Exit's own token, then the GitHub CLI's.
    static func credential() -> Credential? {
        if let t = Keychain.read(account: keychainAccount), !t.isEmpty { return Credential(token: t, source: .exit) }
        if let t = ghToken() { return Credential(token: t, source: .gh) }
        return nil
    }

    static var hasOwnToken: Bool { !(Keychain.read(account: keychainAccount) ?? "").isEmpty }

    static func save(_ token: String) { Keychain.write(token, account: keychainAccount) }

    static func signOut() { Keychain.write("", account: keychainAccount) }

    // MARK: GitHub CLI

    /// `gh auth token` for github.com, or nil when gh isn't installed or signed in.
    static func ghToken() -> String? {
        guard let gh = ghExecutable() else { return nil }
        let p = Process()
        p.executableURL = gh
        p.arguments = ["auth", "token", "--hostname", "github.com"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, !token.isEmpty, !token.contains(where: \.isWhitespace) else { return nil }
        return token
    }

    /// gh from the usual install folders or PATH (apps launched from Finder get a bare PATH).
    static func ghExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/opt/local/bin"] + path {
            let p = "\(dir)/gh"
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    // MARK: Device flow

    struct DeviceCode: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let expiresIn: Int
        let interval: Int
    }

    /// Step one: a code the person enters at github.com/login/device.
    static func requestDeviceCode() async throws -> DeviceCode {
        let data = try await post("https://github.com/login/device/code", ["client_id": clientID])
        if let e = try? decoder.decode(OAuthError.self, from: data), let code = e.error { throw GitHubError.oauth(code, e.errorDescription) }
        return try decoder.decode(DeviceCode.self, from: data)
    }

    /// Step two: waits until the person has entered the code (or it expires), then returns the token.
    static func waitForToken(_ code: DeviceCode) async throws -> String {
        var interval = max(code.interval, 5)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let data = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            struct Reply: Decodable { let accessToken: String?; let error: String?; let errorDescription: String?; let interval: Int? }
            let r = try decoder.decode(Reply.self, from: data)
            if let token = r.accessToken, !token.isEmpty { return token }
            switch r.error {
            case "authorization_pending": continue
            case "slow_down": interval = max(r.interval ?? interval + 5, interval + 5)
            case "expired_token": throw GitHubError.expired
            case "access_denied": throw GitHubError.denied
            default: throw GitHubError.oauth(r.error ?? "?", r.errorDescription)
            }
        }
        throw GitHubError.expired
    }

    private struct OAuthError: Decodable { let error: String?; let errorDescription: String? }

    private static func post(_ url: String, _ form: [String: String]) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(GitHubAPI.userAgent, forHTTPHeaderField: "User-Agent")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        req.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw GitHubError.http(http.statusCode, nil) }
        return data
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

enum GitHubError: LocalizedError {
    case http(Int, String?)
    case signedOut
    case expired
    case denied
    case oauth(String, String?)

    var errorDescription: String? {
        switch self {
        case .http(401, _): T("GitHub no longer accepts the sign-in. Sign in again.", "GitHub 不再接受当前登录，请重新登录。")
        case .http(403, let m), .http(429, let m):
            T("GitHub turned the request down: \(m ?? "too many requests"). Try again in a while.", "GitHub 拒绝了请求：\(m ?? "访问太频繁")。过一会儿再试。")
        case .http(let code, let m): "GitHub: HTTP \(code)" + (m.map { " — \($0)" } ?? "")
        case .signedOut: T("Sign in with GitHub first.", "请先登录 GitHub。")
        case .expired: T("The code expired before it was entered. Try again.", "验证码在输入前过期了，请重试。")
        case .denied: T("The sign-in was cancelled on GitHub.", "在 GitHub 上取消了授权。")
        case .oauth(let code, let m): "GitHub: \(m ?? code)"
        }
    }
}

/// The few REST calls submissions need.
struct GitHubAPI {
    static let userAgent = "Exit/\(AppVersion.current ?? "dev") (macOS)"
    let token: String

    struct User: Decodable { let login: String }
    struct Issue: Decodable {
        let number: Int
        let htmlUrl: String
        let body: String?
        let state: String
        let pullRequest: PullRef?
        struct PullRef: Decodable {}
    }
    struct Comment: Decodable {
        struct User: Decodable { let login: String }
        let user: User
        let body: String
        let updatedAt: Date
    }

    private struct ErrorMessage: Decodable { let message: String? }

    func user() async throws -> User { try await call("GET", "/user") }

    func openIssues(_ repo: String, creator: String) async throws -> [Issue] {
        let list: [Issue] = try await call("GET", "/repos/\(repo)/issues?state=open&per_page=100&creator=\(creator)")
        return list.filter { $0.pullRequest == nil }
    }

    func createIssue(_ repo: String, title: String, body: String) async throws -> Issue {
        try await call("POST", "/repos/\(repo)/issues", ["title": title, "body": body])
    }

    func updateIssue(_ repo: String, _ number: Int, title: String, body: String) async throws -> Issue {
        try await call("PATCH", "/repos/\(repo)/issues/\(number)", ["title": title, "body": body])
    }

    func issue(_ repo: String, _ number: Int) async throws -> Issue {
        try await call("GET", "/repos/\(repo)/issues/\(number)")
    }

    func comments(_ repo: String, _ number: Int) async throws -> [Comment] {
        try await call("GET", "/repos/\(repo)/issues/\(number)/comments?per_page=100")
    }

    private func call<T: Decodable>(_ method: String, _ path: String, _ body: [String: String]? = nil) async throws -> T {
        var req = URLRequest(url: URL(string: "https://api.github.com" + path)!, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GitHubError.http(http.statusCode, (try? JSONDecoder().decode(ErrorMessage.self, from: data))?.message)
        }
        return try GitHubAuth.decoder.decode(T.self, from: data)
    }
}
