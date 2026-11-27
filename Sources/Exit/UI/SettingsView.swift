import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, effects, market, ai, rules, permissions
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: T("General", "通用")
        case .effects: T("Effects", "特效")
        case .market: T("Market", "特效市场")
        case .ai: T("Create with AI", "AI 生成")
        case .rules: T("Rules", "规则")
        case .permissions: T("Permissions", "权限")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .effects: "sparkles.rectangle.stack"
        case .market: "storefront"
        case .ai: "wand.and.stars"
        case .rules: "line.3.horizontal.decrease.circle"
        case .permissions: "lock.shield"
        }
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @EnvironmentObject var nav: SettingsNavigation
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var submissions = SubmissionCenter.shared

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding(get: { nav.tab }, set: { if let t = $0 { nav.tab = t } })) { tab in
                SidebarRow(tab: tab).tag(tab)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Group {
                switch nav.tab {
                case .general: GeneralPane()
                case .effects: EffectsPane()
                case .market: MarketPane()
                case .ai: AIPane()
                case .rules: RulesPane()
                case .permissions: PermissionsPane()
                }
            }
            .navigationTitle(nav.tab.title)
        }
        .id(settings.language)
        .sheet(item: $submissions.sheet) { item in
            if let effect = EffectLibrary.shared.effect(id: item.id) {
                SubmitSheet(effect: effect)
            }
        }
    }
}

/// A sidebar item; the AI item shows a spinner while an effect is being generated.
private struct SidebarRow: View {
    let tab: SettingsTab
    @ObservedObject private var generator = EffectGenerator.shared

