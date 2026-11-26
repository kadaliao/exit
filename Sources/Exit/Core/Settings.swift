import AppKit
import Combine

/// Which effect plays for an event.
enum Assignment: Codable, Hashable {
    case off
    case random
    case effect(String)

    var effectID: String? { if case .effect(let id) = self { return id } else { return nil } }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case claudeCode
    case api
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claudeCode: T("Claude Code (local CLI)", "Claude Code（本机 CLI）")
        case .api: T("Anthropic API key", "Anthropic API Key")
        }
    }
}

/// All user preferences, persisted to UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    @Published var assignments: [WindowEvent: Assignment] { didSet { save(assignments, "assignments") } }
    /// Effects excluded from random shuffle.
    @Published var shuffleExcluded: Set<String> { didSet { save(shuffleExcluded, "shuffleExcluded") } }
    @Published var excludedApps: [String] { didSet { d.set(excludedApps, forKey: "excludedApps") } }
    @Published var speed: Double { didSet { d.set(speed, forKey: "speed") } }
    /// Hold ⌘W / ⌘Q / ⌘M and close-button clicks for a few milliseconds to grab the true last frame.
    @Published var preciseCapture: Bool { didSet { d.set(preciseCapture, forKey: "preciseCapture") } }
    /// Periodically refresh the focused window's snapshot so programmatic closes look right too.
    @Published var refreshFocused: Bool { didSet { d.set(refreshFocused, forKey: "refreshFocused") } }
    @Published var minWindowSize: Double { didSet { d.set(minWindowSize, forKey: "minWindowSize") } }
    @Published var respectReduceMotion: Bool { didSet { d.set(respectReduceMotion, forKey: "respectReduceMotion") } }
    @Published var aiProvider: AIProvider { didSet { d.set(aiProvider.rawValue, forKey: "aiProvider") } }
    @Published var aiModel: String { didSet { d.set(aiModel, forKey: "aiModel") } }
    /// low / medium / high — how hard Claude thinks before writing the shader.
    @Published var aiEffort: String { didSet { d.set(aiEffort, forKey: "aiEffort") } }
    var playCount: Int { didSet { d.set(playCount, forKey: "playCount") } }

    private init() {
        d.register(defaults: [
            "enabled": true,
            "speed": 1.0,
            "preciseCapture": true,
            "refreshFocused": false,
            "minWindowSize": 140.0,
            "respectReduceMotion": true,
            "aiProvider": AIProvider.claudeCode.rawValue,
            "aiModel": "claude-opus-5-5",
            "aiEffort": "medium",
        ])
        enabled = d.bool(forKey: "enabled")
        speed = d.double(forKey: "speed")
        preciseCapture = d.bool(forKey: "preciseCapture")
        refreshFocused = d.bool(forKey: "refreshFocused")
        minWindowSize = d.double(forKey: "minWindowSize")
        respectReduceMotion = d.bool(forKey: "respectReduceMotion")
        aiProvider = AIProvider(rawValue: d.string(forKey: "aiProvider") ?? "") ?? .claudeCode
        aiModel = d.string(forKey: "aiModel") ?? "claude-opus-5-5"
        aiEffort = d.string(forKey: "aiEffort") ?? "medium"
        excludedApps = d.stringArray(forKey: "excludedApps") ?? []
        playCount = d.integer(forKey: "playCount")
        shuffleExcluded = Settings.load(Set<String>.self, "shuffleExcluded", d) ?? []
        assignments = Settings.load([WindowEvent: Assignment].self, "assignments", d) ?? [
            .close: .random,
            .quit: .random,
            .open: .off,
            .minimize: .off,
        ]
    }

    func assignment(for event: WindowEvent) -> Assignment { assignments[event] ?? .off }

    private func save<V: Encodable>(_ value: V, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }

    private static func load<V: Decodable>(_ type: V.Type, _ key: String, _ d: UserDefaults) -> V? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(V.self, from: data)
    }
}
