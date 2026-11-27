import AppKit
import os

/// Interface language: follow macOS, or a fixed one picked in Settings → General.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", chinese = "zh-Hans"
    var id: String { rawValue }

    /// Each language is named in itself, so it can be found whatever the current language is.
    var title: String {
        switch self {
        case .system: T("System (\(Lang.systemPrefersChinese ? "简体中文" : "English"))",
                        "跟随系统（\(Lang.systemPrefersChinese ? "简体中文" : "English")）")
        case .english: "English"
        case .chinese: "简体中文"
        }
    }
}

/// Picks the Chinese string when the chosen (or system) language is Chinese.
enum Lang {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var chinese = resolve(UserDefaults.standard.string(forKey: "language"))

    static var isChinese: Bool { lock.withLock { chinese } }

    static func apply(_ language: AppLanguage) {
        lock.withLock { chinese = resolve(language.rawValue) }
    }

    private static func resolve(_ language: String?) -> Bool {
        switch AppLanguage(rawValue: language ?? "") ?? .system {
        case .english: false
        case .chinese: true
        case .system: systemPrefersChinese
        }
    }

    /// The Mac's own language list, ignoring the override Exit keeps for its system strings.
    static var systemPrefersChinese: Bool {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return (global ?? Locale.preferredLanguages).first?.hasPrefix("zh") ?? false
    }
}

/// Light or dark for Exit's own windows.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: T("System", "跟随系统")
        case .light: T("Light", "浅色")
        case .dark: T("Dark", "深色")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Whether macOS itself is dark — for pictures of other apps' windows, which ignore Exit's choice.
    static var systemIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
}

@inline(__always) func T(_ en: String, _ zh: String) -> String { Lang.isChinese ? zh : en }

let log = Logger(subsystem: "io.github.kadaliao.Exit", category: "app")

/// What happened to a window.
enum WindowEvent: Int, CaseIterable, Codable, Identifiable {
    case close = 0
    case open = 1
    case minimize = 2
    case quit = 3

    var id: Int { rawValue }

    var key: String {
        switch self {
        case .close: "close"
        case .open: "open"
        case .minimize: "minimize"
        case .quit: "quit"
        }
    }

    init?(key: String) {
        guard let e = WindowEvent.allCases.first(where: { $0.key == key.lowercased() }) else { return nil }
        self = e
    }

    var title: String {
        switch self {
        case .close: T("Close window", "关闭窗口")
        case .open: T("Open window", "打开窗口")
        case .minimize: T("Minimize", "最小化")
        case .quit: T("Quit app", "退出 App")
        }
    }

    var symbol: String {
        switch self {
        case .close: "xmark.circle"
        case .open: "plus.circle"
        case .minimize: "minus.circle"
        case .quit: "power.circle"
        }
    }
}

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Exit", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Set by `--effects-dir` (CI): read user effects from there and ignore installed market effects.
    nonisolated(unsafe) static var effectsDirOverride: URL?

    static var userEffects: URL { effectsDirOverride ?? defaultUserEffects }

    private static let defaultUserEffects: URL = {
        let url = support.appendingPathComponent("Effects", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Effects installed from a market. Exit manages this folder; edits go to a copy in `userEffects`.
    static let marketEffects: URL = {
        let url = support.appendingPathComponent("Market", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Downloaded market indexes and effect sources (safe to delete).
    static let marketCache: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("io.github.kadaliao.Exit/Market", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Built-in effects: inside the app bundle, or the repo's Effects/ folder when run from source.
    static let builtInEffects: URL = {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Effects", isDirectory: true),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("prelude.metal").path) {
            return res
        }
        // Sources/Exit/Core/Core.swift -> repo root
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("Effects", isDirectory: true)
    }()

    /// The effect-authoring guide, also used as the AI system prompt.
    static let authoringGuide: URL = {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("EFFECTS.md"),
           FileManager.default.fileExists(atPath: res.path) {
            return res
        }
        return builtInEffects.deletingLastPathComponent().appendingPathComponent("docs/EFFECTS.md")
    }()
}

/// Exit's own version, for `@requires`.
enum AppVersion {
    /// nil when run from source without an app bundle: then every effect is allowed.
    static let current: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    /// Whether this copy of Exit is at least `version` ("0.3", "0.3.0", "1.2.10").
    static func satisfies(_ version: String) -> Bool {
        guard let current else { return true }
        return compare(current, version) != .orderedAscending
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// Global screen geometry helpers. AX and CGWindow use a top-left origin anchored at the
/// primary screen; AppKit uses a bottom-left origin.
enum ScreenGeometry {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }

    /// Converts a top-left-origin global rect (AX / CGWindow) into AppKit coordinates.
    static func toAppKit(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Converts an AppKit rect into top-left-origin global coordinates (the flip is its own inverse).
    static func toGlobal(_ r: CGRect) -> CGRect { toAppKit(r) }

    static func toAppKit(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// The screen that contains most of the given AppKit rect.
    static func screen(for appKitRect: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for s in NSScreen.screens {
            let i = s.frame.intersection(appKitRect)
            let area = i.isNull ? 0 : i.width * i.height
            if area > bestArea { bestArea = area; best = s }
        }
        return best ?? NSScreen.screens.first(where: { $0.frame.contains(appKitRect.center) }) ?? NSScreen.main
    }
}
