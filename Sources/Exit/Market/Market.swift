import AppKit
import Combine
import CryptoKit

// MARK: - Index

/// One effect listed in a market's index.json.
struct MarketEntry: Codable, Hashable {
    let id: String
    let name: String
    let nameZh: String?
    let description: String?
    let descriptionZh: String?
    let author: String?
    let events: [String]?
    let duration: Double?
    let requires: String?
    /// Path of the .metal file, relative to the market's base URL.
    let file: String
    let preview: String?
    let sha256: String
    let sourceUrl: String?

    var displayName: String { Lang.isChinese ? (nameZh ?? name) : name }
    var displayDescription: String? { Lang.isChinese ? (descriptionZh ?? description) : description }
    var windowEvents: [WindowEvent] {
        (events ?? ["close", "quit", "minimize"]).compactMap(WindowEvent.init(key:)).sorted { $0.rawValue < $1.rawValue }
    }
    var isCompatible: Bool { requires.map(AppVersion.satisfies) ?? true }
    var checksum: String { sha256.lowercased() }
    /// The effect's page, if it's a web link.
    var webURL: URL? { URL.web(sourceUrl) }

    /// Index entries are untrusted: `id` becomes a file name and `file` part of a URL.
    var isWellFormed: Bool {
        Self.isValidID(id) && Self.isRelativeFile(file)
            && sha256.count == 64 && sha256.allSatisfy(\.isHexDigit)
    }

    /// A plain file name: lowercase letters, digits, "-" and "_", nothing that walks out of a folder.
    static func isValidID(_ id: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard (1...64).contains(id.count), id != "prelude", let first = id.first,
              first.isLetter || first.isNumber else { return false }
        return id.allSatisfy(allowed.contains)
    }

    /// "effects/x.metal": relative, no "..", no scheme, no query.
    static func isRelativeFile(_ path: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./")
        guard path.hasSuffix(".metal"), !path.hasPrefix("/"), path.allSatisfy(allowed.contains) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

extension URL {
    /// An http(s) link from untrusted text, or nil: never a file or app URL.
    static func web(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }
}

/// A market's index.json (see github.com/kadaliao/exit-effects).
struct MarketIndex: Decodable {
    static let supportedFormat = 1

    let format: Int
    let name: String?
    let homepage: String?
    /// When the index was built (ISO 8601), to spot a stale mirror.
    let updated: String?
    /// Other base URLs that serve the same files, tried when the main one fails.
    let mirrors: [String]?
    /// Well-formed entries only, first of each id; the rest are skipped, not fatal.
    let effects: [MarketEntry]

    private enum CodingKeys: String, CodingKey { case format, name, homepage, updated, mirrors, effects }

    /// Consumes one array element of any shape.
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        homepage = try? c.decodeIfPresent(String.self, forKey: .homepage)
        updated = try? c.decodeIfPresent(String.self, forKey: .updated)
        mirrors = try? c.decodeIfPresent([String].self, forKey: .mirrors)
        var list: [MarketEntry] = []
        var seen = Set<String>()
        var items = try c.nestedUnkeyedContainer(forKey: .effects)
        while !items.isAtEnd {
            if let e = try? items.decode(MarketEntry.self) {
                if e.isWellFormed && seen.insert(e.id).inserted { list.append(e) }
            } else {
                _ = try? items.decode(Skip.self)
            }
        }
        effects = list
    }

    static func decode(_ data: Data) throws -> MarketIndex {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let index: MarketIndex
        do { index = try d.decode(MarketIndex.self, from: data) }
        catch { throw MarketError.badIndex(error.localizedDescription) }
        guard index.format <= supportedFormat else {
            throw MarketError.badIndex(T("it needs a newer Exit (format \(index.format)).", "需要更新版本的 Exit（格式 \(index.format)）。"))
        }
        return index
    }
}

/// Where effects come from: the official market, or any other folder with an index.json.
struct MarketSource: Hashable, Identifiable {
    /// The folder that holds index.json, ending in "/".
    let base: URL
    var id: String { base.absoluteString }

    static let official = MarketSource(base: URL(string: "https://kadaliao.github.io/exit-effects/")!)
    static let officialMirrors = [URL(string: "https://cdn.jsdelivr.net/gh/kadaliao/exit-effects@gh-pages/")!]

    var isOfficial: Bool { self == .official }

    private init(base: URL) { self.base = base }

    /// Accepts "example.com/fx", "https://example.com/fx/" or ".../index.json".
    init?(string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard var url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        if url.pathExtension.lowercased() == "json" { url = url.deletingLastPathComponent() }
        var text = url.absoluteString
        if !text.hasSuffix("/") { text += "/" }
        guard let base = URL(string: text) else { return nil }
        self.base = base
    }

