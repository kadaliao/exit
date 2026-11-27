import AppKit
import Combine
import CoreServices
import CryptoKit
import Metal

/// Metadata parsed from the `// @key value` header of an effect file.
struct EffectMeta {
    var name: String
    var nameZh: String?
    var author: String?
    var description: String?
    var descriptionZh: String?
    var duration: Double = 0.7
    /// Extra canvas around the window, in points. nil = the whole screen.
    var padding: CGFloat? = 160
    var events: Set<WindowEvent> = [.close, .quit, .minimize]
    /// Oldest Exit version the effect works with (`@requires 0.3`).
    var requires: String?

    var displayName: String { Lang.isChinese ? (nameZh ?? name) : name }
    var displayDescription: String? { Lang.isChinese ? (descriptionZh ?? description) : description }

    static func parse(source: String, fallbackName: String) -> EffectMeta {
        var m = EffectMeta(name: fallbackName)
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(60) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("//") else {
                if line.isEmpty { continue } else { break }
            }
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("@") else { continue }
            let parts = body.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let key = parts.first.map(String.init) else { continue }
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch key.lowercased() {
            case "name": m.name = value
            case "name.zh": m.nameZh = value
            case "author": m.author = value
            case "description": m.description = value
            case "description.zh": m.descriptionZh = value
            case "duration": if let v = Double(value) { m.duration = min(max(v, 0.15), 6) }
            case "padding":
                if value.lowercased() == "screen" { m.padding = nil }
                else if let v = Double(value) { m.padding = CGFloat(min(max(v, 0), 2000)) }
            case "requires": if !value.isEmpty { m.requires = value }
            case "events":
                let set = Set(value.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { WindowEvent(key: String($0)) })
                if !set.isEmpty { m.events = set }
            default: break
            }
        }
        return m
    }
}

/// Where an effect file lives. A user file shadows a market one, which shadows a built-in one.
enum EffectOrigin {
    case user, market, builtIn
}

/// One loaded effect: its source, metadata and compiled pipeline (or compile error).
final class Effect: Identifiable, ObservableObject {
    let id: String
    let url: URL
    let origin: EffectOrigin
    @Published var meta: EffectMeta
    @Published var pipeline: MTLRenderPipelineState?
    @Published var error: String?
    var modified: Date
    /// Bumped on every successful recompile so previews can restart.
    @Published var revision = 0

    init(id: String, url: URL, origin: EffectOrigin, meta: EffectMeta, modified: Date) {
        self.id = id
        self.url = url
        self.origin = origin
        self.meta = meta
        self.modified = modified
    }

    /// Consecutive frames over `EffectGuard.frameLimit` (main thread).
    var slowFrames = 0
    /// Hash of the source the current pipeline was built from, so the guard blames that version.
    var sourceHash: String?
    /// Switched off by `EffectGuard`; Settings offers to turn it back on.
    @Published var stoppedByGuard = false

    var isReady: Bool { pipeline != nil }
    var isBuiltIn: Bool { origin == .builtIn }
}

/// Effects Exit switched off because their GPU work hung or crawled, remembered by source hash
/// so a hung shader doesn't hang the Mac again on the next launch. Editing the file clears it.
enum EffectGuard {
    private static let key = "disabledEffects"

    /// A single frame slower than this stops the effect (normal frames take a few milliseconds).
    static let frameLimit: Double = 0.25

    static func hash(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func reason(id: String, source: String) -> String? {
        guard let entry = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]])?[id],
              entry.count == 2, entry[0] == hash(source) else { return nil }
        return entry[1]
    }

    /// Remembers that this version of the effect hung or faulted the GPU.
    static func remember(id: String, hash: String, reason: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        all[id] = [hash, reason]
        UserDefaults.standard.set(all, forKey: key)
    }

    static func forget(id: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        all[id] = nil
        UserDefaults.standard.set(all, forKey: key)
    }

    /// Watches one frame of an effect and switches the effect off when its own GPU work hangs or
    /// faults, or keeps crawling. One slow frame can be another app hogging the GPU, so slow
    /// frames only count after a few in a row; frames lost to someone else's GPU crash never count.
    static func watch(_ cb: MTLCommandBuffer, effect: Effect) {
        cb.addCompletedHandler { cb in
            let seconds = cb.gpuEndTime - cb.gpuStartTime
            let code = (cb.error as NSError?).flatMap { MTLCommandBufferError.Code(rawValue: UInt($0.code)) }
            let fatal = cb.status == .error && (code == .timeout || code == .pageFault)
            let slow = cb.status == .completed && seconds > frameLimit
            DispatchQueue.main.async {
                if fatal {
                    EffectLibrary.shared.disable(effect, persist: true, reason: T(
                        "Exit switched it off: the GPU gave up on it (\(cb.error?.localizedDescription ?? "timeout")).",
                        "Exit 已停用它：GPU 处理它时出错（\(cb.error?.localizedDescription ?? "超时")）。"))
                } else if cb.status == .completed {
                    effect.slowFrames = slow ? effect.slowFrames + 1 : 0
                    // Crawling can be the machine's fault (another app, thermal limits): this session only.
                    if effect.slowFrames >= 3 {
                        EffectLibrary.shared.disable(effect, persist: false, reason: T(
                            String(format: "Exit switched it off: frames took %.0f ms on the GPU.", seconds * 1000),
                            String(format: "Exit 已停用它：每帧在 GPU 上要花 %.0f 毫秒。", seconds * 1000)))
                    }
                }
            }
        }
    }
}

