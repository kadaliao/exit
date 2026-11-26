import AppKit
import Combine

/// Which effect plays for an event.
enum Assignment: Codable, Hashable {
    case off
    case random
    case effect(String)

    var effectID: String? { if case .effect(let id) = self { return id } else { return nil } }
}

/// All user preferences, persisted to UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    @Published var language: AppLanguage {
        didSet {
            d.set(language.rawValue, forKey: "language")
            Lang.apply(language)
            // System-provided text (text-field menus, open panels) follows from the next launch.
            if language == .system { d.removeObject(forKey: "AppleLanguages") } else { d.set([language.rawValue], forKey: "AppleLanguages") }
            EffectLibrary.shared.sortByName()
        }
    }
    @Published var appearance: AppAppearance {
        didSet {
            d.set(appearance.rawValue, forKey: "appearance")
            NSApp?.appearance = appearance.nsAppearance
        }
    }
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
    /// Where AI generation runs, e.g. "cli.codex" or "api.openai" (see `AIProvider`).
    @Published var aiProviderID: String { didSet { d.set(aiProviderID, forKey: "aiProvider") } }
    /// Model per provider ID; a missing entry means the provider's default.
    @Published var aiModels: [String: String] { didSet { d.set(aiModels, forKey: "aiModels") } }
    /// Base URL per API provider ID; a missing entry means the preset's URL.
    @Published var aiBaseURLs: [String: String] { didSet { d.set(aiBaseURLs, forKey: "aiBaseURLs") } }
    /// low / medium / high — how hard the model thinks before writing the shader.
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
            "aiEffort": "medium",
        ])
        enabled = d.bool(forKey: "enabled")
        language = AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .system
        appearance = AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        speed = d.double(forKey: "speed")
        preciseCapture = d.bool(forKey: "preciseCapture")
        refreshFocused = d.bool(forKey: "refreshFocused")
        minWindowSize = d.double(forKey: "minWindowSize")
        respectReduceMotion = d.bool(forKey: "respectReduceMotion")
        // 0.1.0 stored "claudeCode" / "api" and one model for both.
        var providerID = d.string(forKey: "aiProvider") ?? ""
        if providerID == "claudeCode" { providerID = "cli.claude" }
        if providerID == "api" { providerID = "api.anthropic" }
        hasChosenAIProvider = AIProvider(id: providerID) != nil
        aiProviderID = AIProvider(id: providerID) != nil ? providerID : "cli.claude"
        var models = d.dictionary(forKey: "aiModels") as? [String: String] ?? [:]
        if let old = d.string(forKey: "aiModel") {
            if models["cli.claude"] == nil { models["cli.claude"] = old }
            if models["api.anthropic"] == nil { models["api.anthropic"] = old }
            d.removeObject(forKey: "aiModel")
        }
        aiModels = models
        aiBaseURLs = d.dictionary(forKey: "aiBaseURLs") as? [String: String] ?? [:]
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

    /// false until the user picks an AI service, so the first installed CLI can be chosen for them.
    private(set) var hasChosenAIProvider: Bool

    var aiProvider: AIProvider {
        get { AIProvider(id: aiProviderID) ?? .cli(.claude) }
        set { aiProviderID = newValue.id; hasChosenAIProvider = true }
    }

    func aiModel(for p: AIProvider) -> String { aiModels[p.id] ?? p.defaultModel }

    func aiBaseURL(for p: AIProvider) -> String {
        guard case .api(let preset) = p else { return "" }
        let saved = (aiBaseURLs[p.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.isEmpty ? preset.baseURL : saved
    }

    private func save<V: Encodable>(_ value: V, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }

    private static func load<V: Decodable>(_ type: V.Type, _ key: String, _ d: UserDefaults) -> V? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(V.self, from: data)
    }
}