    var title: String {
        isOfficial ? T("Exit Effects (official)", "Exit 特效市场（官方）") : base.absoluteString
    }

    /// Folder name for this source's cached files.
    var cacheKey: String {
        let raw = (base.host ?? "") + (base.port.map { "-\($0)" } ?? "") + base.path
        return String(raw.map { $0.isLetter || $0.isNumber ? $0 : "-" }).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// An effect as offered by one source.
struct MarketItem: Identifiable, Hashable {
    let source: MarketSource
    let entry: MarketEntry
    var id: String { source.id + "#" + entry.id }
    /// Changes when the file does, so previews follow updates.
    var versionKey: String { id + "@" + entry.checksum }
}

/// What Exit installed from a market (Market/installed.json).
struct InstalledEffect: Codable {
    var source: String
    var sha256: String
}

enum MarketError: LocalizedError {
    case unreachable(String)
    case badIndex(String)
    case checksum
    case otherSource

    var errorDescription: String? {
        switch self {
        case .unreachable(let why): T("Couldn’t reach the market: \(why)", "连不上特效市场：\(why)")
        case .badIndex(let why): T("The market’s index.json can’t be used: \(why)", "特效市场的 index.json 用不了：\(why)")
        case .checksum: T("The download doesn’t match the market’s checksum. Try again later.", "下载的文件和市场的校验值不符，请稍后再试。")
        case .otherSource: T("An effect with this name is already installed from another source. Uninstall it first.",
                             "已经从别的来源装了同名特效，请先卸载它。")
        }
    }
}

// MARK: - Store

/// Lists, installs and updates effects from markets.
@MainActor
final class MarketStore: ObservableObject {
    static let shared = MarketStore()

    enum Status: Equatable {
        case notInstalled
        case installed
        case updateAvailable
        /// Needs a newer Exit.
        case incompatible(String)
        /// An effect with this file name is already installed from another source.
        case otherSource
    }

    @Published private(set) var items: [MarketItem] = []
    @Published private(set) var loading = false
    @Published private(set) var errors: [String: String] = [:]        // source id → message
    @Published private(set) var installed: [String: InstalledEffect] = [:]
    @Published private(set) var busy: Set<String> = []                 // item ids being installed
    @Published private(set) var previews: [String: Effect] = [:]       // item version key → compiled preview
    @Published private(set) var previewErrors: [String: String] = [:]
    /// Names installed automatically by the last refresh.
    @Published private(set) var autoInstalled: [String] = []
    @Published var actionError: String?

    private let settings = Settings.shared
    private var indexes: [String: MarketIndex] = [:]
    /// The base URL that last answered for each source, tried first for its files.
    private var workingBase: [String: URL] = [:]
    private var lastRefresh: Date?
    private var refreshAgain = false
    private var timer: Timer?
    @Published private var previewLoads: Set<String> = []
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 60
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["User-Agent": "Exit/\(AppVersion.current ?? "dev")"]
        return URLSession(configuration: c)
    }()

    private static var manifestURL: URL { Paths.marketEffects.appendingPathComponent("installed.json") }

    private init() {
        let saved = (try? JSONDecoder().decode([String: InstalledEffect].self, from: Data(contentsOf: Self.manifestURL))) ?? [:]
        installed = saved.filter { MarketEntry.isValidID($0.key) }
        // Show the last known listing right away, even offline.
        for source in sources {
            if let data = try? Data(contentsOf: cacheDir(source).appendingPathComponent("index.json")),
               let index = try? MarketIndex.decode(data) {
                indexes[source.id] = index
            }
        }
        rebuildItems()
    }

    var sources: [MarketSource] {
        var seen = Set<String>()
        return ([.official] + settings.marketSources.compactMap(MarketSource.init(string:))).filter { seen.insert($0.id).inserted }
    }

    // MARK: Refreshing

    /// Background refresh at launch and every few hours — only when there's something to keep
    /// up to date or the user subscribed to new effects, so an unused market costs nothing.
    func startAutoRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in MarketStore.shared.backgroundRefresh() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.backgroundRefresh() }
    }

    private func backgroundRefresh() {
        let wanted = settings.marketAutoInstall || (settings.marketAutoUpdate && !installed.isEmpty)
        if wanted { Task { await refresh() } }
    }

    func refreshIfStale() {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 600 { return }
        Task { await refresh() }
    }

    /// After the user adds or removes a source.
    func sourcesChanged() {
        rebuildItems()
        Task { await refresh() }
    }

