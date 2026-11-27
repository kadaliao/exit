import AppKit
import Combine
import os

private let updateLog = Logger(subsystem: "io.github.kadaliao.Exit", category: "update")

/// Keeps Exit current from GitHub Releases: checks about once a day, downloads a new version in
/// the background, and installs it once you've been away from the Mac for a few minutes, then
/// reopens (the menu-bar icon blinks once). Quitting Exit installs a downloaded update too.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        /// A newer version exists but isn't downloaded.
        case available(Release)
        case downloading(Release)
        /// Downloaded and checked: installing is a rename.
        case ready(Release, archive: URL)
        case installing(Release)
        /// On disk already; this process is still the old version until it reopens.
        case installed(Release)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var checking = false
    /// Why the new version didn't install, for Settings.
    @Published private(set) var problem: String?
    @Published var checksAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(checksAutomatically, forKey: Key.check)
            if checksAutomatically { nextCheck = .now }
        }
    }
    @Published var installsAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(installsAutomatically, forKey: Key.install)
            if installsAutomatically { nextCheck = .now }
        }
    }
    @Published private(set) var lastCheck: Date? {
        didSet { UserDefaults.standard.set(lastCheck, forKey: Key.lastCheck) }
    }

    let current: ReleaseVersion
    /// Only real builds update themselves.
    let enabled: Bool
    /// Why this copy can't replace itself (running from a disk image, no permission); nil when it can.
    let blocker: String?

    private var nextCheck = Date.now
    private var loop: Task<Void, Never>?
    /// A version that failed its checks or its install: the background leaves it alone until a
    /// newer one comes out or the user tries again.
    private var gaveUpOn: ReleaseVersion?

    private enum Key {
        static let check = "updates.check"
        static let install = "updates.install"
        static let lastCheck = "updates.lastCheck"
    }

    private static let interval: TimeInterval = 24 * 3600
    private static let retry: TimeInterval = 3600
    /// Keyboard and mouse idle this long before an automatic install: reopening blinks the
    /// menu-bar icon and pauses effects for a moment, which mustn't happen while you work.
    private static let idleBeforeInstall: TimeInterval = 300

    private var userAgent: String { "Exit/\(current) (macOS)" }
    private var installed: URL { Bundle.main.bundleURL }
    private var downloads: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.kadaliao.Exit/Updates", isDirectory: true)
    }

    private init() {
        let d = UserDefaults.standard
        current = AppVersion.current.flatMap(ReleaseVersion.init) ?? ReleaseVersion("0")!
        enabled = AppVersion.current != nil && Updates.isReleaseBuild
        blocker = Updates.blocker(for: Bundle.main.bundleURL)
        checksAutomatically = d.object(forKey: Key.check) as? Bool ?? true
        installsAutomatically = d.object(forKey: Key.install) as? Bool ?? true
        lastCheck = d.object(forKey: Key.lastCheck) as? Date
    }

    /// The newer version on offer.
    var release: Release? {
        switch state {
        case .available(let r), .downloading(let r), .ready(let r, _), .installing(let r), .installed(let r): r
        case .idle: nil
        }
    }

    var isWorking: Bool {
        switch state {
        case .downloading, .installing: true
        default: checking
        }
    }

    /// Both switches on: downloading and installing need no questions.
    private var installsOnItsOwn: Bool { checksAutomatically && installsAutomatically }

    func start() {
        guard enabled, loop == nil else { return }
        nextCheck = lastCheck.map { $0.addingTimeInterval(Self.interval) } ?? .now
        let dir = downloads, current = current
        Task.detached(priority: .utility) { Updates.pruneDownloads(in: dir, keepingNewerThan: current) }
        loop = Task {
            // Let launch work (effect compiles, the market) settle first.
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func tick() async {
        if checksAutomatically, Date.now >= nextCheck, !isWorking { await check(userInitiated: false) }
        forgetMissingDownload()
        guard installsOnItsOwn, isUnattended else { return }
        if case .ready(let r, _) = state, gaveUpOn != r.version { await install(asked: false) }
        // Installing takes a moment: reopen only if still nobody's around.
        if case .installed = state, isUnattended { relaunch() }
    }

    /// Downloads live in Caches, which cleaners may empty: then download again.
    private func forgetMissingDownload() {
        if case .ready(let r, let archive) = state, !FileManager.default.fileExists(atPath: archive.path) {
            state = .available(r)
            if installsAutomatically { nextCheck = .now }
        }
    }

    // MARK: Checking

    /// Looks for a newer version. A check the user asked for reports back and offers to install.
    func check(userInitiated: Bool) async {
        guard enabled else {
            if userInitiated {
                alert(T("This copy doesn't update itself", "这份 Exit 不会自己更新"),
                      T("Only the signed releases from GitHub keep themselves up to date.",
                        "只有从 GitHub Releases 下载的正式版本会自己更新。"))
            }
            return
        }
        guard !isWorking else { return }
        if case .installed(let r) = state {
            if userInitiated { offer(r) }
            return
        }
        checking = true
        defer { checking = false }
        let r: Release
        do {
            r = try await Updates.latest(userAgent: userAgent)
        } catch {
            updateLog.error("update check failed: \(error.localizedDescription, privacy: .public)")
            nextCheck = Date.now.addingTimeInterval(Self.retry)
            if userInitiated { failed(error) }
            return
        }
        lastCheck = .now
        nextCheck = Date.now.addingTimeInterval(Self.interval)
        guard r.version > current else {
            state = .idle
            if userInitiated { alert(T("Exit is up to date", "已经是最新版本"), T("Exit \(current) is the newest version.", "Exit \(current) 是最新版本。")) }
            return
        }
        if release?.version != r.version { problem = nil }
        if case .ready(let have, let archive) = state, have.version == r.version,
           FileManager.default.fileExists(atPath: archive.path) {
            if userInitiated { offer(r) }
        } else if blocker != nil || (!userInitiated && (!installsOnItsOwn || gaveUpOn == r.version)) {
            state = .available(r)
            if userInitiated { offer(r) }
        } else if await download(r, asked: userInitiated), userInitiated {
            offer(r)
        }
    }

    /// Downloads and checks it; a bad version is never kept around to install.
    private func download(_ r: Release, asked: Bool) async -> Bool {
        state = .downloading(r)
        do {
            let archive = try await Updates.download(r, to: downloads, userAgent: userAgent)
            let installed = installed
            try await Task.detached(priority: .utility) {
                let app = try Updates.unpack(archive, version: r.version, near: installed)
                try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
            }.value
            updateLog.notice("\(r.version, privacy: .public) downloaded and checked")
            state = .ready(r, archive: archive)
            problem = nil
            return true
        } catch {
            state = .available(r)
            note(error, for: r, asked: asked)
            return false
        }
    }

    // MARK: Installing

    /// "Update" in the menu, Settings or an alert: download if needed, install, reopen.
    func update() async {
        if blocker != nil { NSWorkspace.shared.open(Updates.releasesPage); return }
        forgetMissingDownload()
        if case .available(let r) = state, await !download(r, asked: true) { return }
        if case .ready = state { await install(asked: true) }
        relaunch()
    }

    private func install(asked: Bool) async {
        guard case .ready(let r, let archive) = state else { return }
        state = .installing(r)
        let installed = installed
        do {
            try await Task.detached(priority: .userInitiated) {
                try Updates.install(archive, version: r.version, over: installed)
            }.value
            updateLog.notice("installed \(r.version, privacy: .public)")
            state = .installed(r)
            problem = nil
        } catch {
            state = .available(r)
            note(error, for: r, asked: asked)
        }
    }

    /// Reopens as the newly installed version.
    func relaunch() {
        guard case .installed = state else { return }
        do {
            try Updates.relaunch(installed)
            NSApp.terminate(nil)
        } catch {
            failed(error)
        }
    }

    /// Quitting with an update downloaded installs it, so the next launch is the new version.
    func installOnQuit() {
        guard enabled, installsOnItsOwn, case .ready(let r, let archive) = state, gaveUpOn != r.version else { return }
        do {
            try Updates.install(archive, version: r.version, over: installed)
            updateLog.notice("installed \(r.version, privacy: .public) on quit")
        } catch {
            updateLog.error("install on quit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Network trouble: try again in an hour. A version that fails its checks is left alone
    /// until a newer one comes out or the user tries again.
    private func note(_ error: Error, for r: Release, asked: Bool) {
        updateLog.error("update to \(r.version, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        nextCheck = Date.now.addingTimeInterval(Self.retry)
        switch error as? UpdateError {
        case .signature, .wrongApp, .unpack, .cannotReplace:
            gaveUpOn = r.version
            problem = error.localizedDescription
        default:
            break
        }
        if asked { failed(error) }
    }

    /// Reopening would go unnoticed: keyboard and mouse idle for a while, no Exit window or alert
    /// open, no effect playing, nothing being generated or submitted.
    private var isUnattended: Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return idle >= Self.idleBeforeInstall
            && !NSApp.isActive && NSApp.modalWindow == nil
            && !NSApp.windows.contains { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
            && ExitEngine.shared.overlay.activeCount == 0
            && !EffectGenerator.shared.isWorking
            && !SubmissionCenter.shared.isBusy
    }

    // MARK: Alerts

    func offer(_ r: Release) {
        let a = NSAlert()
        if case .installed = state {
            a.messageText = T("Exit \(r.version) is installed", "Exit \(r.version) 已经装好")
        } else {
            a.messageText = T("Exit \(r.version) is available", "Exit \(r.version) 可以更新了")
        }
        let now = T("You have \(current).", "你现在用的是 \(current)。")
        if let blocker {
            a.informativeText = now + " " + blocker
            a.addButton(withTitle: T("Open Download Page", "打开下载页"))
        } else {
            a.informativeText = now + " " + T("Updating quits Exit and opens it again; the menu-bar icon blinks once.",
                                              "更新时 Exit 会退出再自动打开，菜单栏图标会闪一下。")
                + (installsOnItsOwn ? " " + T("Choose Later and it installs itself when you're away from the Mac for a while.",
                                              "选「稍后」的话，等你离开电脑一会儿时自动装上。") : "")
            a.addButton(withTitle: T("Update and Relaunch", "更新并重新打开"))
        }
        a.addButton(withTitle: T("Later", "稍后"))
        a.addButton(withTitle: T("What's New", "更新内容"))
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: Task { await update() }
        case .alertThirdButtonReturn: NSWorkspace.shared.open(r.page)
        default: break
        }
    }

    private func failed(_ error: Error) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = T("Couldn't update", "没能更新")
        a.informativeText = error.localizedDescription
        a.addButton(withTitle: T("OK", "好"))
        a.addButton(withTitle: T("Open Download Page", "打开下载页"))
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(Updates.releasesPage) }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