/// Loads, compiles and hot-reloads effects from the bundle and the user's Effects folder.
final class EffectLibrary: ObservableObject {
    static let shared = EffectLibrary()

    @Published private(set) var effects: [Effect] = []
    let device: MTLDevice
    private let compileQueue = DispatchQueue(label: "exit.compile", qos: .userInitiated)
    private var prelude: String = ""
    private var stream: FSEventStreamRef?

    private init() {
        guard let dev = MTLCreateSystemDefaultDevice() else { fatalError("Metal is not available") }
        device = dev
    }

    func effect(id: String) -> Effect? { effects.first { $0.id == id } }

    func readyEffects(for event: WindowEvent) -> [Effect] {
        effects.filter { $0.isReady && $0.meta.events.contains(event) }
    }

    // MARK: Loading

    /// Loads everything synchronously (used at launch and by CLI tools).
    func loadAll(synchronously: Bool = false) {
        prelude = (try? String(contentsOf: Paths.builtInEffects.appendingPathComponent("prelude.metal"), encoding: .utf8)) ?? ""
        var list: [Effect] = []
        var seen = Set<String>()
        // User effects shadow market effects, which shadow built-ins with the same file name.
        for (dir, origin) in Self.folders {
            for url in metalFiles(in: dir) {
                let id = url.deletingPathExtension().lastPathComponent
                guard !seen.contains(id) else { continue }
                seen.insert(id)
                let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let e = Effect(id: id, url: url, origin: origin,
                               meta: EffectMeta.parse(source: src, fallbackName: id),
                               modified: modificationDate(url))
                list.append(e)
            }
        }
        effects = Self.sorted(list)
        for e in list { compile(e, synchronously: synchronously) }
    }

    /// Effect folders, highest priority first.
    private static var folders: [(URL, EffectOrigin)] {
        Paths.effectsDirOverride != nil
            ? [(Paths.userEffects, .user), (Paths.builtInEffects, .builtIn)]
            : [(Paths.userEffects, .user), (Paths.marketEffects, .market), (Paths.builtInEffects, .builtIn)]
    }

    private static func sorted(_ list: [Effect]) -> [Effect] {
        list.sorted { a, b in
            if a.isBuiltIn != b.isBuiltIn { return !a.isBuiltIn }   // user and market effects first
            return a.meta.displayName.localizedCompare(b.meta.displayName) == .orderedAscending
        }
    }

    /// Re-sorts after the interface language changes the display names.
    func sortByName() { effects = Self.sorted(effects) }