    /// Fetches every source's index. `automatic: false` only lists (no updates or subscriptions),
    /// for the command line.
    func refresh(automatic: Bool = true) async {
        guard !loading else { refreshAgain = true; return }
        loading = true
        autoInstalled = []
        var anyOK = false
        var changedFiles = false
        for source in sources {
            do {
                let (fetched, data, base) = try await fetchIndex(source)
                // A stale mirror must not roll the listing (and installed effects) back.
                var index = fetched
                if let old = indexes[source.id], let was = old.updated, let now = fetched.updated, now < was {
                    index = old
                } else {
                    try? data.write(to: cacheDir(source).appendingPathComponent("index.json"), options: .atomic)
                }
                indexes[source.id] = index
                workingBase[source.id] = base
                errors[source.id] = nil
                anyOK = true
                rebuildItems()
                if automatic {
                    // A marker for the source itself: the first listing is the baseline, not "new".
                    let firstLook = settings.marketSeen.insert(source.id + "#").inserted
                    if await afterRefresh(source, index: index, firstLook: firstLook) { changedFiles = true }
                }
            } catch {
                errors[source.id] = error.localizedDescription
            }
        }
        if changedFiles { EffectLibrary.shared.rescan() }
        // Forget sources the user removed.
        let ids = Set(sources.map(\.id))
        indexes = indexes.filter { ids.contains($0.key) }
        errors = errors.filter { ids.contains($0.key) }
        rebuildItems()
        if anyOK { lastRefresh = Date() }
        loading = false
        if refreshAgain {
            refreshAgain = false
            await refresh(automatic: automatic)
        }
    }

    /// Updates installed effects and, when subscribed, installs new ones. Returns whether any file changed.
    private func afterRefresh(_ source: MarketSource, index: MarketIndex, firstLook: Bool) async -> Bool {
        let listed = index.effects.map { MarketItem(source: source, entry: $0) }
        var changed = false
        if settings.marketAutoUpdate {
            for item in listed where status(of: item) == .updateAvailable {
                if (try? await install(item, rescan: false)) != nil { changed = true }
            }
        }
        // Subscribed: install what's new since last time (never the backlog on the first look).
        // An item counts as seen once it's installed; one that failed or needs a newer Exit
        // is tried again next time.
        var names: [String] = []
        for item in listed where !settings.marketSeen.contains(item.id) {
            if !settings.marketAutoInstall || firstLook {
                settings.marketSeen.insert(item.id)
                continue
            }
            switch status(of: item) {
            case .notInstalled:
                if (try? await install(item, rescan: false)) != nil {
                    names.append(item.entry.displayName)
                    changed = true
                    settings.marketSeen.insert(item.id)
                }
            case .incompatible:
                break
            default:
                settings.marketSeen.insert(item.id)
            }
        }
        if !names.isEmpty { autoInstalled += names }
        return changed
    }

    private func rebuildItems() {
        items = sources.flatMap { source in
            (indexes[source.id]?.effects ?? []).map { MarketItem(source: source, entry: $0) }
        }
    }

    /// The source's own URL first, then its mirrors; the one that worked last time goes first.
    private func bases(_ source: MarketSource) -> [URL] {
        var list = [source.base]
        list += source.isOfficial ? MarketSource.officialMirrors
            : (indexes[source.id]?.mirrors ?? []).compactMap { URL.web($0.hasSuffix("/") ? $0 : $0 + "/") }
        if let w = workingBase[source.id], let i = list.firstIndex(of: w) { list.insert(list.remove(at: i), at: 0) }
        var seen = Set<URL>()
        return list.filter { seen.insert($0).inserted }
    }