    var body: some View {
        HStack {
            Label(tab.title, systemImage: tab.symbol)
            if tab == .ai && generator.isWorking {
                Spacer()
                ProgressView().controlSize(.mini)
                    .help(T("Generating an effect…", "正在生成特效…"))
            }
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Toggle(T("Play effects", "播放特效"), isOn: $settings.enabled)
            }
            Section {
                Picker(selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                } label: {
                    // Both names, so it can be found whatever the current language is.
                    Label(T("Language · 语言", "语言 · Language"), systemImage: "globe")
                }
                Picker(selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label(T("Appearance", "外观"), systemImage: "circle.lefthalf.filled")
                }
                .pickerStyle(.segmented)
            }
            Section(T("What plays when…", "什么时候播放什么")) {
                ForEach([WindowEvent.close, .quit, .open, .minimize]) { event in
                    EffectAssignmentRow(event: event)
                }
            }
            Section {
                LabeledContent(T("Speed", "速度")) {
                    HStack {
                        Slider(value: $settings.speed, in: 0.5...2.0, step: 0.1)
                        Text(String(format: "%.1f×", settings.speed)).monospacedDigit().frame(width: 40)
                    }
                }
            }
            Section {
                Toggle(isOn: $settings.preciseCapture) {
                    Text(T("Precise last frame", "精确最后一帧"))
                    Text(T("Holds ⌘W, ⌘Q, ⌘M and close-button clicks for a few milliseconds to photograph the window exactly as it was. No other keys are ever read.",
                           "按下 ⌘W、⌘Q、⌘M 或点击关闭按钮时，先停留几毫秒拍下窗口的最后一帧再放行。不会读取其他任何按键。"))
                }
                Toggle(isOn: $settings.refreshFocused) {
                    Text(T("Keep the front window's picture fresh", "持续刷新前台窗口画面"))
                    Text(T("Re-captures the focused window every few seconds, so windows closed by the app itself also start from a recent frame. The menu-bar recording indicator may flash.",
                           "每隔几秒重新截取当前窗口，App 自己关掉的窗口也能用上较新的画面。菜单栏的录屏指示可能会闪一下。"))
                }
            }
            UpdatesSection()
            Section {
                LabeledContent(T("Windows sent off", "已送走的窗口"), value: "\(settings.playCount)")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Rules

struct RulesPane: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Toggle(T("Stay still when Reduce Motion is on", "开启“减弱动态效果”时不播放"), isOn: $settings.respectReduceMotion)
                LabeledContent(T("Ignore windows smaller than", "忽略小于此尺寸的窗口")) {
                    HStack {
                        Slider(value: $settings.minWindowSize, in: 40...600, step: 10)
                        Text("\(Int(settings.minWindowSize)) pt").monospacedDigit().frame(width: 60)
                    }
                }
            }
            Section(T("Excluded apps", "排除的 App")) {
                if settings.excludedApps.isEmpty {
                    Text(T("No apps excluded.", "还没有排除任何 App。")).foregroundStyle(.secondary)
                }
                ForEach(settings.excludedApps, id: \.self) { bundleID in
                    HStack {
                        AppIconView(bundleID: bundleID)
                        Text(appName(bundleID))
                        Text(bundleID).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            settings.excludedApps.removeAll { $0 == bundleID }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Menu(T("Add Running App", "添加正在运行的 App")) {
                        ForEach(runningApps(), id: \.self) { b in
                            Button(appName(b)) { add(b) }
                        }
                    }
                    Button(T("Choose…", "选择…")) { chooseApp() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func runningApps() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { !settings.excludedApps.contains($0) && $0 != Bundle.main.bundleIdentifier }
            .sorted { appName($0).localizedCompare(appName($1)) == .orderedAscending }
    }

    private func add(_ b: String) {
        if !settings.excludedApps.contains(b) { settings.excludedApps.append(b) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url, let b = Bundle(url: url)?.bundleIdentifier { add(b) }
    }
}

func appName(_ bundleID: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    return bundleID
}

struct AppIconView: View {
    let bundleID: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "app").frame(width: 20, height: 20)
        }
    }
}

// MARK: - Permissions

struct PermissionsPane: View {
    @State private var ax = AX.isTrusted()
    @State private var screen = SnapshotService.hasPermission
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    granted: ax,
                    title: T("Accessibility (required)", "辅助功能（必需）"),
                    detail: T("Lets Exit notice windows opening, closing and minimizing, and briefly hold ⌘W / ⌘Q / ⌘M for the precise last frame.",
                              "用来感知窗口的打开、关闭和最小化，以及在 ⌘W / ⌘Q / ⌘M 时短暂停留以拍下最后一帧。"),
                    action: {
                        _ = AX.isTrusted(prompt: true)
                        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    })
                PermissionRow(
                    granted: screen,
                    title: T("Screen Recording (optional)", "录屏（可选）"),
                    detail: T("Lets effects start from the window's real picture. Without it Exit animates a card with the app icon. Pictures stay in memory for a few seconds and never leave your Mac.",
                              "让特效从窗口的真实画面开始。没有这个权限时，会用带 App 图标的卡片代替。画面只在内存里停留几秒，不会写入磁盘，也不会离开你的 Mac。"),
                    action: {
                        SnapshotService.requestPermission()
                        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                    })
            }
            if screen == false {
                Section {
                    Text(T("After granting Screen Recording, macOS may ask to quit and reopen Exit.",
                           "开启录屏权限后，macOS 可能会要求退出并重新打开 Exit。"))
                        .foregroundStyle(.secondary)
                    Button(T("Relaunch Exit", "重新启动 Exit")) { relaunch() }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            ax = AX.isTrusted()
            screen = SnapshotService.hasPermission
        }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

struct PermissionRow: View {
    let granted: Bool
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                Button(T("Grant…", "去开启…"), action: action)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Updates

struct UpdatesSection: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section(T("Updates", "软件更新")) {
            LabeledContent(T("Version", "版本")) {
                HStack(spacing: 10) {
                    Text(AppVersion.current ?? "dev").monospacedDigit()
                    if updater.isWorking { ProgressView().controlSize(.small) }
                    Button(T("Check Now", "立即检查")) { Task { await updater.check(userInitiated: true) } }
                        .disabled(updater.isWorking || !updater.enabled)
                }
            }
            if let line = statusLine {
                HStack {
                    Text(line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let r = updater.release {
                        Button(T("What's New", "更新内容")) { NSWorkspace.shared.open(r.page) }.buttonStyle(.link)
                        if case .installed = updater.state {
                            Button(T("Relaunch", "重新打开")) { updater.relaunch() }
                        } else if !updater.isWorking {
                            Button(updater.blocker == nil ? T("Update", "更新") : T("Download", "下载")) { Task { await updater.update() } }
                        }
                    }
                }
            }
            if let problem = updater.problem ?? (updater.release != nil ? updater.blocker : nil) {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(T("Check for updates automatically", "自动检查更新"), isOn: $updater.checksAutomatically)
                .disabled(!updater.enabled)
            Toggle(isOn: $updater.installsAutomatically) {
                Text(T("Install updates automatically", "自动安装更新"))
                Text(T("Downloads in the background and installs while you're away from the Mac, or when Exit quits. Exit reopens by itself; the menu-bar icon blinks once.",
                       "在后台下载，等你离开电脑一会儿或退出 Exit 时装上。Exit 会自己重新打开，菜单栏图标会闪一下。"))
            }
            .disabled(!updater.enabled || !updater.checksAutomatically)
        }
    }

    private var statusLine: String? {
        guard updater.enabled else {
            return T("This copy wasn't downloaded from GitHub Releases, so it doesn't update itself.",
                     "这份 Exit 不是从 GitHub Releases 下载的正式版本，不会自己更新。")
        }
        switch updater.state {
        case .idle:
            if updater.checking { return T("Checking…", "正在检查…") }
            guard let last = updater.lastCheck else { return nil }
            let ago = RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
            return T("Exit is up to date (checked \(ago)).", "已经是最新版本（\(ago)检查过）。")
        case .available(let r): return T("Exit \(r.version) is available.", "Exit \(r.version) 可以更新了。")
        case .downloading(let r): return T("Downloading Exit \(r.version)…", "正在下载 Exit \(r.version)…")
        case .ready(let r, _):
            return updater.installsAutomatically && updater.checksAutomatically
                ? T("Exit \(r.version) is downloaded and installs itself while you're away.", "Exit \(r.version) 已下载，会在你离开电脑时自动装上。")
                : T("Exit \(r.version) is downloaded.", "Exit \(r.version) 已下载。")
        case .installing(let r): return T("Installing Exit \(r.version)…", "正在安装 Exit \(r.version)…")
        case .installed(let r): return T("Exit \(r.version) is installed. Relaunch to use it.", "Exit \(r.version) 已装好，重新打开后生效。")
        }
    }
}