    private func metalFiles(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { $0.pathExtension == "metal" && $0.lastPathComponent != "prelude.metal" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: Compiling

    struct CompileResult {
        let pipeline: MTLRenderPipelineState?
        let error: String?
        /// The source was switched off by `EffectGuard` earlier.
        var guarded = false
        var sourceHash: String?
    }

    /// Compiles raw effect source (used by AI generation before anything is saved).
    func compile(source: String, fileName: String) -> CompileResult {
        let full = prelude + "\n#line 1 \"\(fileName)\"\n" + source
        do {
            let opts = MTLCompileOptions()
            let lib = try device.makeLibrary(source: full, options: opts)
            guard let vfn = lib.makeFunction(name: "exit_vertex"),
                  let ffn = lib.makeFunction(name: "exit_fragment") else {
                return CompileResult(pipeline: nil, error: "Missing entry points (did the file define `effect`?)")
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let ps = try device.makeRenderPipelineState(descriptor: desc)
            return CompileResult(pipeline: ps, error: nil)
        } catch {
            return CompileResult(pipeline: nil, error: Self.cleanCompilerLog(error.localizedDescription, fileName: fileName))
        }
    }

    /// Keeps only the diagnostics that point into the effect file.
    static func cleanCompilerLog(_ log: String, fileName: String) -> String {
        let lines = log.components(separatedBy: "\n")
        let relevant = lines.filter { $0.contains("error:") || $0.contains(fileName) }
        let text = (relevant.isEmpty ? lines : relevant).prefix(24).joined(separator: "\n")
        return text.replacingOccurrences(of: "Compilation failed: \n\n", with: "")
    }

    /// Compiles source that isn't in the library (market previews) on the compile queue.
    func compileDetached(source: String, fileName: String, completion: @escaping (CompileResult) -> Void) {
        compileQueue.async { [weak self] in
            guard let self else { return }
            let result = self.checked(source: source, id: (fileName as NSString).deletingPathExtension, fileName: fileName)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Compiles unless the effect needs a newer Exit or was switched off for hanging the GPU.
    private func checked(source: String, id: String, fileName: String) -> CompileResult {
        let hash = EffectGuard.hash(source)
        if let need = EffectMeta.parse(source: source, fallbackName: id).requires, !AppVersion.satisfies(need) {
            return CompileResult(pipeline: nil, error: T("Needs Exit \(need) or later.", "需要 Exit \(need) 或更新版本。"), sourceHash: hash)
        }
        if let why = EffectGuard.reason(id: id, source: source) {
            return CompileResult(pipeline: nil, error: why, guarded: true, sourceHash: hash)
        }
        var result = compile(source: source, fileName: fileName)
        result.sourceHash = hash
        return result
    }

    /// Stops an effect that hung or crawled on the GPU. A hang or fault is remembered for that
    /// version of the file across launches; a crawl only for this session.
    func disable(_ effect: Effect, persist: Bool, reason: String) {
        guard effect.pipeline != nil else { return }
        log.error("disabled \(effect.id, privacy: .public): \(reason, privacy: .public)")
        if persist, let hash = effect.sourceHash { EffectGuard.remember(id: effect.id, hash: hash, reason: reason) }
        effect.pipeline = nil
        effect.error = reason
        effect.stoppedByGuard = true
        objectWillChange.send()
    }

    /// "Turn Back On" for an effect the guard stopped.
    func reenable(_ effect: Effect) {
        EffectGuard.forget(id: effect.id)
        effect.slowFrames = 0
        effect.stoppedByGuard = false
        if effects.contains(where: { $0 === effect }) {
            compile(effect)
        } else if let src = try? String(contentsOf: effect.url, encoding: .utf8) {   // a market preview
            compileDetached(source: src, fileName: effect.url.lastPathComponent) { result in
                effect.pipeline = result.pipeline
                effect.error = result.error
                effect.sourceHash = result.sourceHash
                if result.pipeline != nil { effect.revision += 1 }
            }
        }
    }

    func compile(_ effect: Effect, synchronously: Bool = false) {
        let url = effect.url
        let work = { [weak self] in
            guard let self else { return }
            let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let meta = EffectMeta.parse(source: src, fallbackName: effect.id)
            let result = self.checked(source: src, id: effect.id, fileName: url.lastPathComponent)
            let apply = {
                effect.meta = meta
                effect.sourceHash = result.sourceHash
                effect.stoppedByGuard = result.guarded
                effect.slowFrames = 0
                effect.pipeline = result.pipeline
                effect.error = result.error
                if result.pipeline != nil { effect.revision += 1 }
                if let err = result.error { log.error("compile \(effect.id, privacy: .public): \(err, privacy: .public)") }
                self.objectWillChange.send()
            }
            if synchronously { apply() } else { DispatchQueue.main.async(execute: apply) }
        }
        if synchronously { work() } else { compileQueue.async(execute: work) }
    }

    // MARK: Hot reload

    func startWatching() {
        guard stream == nil else { return }
        let paths = Self.folders.map { $0.0.path } as CFArray
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let lib = Unmanaged<EffectLibrary>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { lib.rescan() }
        }
        stream = FSEventStreamCreate(nil, callback, &ctx, paths,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    /// Picks up added, removed and edited files.
    func rescan() {
        let newPrelude = (try? String(contentsOf: Paths.builtInEffects.appendingPathComponent("prelude.metal"), encoding: .utf8)) ?? prelude
        if newPrelude != prelude { loadAll(); return }

        var current: [String: URL] = [:]
        for (dir, _) in Self.folders.reversed() {   // lowest priority first, so higher ones win
            for url in metalFiles(in: dir) { current[url.deletingPathExtension().lastPathComponent] = url }
        }

        let known = Dictionary(uniqueKeysWithValues: effects.map { ($0.id, $0) })
        let structureChanged = Set(known.keys) != Set(current.keys)
            || known.contains { id, e in current[id] != e.url }
        if structureChanged { loadAll(); return }

        for e in effects where modificationDate(e.url) != e.modified {
            e.modified = modificationDate(e.url)
            compile(e)
        }
    }

    /// Copies an effect into the user folder so it can be edited; returns the new URL.
    @discardableResult
    func duplicateToUserFolder(_ effect: Effect, newID: String? = nil) -> URL? {
        let id = newID ?? effect.id
        let dest = Paths.userEffects.appendingPathComponent("\(id).metal")
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.copyItem(at: effect.url, to: dest)
        }
        rescan()
        return dest
    }

    /// Writes new effect source into the user folder.
    @discardableResult
    func saveUserEffect(id: String, source: String) -> URL? {
        let dest = Paths.userEffects.appendingPathComponent("\(id).metal")
        do {
            try source.write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            log.error("save effect failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        rescan()
        return dest
    }

    func uniqueUserID(base: String) -> String {
        let slug = base.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let root = slug.isEmpty ? "effect" : String(slug.prefix(40))
        var id = root
        var n = 2
        while FileManager.default.fileExists(atPath: Paths.userEffects.appendingPathComponent("\(id).metal").path)
                || effects.contains(where: { $0.id == id }) {
            id = "\(root)-\(n)"; n += 1
        }
        return id
    }
}