    private func fetchIndex(_ source: MarketSource) async throws -> (MarketIndex, Data, URL) {
        var lastError: Error = MarketError.unreachable("?")
        for base in bases(source) {
            do {
                let data = try await get(base.appendingPathComponent("index.json"))
                return (try MarketIndex.decode(data), data, base)
            } catch let e as MarketError {
                lastError = e
            } catch {
                lastError = MarketError.unreachable(error.localizedDescription)
            }
        }
        throw lastError
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MarketError.unreachable("HTTP \(http.statusCode)")
        }
        return data
    }

    private func cacheDir(_ source: MarketSource) -> URL {
        let dir = Paths.marketCache.appendingPathComponent(source.cacheKey, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where an installed market effect lives; nil for an id that isn't a plain file name.
    private func installedFile(_ id: String) -> URL? {
        guard MarketEntry.isValidID(id) else { return nil }
        let url = Paths.marketEffects.appendingPathComponent("\(id).metal")
        return url.deletingLastPathComponent().standardizedFileURL == Paths.marketEffects.standardizedFileURL ? url : nil
    }

    // MARK: Status

    func status(of item: MarketItem) -> Status {
        if !item.entry.isCompatible { return .incompatible(item.entry.requires ?? "") }
        guard let record = installed[item.entry.id], let file = installedFile(item.entry.id),
              FileManager.default.fileExists(atPath: file.path)
        else { return .notInstalled }
        if record.source != item.source.id { return .otherSource }
        return record.sha256.lowercased() == item.entry.checksum ? .installed : .updateAvailable
    }

    /// The user has their own file with this name, which plays instead of the market one.
    func isShadowedByUser(_ item: MarketItem) -> Bool {
        FileManager.default.fileExists(atPath: Paths.userEffects.appendingPathComponent("\(item.entry.id).metal").path)
    }

    // MARK: Downloading and installing

    /// Downloads (or reuses) the item's source after checking it against the index's SHA-256.
    func download(_ item: MarketItem) async throws -> URL {
        let entry = item.entry
        let dest = cacheDir(item.source).appendingPathComponent("\(entry.id)-\(entry.checksum.prefix(12)).metal")
        if let data = try? Data(contentsOf: dest), Self.sha256(data) == entry.checksum { return dest }
        var lastError: Error = MarketError.unreachable("?")
        var mismatch = false
        for base in bases(item.source) {
            let url = base.appendingPathComponent(entry.file)   // `file` is checked to be a plain relative path
            do {
                let data = try await get(url)
                guard Self.sha256(data) == entry.checksum else { mismatch = true; continue }
                try data.write(to: dest, options: .atomic)
                return dest
            } catch {
                lastError = error
            }
        }
        // A file that arrived but didn't match matters more than a mirror that was down.
        throw mismatch ? MarketError.checksum : lastError
    }

    @discardableResult
    func install(_ item: MarketItem, rescan: Bool = true) async throws -> URL {
        if status(of: item) == .otherSource { throw MarketError.otherSource }
        guard let dest = installedFile(item.entry.id) else { throw MarketError.badIndex(item.entry.id) }
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        let cached = try await download(item)
        try Data(contentsOf: cached).write(to: dest, options: .atomic)
        installed[item.entry.id] = InstalledEffect(source: item.source.id, sha256: item.entry.checksum)
        saveManifest()
        if rescan { EffectLibrary.shared.rescan() }
        return dest
    }

    /// Install from a button: errors go to `actionError` for the pane to show.
    func installFromUI(_ item: MarketItem) {
        Task {
            do { try await install(item) }
            catch { actionError = error.localizedDescription }
        }
    }

    @discardableResult
    func uninstall(id: String) -> Bool {
        guard let file = installedFile(id) else { return false }
        try? FileManager.default.removeItem(at: file)
        installed[id] = nil
        saveManifest()
        EffectLibrary.shared.rescan()
        return true
    }

    private func saveManifest() {
        if let data = try? JSONEncoder().encode(installed) { try? data.write(to: Self.manifestURL, options: .atomic) }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Previews

    func preview(for item: MarketItem) -> Effect? { previews[item.versionKey] }
    func isLoadingPreview(_ item: MarketItem) -> Bool { previewLoads.contains(item.versionKey) }
    func previewError(for item: MarketItem) -> String? { previewErrors[item.versionKey] }

    /// Downloads and compiles an item so its card can show it live and "Try" can play it.
    func loadPreview(_ item: MarketItem) {
        let key = item.versionKey
        guard previews[key] == nil, !previewLoads.contains(key) else { return }
        guard item.entry.isCompatible else {
            previewErrors[key] = T("Needs Exit \(item.entry.requires ?? "") or later.", "需要 Exit \(item.entry.requires ?? "") 或更新版本。")
            return
        }
        previewLoads.insert(key)
        Task {
            do {
                let url = try await download(item)
                let source = try String(contentsOf: url, encoding: .utf8)
                EffectLibrary.shared.compileDetached(source: source, fileName: "\(item.entry.id).metal") { [weak self] result in
                    let effect = Effect(id: item.entry.id, url: url, origin: .market,
                                        meta: EffectMeta.parse(source: source, fallbackName: item.entry.id), modified: Date())
                    effect.pipeline = result.pipeline
                    effect.error = result.error
                    effect.sourceHash = result.sourceHash
                    effect.stoppedByGuard = result.guarded
                    if result.pipeline != nil { effect.revision = 1 }
                    self?.previews[key] = effect
                    self?.previewErrors[key] = nil
                    self?.previewLoads.remove(key)
                }
            } catch {
                previewErrors[key] = error.localizedDescription
                previewLoads.remove(key)
            }
        }
    }

    func homepage(for source: MarketSource) -> URL? {
        URL.web(indexes[source.id]?.homepage) ?? source.base
    }
}
