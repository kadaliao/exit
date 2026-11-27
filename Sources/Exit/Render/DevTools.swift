import AppKit
import Metal
import SwiftUI

/// Command-line helpers for effect authors and CI:
///   Exit --check                          compile every effect, print errors
///   Exit --render-sheet out.png [--only a,b] [--frames 6] [--event open] [--placeholder]
///   Exit --bench [--max-ms 20]            GPU time per frame at Retina size
///   Exit --validate [--budget 7]          the AI generator's checks (seamless start, clean end, speed)
///   Exit --version
///   Exit --market [list | update | install ID | uninstall ID]   the effect market, from the terminal
///   Exit --market submit FILE|ID [--notes TEXT] [--wait] [--dry-run]   send an effect to the market (for agents)
/// Add `--effects-dir DIR` to read effects from DIR instead of your own folder (installed market
/// effects are skipped too), so CI and reviewers test exactly the files in front of them.
enum DevTools {
    static let commands = ["--check", "--render-sheet", "--bench", "--render-frames", "--render-sequence", "--validate",
                           "--generate", "--snapshot-ui", "--ai-ping", "--version", "--market"]

    static func run(_ args: [String]) -> Int32? {
        guard let cmd = args.first(where: { commands.contains($0) }) else { return nil }
        if cmd == "--version" {
            print(AppVersion.current ?? "dev")
            return 0
        }
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let dir = value("--effects-dir") {
            Paths.effectsDirOverride = URL(fileURLWithPath: dir, isDirectory: true).standardizedFileURL
        }
        let lib = EffectLibrary.shared
        lib.loadAll(synchronously: true)

        var effects = lib.effects
        if let only = value("--only") {
            let ids = Set(only.split(separator: ",").map(String.init))
            effects = effects.filter { ids.contains($0.id) }
        }
        let event = value("--event").flatMap(WindowEvent.init(key:))

        switch cmd {
        case "--check":
            var failed = 0
            for e in effects {
                if let err = e.error {
                    failed += 1
                    print("✗ \(e.id)\n\(err)\n")
                } else {
                    print("✓ \(e.id)  \(e.meta.name)  \(e.meta.duration)s  events=\(e.meta.events.map(\.key).sorted().joined(separator: ","))")
                }
            }
            return failed == 0 ? 0 : 1

        case "--render-sheet":
            guard let out = value("--render-sheet") else { print("usage: --render-sheet out.png"); return 2 }
            let frames = Int(value("--frames") ?? "6") ?? 6
            let placeholder = args.contains("--placeholder")
            if let event { effects = effects.filter { $0.meta.events.contains(event) } }
            guard let sheet = renderSheet(effects, frames: frames, event: event ?? .close, placeholder: placeholder) else {
                print("render failed"); return 1
            }
            do { try Images.writePNG(sheet, to: URL(fileURLWithPath: out)) } catch { print(error); return 1 }
            print("wrote \(out)")
            return 0

        case "--render-frames":
            // Writes individual full-size frames for one effect: --render-frames dir --only id
            guard let dir = value("--render-frames"), let e = effects.first, let ps = e.pipeline else { return 2 }
            let frames = Int(value("--frames") ?? "8") ?? 8
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let imgs = renderFrames(e, pipeline: ps, count: frames, event: event ?? .close, placeholder: false, scale: 2)
            for (i, img) in imgs.enumerated() {
                try? Images.writePNG(img, to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%@-%02d.png", e.id, i)))
            }
            print("wrote \(imgs.count) frames to \(dir)")
            return 0

        case "--render-sequence":
            // Renders one effect onto your own window picture as a transparent PNG sequence, for videos:
            //   --render-sequence dir --only id --window win.png --stage 1920x1080 --rect x,y,w,h
            //   [--scale 1] [--fps 60] [--corner 20] [--cursor x,y] [--event open] [--shadow] [--seed 0.37]
            // Coordinates are stage pixels from the top left. Each frame covers only the effect's canvas;
            // meta.json says where that canvas sits on the stage.
            //   (--file some.metal renders a file that isn't in the effects folders)
            var meta: EffectMeta? = effects.first?.meta
            var pipeline: MTLRenderPipelineState? = effects.first?.pipeline
            if let path = value("--file") {
                guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { print("can't read \(path)"); return 2 }
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                let result = lib.compile(source: source, fileName: name + ".metal")
                if let err = result.error { print(err); return 1 }
                meta = EffectMeta.parse(source: source, fallbackName: name)
                pipeline = result.pipeline
            }
            func nums(_ flag: String, _ sep: Character) -> [Double]? {
                value(flag).map { $0.split(separator: sep).compactMap { Double($0) } }
            }
            let stageWH = nums("--stage", "x") ?? [1920, 1080]
            guard let dir = value("--render-sequence"), let meta, let ps = pipeline,
                  let r = nums("--rect", ","), r.count == 4, stageWH.count == 2 else {
                print("usage: --render-sequence dir (--only id | --file x.metal) --stage WxH --rect x,y,w,h [--window win.png]"); return 2
            }
            let stage = CGRect(x: 0, y: 0, width: stageWH[0], height: stageWH[1])
            let win = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
            let scale = Double(value("--scale") ?? "1") ?? 1
            // Without --window, the built-in demo window is drawn at the rect's size.
            let picture: CGImage? = value("--window")
                .map { NSImage(contentsOfFile: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
                ?? Images.demoWindow(size: CGSize(width: win.width / scale, height: win.height / scale), scale: scale)
            guard let src = picture, let tex = Renderer.shared.makeTexture(from: src) else { print("can't load the window picture"); return 1 }
            let fps = Double(value("--fps") ?? "60") ?? 60
            let canvas = (meta.padding.map { win.insetBy(dx: -$0 * scale, dy: -$0 * scale) } ?? stage)
                .intersection(stage).integral
            guard let off = OffscreenRenderer(width: Int(canvas.width), height: Int(canvas.height)) else { return 1 }

            var u = ExitUniforms()
            u.size = SIMD2(Float(canvas.width), Float(canvas.height))
            u.win = SIMD4(Float(win.minX - canvas.minX), Float(win.minY - canvas.minY), Float(win.width), Float(win.height))
            if let c = nums("--cursor", ","), c.count == 2 {
                u.cursor = SIMD2(Float(c[0] - canvas.minX), Float(c[1] - canvas.minY))
            } else {
                u.cursor = SIMD2(u.win.x + Float(26 * scale), u.win.y + Float(24 * scale))
            }
            u.accent = SIMD4(0.0, 0.478, 1.0, 1)
            u.duration = Float(meta.duration)
            u.scale = Float(scale)
            u.event = Int32((event ?? .close).rawValue)
            u.hasSnapshot = 1
            u.corner = Float(Double(value("--corner") ?? "") ?? (value("--window") == nil ? Images.demoCorner : 12) * scale)
            u.seed = Float(value("--seed") ?? "0.37") ?? 0.37
            u.shadow = args.contains("--shadow") ? 1 : 0

            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let count = Int((meta.duration * fps).rounded()) + 1
            for i in 0..<count {
                u.progress = Float(i) / Float(count - 1)
                u.time = u.progress * u.duration
                guard let img = off.render(ps, uniforms: u, texture: tex) else { return 1 }
                try? Images.writePNG(img, to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%04d.png", i)))
            }
            let info: [String: Any] = ["effect": meta.name, "frames": count, "fps": fps, "duration": meta.duration,
                                       "canvas": ["x": canvas.minX, "y": canvas.minY, "w": canvas.width, "h": canvas.height]]
            if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("meta.json"))
            }
            print("wrote \(count) frames to \(dir)  canvas \(Int(canvas.minX)),\(Int(canvas.minY)) \(Int(canvas.width))x\(Int(canvas.height))")
            return 0

        case "--snapshot-ui":
            // Renders each settings pane to PNG (Metal thumbnails stay blank): --snapshot-ui dir
            guard let dir = value("--snapshot-ui") else { return 2 }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            if let appearance = value("--appearance") {
                app.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            }
            for tab in SettingsTab.allCases {
                let nav = SettingsNavigation()
                nav.tab = tab
                let host = NSHostingView(rootView: SettingsView().environmentObject(nav))
                let w = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 860, height: 600),
                                 styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                w.contentView = host
                w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("\(tab.rawValue).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    print("wrote \(url.path)")
                }
                w.orderOut(nil)
            }
            return 0

        case "--market":
            let i = args.firstIndex(of: "--market")!
            let rest = Array(args[(i + 1)...].prefix { !$0.hasPrefix("--") })
            if rest.first == "submit" {
                guard rest.count > 1 else { print("usage: --market submit FILE|ID [--notes TEXT] [--wait] [--dry-run] [--force]"); return 2 }
                return MarketSubmit.run(target: rest[1], notes: value("--notes"), wait: args.contains("--wait"),
                                        dryRun: args.contains("--dry-run"), force: args.contains("--force"))
            }
            return MainActor.assumeIsolated { market(rest) }

        case "--validate":
            // Runs the same automatic checks the AI generator uses.
            var failed = 0
            for e in effects {
                let src = (try? String(contentsOf: e.url, encoding: .utf8)) ?? ""
                let problems = EffectGenerator.validate(src, budgetMs: Double(value("--budget") ?? "") ?? 7)
                if problems.isEmpty { print("✓ \(e.id)") } else {
                    failed += 1
                    print("✗ \(e.id)"); problems.forEach { print("   - \($0)") }
                }
            }
            return failed == 0 ? 0 : 1

        case "--generate":
            // Headless AI generation: --generate "description" [--event open]
            guard let desc = value("--generate") else { return 2 }
            let gen = MainActor.assumeIsolated { EffectGenerator() }
            var printed = 0
            MainActor.assumeIsolated {
                gen.generate(description: desc, events: event.map { [$0] } ?? [.close, .quit, .minimize])
            }
            while MainActor.assumeIsolated({ gen.isWorking }) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                MainActor.assumeIsolated {
                    for s in gen.steps.dropFirst(printed) { print(s.text) }
                    printed = gen.steps.count
                }
            }
            return MainActor.assumeIsolated {
                for s in gen.steps.dropFirst(printed) { print(s.text) }
                if let err = gen.errorText { print("error: \(err)") }
                if let id = gen.savedEffectID { print("saved: \(id)") }
                return gen.status == .done ? 0 : 1
            }

        case "--ai-ping":
            // Checks AI services: --ai-ping [cli.codex,api.openai,…]  (default: the selected one; "all" = every installed CLI)
            //   [--key-env VAR] [--base-url URL] [--model ID] [--models]   try an API without saving anything
            let arg = value("--ai-ping") ?? ""
            let ids: [String] = arg == "all"
                ? CLIAgent.allCases.filter { CLILocator.locate($0) != nil }.map { AIProvider.cli($0).id }
                : (arg.isEmpty || arg.hasPrefix("--") ? [Settings.shared.aiProviderID] : arg.split(separator: ",").map(String.init))
            var failed = 0
            for id in ids {
                guard let p = AIProvider(id: id) else { print("✗ \(id): unknown provider"); failed += 1; continue }
                let start = Date()
                let key = value("--key-env").flatMap { ProcessInfo.processInfo.environment[$0] }
                let base = value("--base-url"), model = value("--model")
                let box = PingBox()
                if args.contains("--models") {
                    Task.detached {
                        box.result = await Result {
                            let ids = try await AIService.listModels(for: p, apiKey: key ?? "",
                                                                     baseURL: base ?? Settings.shared.aiBaseURL(for: p))
                            return "\(ids.count) models: " + ids.prefix(8).joined(separator: ", ")
                        }
                    }
                } else {
                    Task.detached { box.result = await Result { try await AIService.ping(p, apiKey: key, baseURL: base, model: model) } }
                }
                while box.result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
                let secs = String(format: "%.1fs", Date().timeIntervalSince(start))
                switch box.result! {
                case .success(let reply): print("✓ \(id)  \(secs)  \(reply.prefix(60))")
                case .failure(let error): failed += 1; print("✗ \(id)  \(secs)  \(error.localizedDescription)")
                }
            }
            return failed == 0 ? 0 : 1

        case "--bench":
            let maxMs = value("--max-ms").flatMap(Double.init)
            var slow = 0
            let screen = CGSize(width: 2560, height: 1600)
            let win = CGSize(width: 1440, height: 920)
            guard let snap = Images.demoWindow(size: CGSize(width: 720, height: 460), scale: 2),
                  let tex = Renderer.shared.makeTexture(from: snap) else { return 1 }
            for e in effects {
                guard let ps = e.pipeline else { print("✗ \(e.id) (compile error)"); continue }
                let pad = (e.meta.padding ?? 4000) * 2
                let cw = Int(min(screen.width, win.width + pad * 2)), ch = Int(min(screen.height, win.height + pad * 2))
                guard let off = OffscreenRenderer(width: cw, height: ch) else { continue }
                var u = ExitUniforms()
                u.size = SIMD2(Float(cw), Float(ch))
                u.win = SIMD4(Float((CGFloat(cw) - win.width) / 2), Float((CGFloat(ch) - win.height) / 2), Float(win.width), Float(win.height))
                u.cursor = SIMD2(u.win.x + 30, u.win.y + 30)
                u.duration = Float(e.meta.duration)
                u.scale = 2
                u.corner = Float(Images.demoCorner * 2)
                u.seed = 0.37
                let ms = off.benchmark(ps, uniforms: u, texture: tex)
                let over = maxMs.map { ms > $0 } ?? false
                if over { slow += 1 }
                print(String(format: "%@ %-22@ %6.2f ms/frame  (%dx%d)", over ? "✗" : ms > 8 ? "⚠︎" : "✓", e.id as NSString, ms, cw, ch))
            }
            return slow == 0 ? 0 : 1

        default:
            return nil
        }
    }

    @MainActor
    private static func market(_ args: [String]) -> Int32 {
        let store = MarketStore.shared
        func wait(_ work: @escaping @MainActor () async -> Void) {
            var done = false
            Task { @MainActor in await work(); done = true }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        let verb = args.first ?? "list"
        // Only "update" does what the app does in the background (updates, subscriptions).
        wait { await store.refresh(automatic: verb == "update") }
        for (source, error) in store.errors { print("✗ \(source): \(error)") }
        switch verb {
        case "update":
            let names = store.autoInstalled
            print(names.isEmpty ? "up to date" : "installed: " + names.joined(separator: ", "))
            fallthrough
        case "list":
            for item in store.items {
                let status: String = switch store.status(of: item) {
                case .notInstalled: "-"
                case .installed: "installed"
                case .updateAvailable: "update available"
                case .incompatible(let v): "needs \(v)"
                case .otherSource: "installed from another source"
                }
                print(item.entry.id.padding(toLength: 20, withPad: " ", startingAt: 0) + " "
                      + item.entry.name.padding(toLength: 24, withPad: " ", startingAt: 0) + " " + status)
            }
            return store.errors.isEmpty ? 0 : 1
        case "install", "uninstall":
            guard args.count > 1 else { print("usage: --market \(verb) ID"); return 2 }
            if verb == "uninstall" {
                guard store.uninstall(id: args[1]) else { print("not a market effect id: \(args[1])"); return 2 }
                print("uninstalled \(args[1])")
                return 0
            }
            guard let item = store.items.first(where: { $0.entry.id == args[1] }) else { print("not in the market: \(args[1])"); return 1 }
            var failure: Error?
            wait { do { try await store.install(item) } catch { failure = error } }
            if let failure { print("✗ \(failure.localizedDescription)"); return 1 }
            print("installed \(item.entry.id) → \(Paths.marketEffects.path)")
            return 0
        default:
            print("usage: --market [list | update | install ID | uninstall ID | submit FILE|ID]")
            return 2
        }
    }

    /// Renders `count` frames spread over the effect, each composited into a fixed "screen" frame.
    static func renderFrames(_ e: Effect, pipeline: MTLRenderPipelineState, count: Int, event: WindowEvent,
                             placeholder: Bool, scale: CGFloat) -> [CGImage] {
        let screen = CGSize(width: 1180, height: 760)
        let winPt = CGSize(width: 640, height: 410)
        let snapshot: CGImage? = placeholder
            ? Images.placeholder(size: winPt, scale: scale, icon: NSImage(named: NSImage.folderName), title: "Untitled — Notes", corner: Images.demoCorner)
            : Images.demoWindow(size: winPt, scale: scale)
        guard let snap = snapshot, let tex = Renderer.shared.makeTexture(from: snap) else { return [] }

        let winOrigin = CGPoint(x: (screen.width - winPt.width) / 2, y: (screen.height - winPt.height) / 2)
        let screenRect = CGRect(origin: .zero, size: screen)
        let canvasPt: CGRect = {
            guard let pad = e.meta.padding else { return screenRect }
            return CGRect(origin: winOrigin, size: winPt).insetBy(dx: -pad, dy: -pad).intersection(screenRect)
        }()
        let cw = Int(canvasPt.width * scale), ch = Int(canvasPt.height * scale)
        guard let off = OffscreenRenderer(width: cw, height: ch) else { return [] }

        var u = ExitUniforms()
        u.size = SIMD2(Float(cw), Float(ch))
        u.win = SIMD4(Float((winOrigin.x - canvasPt.minX) * scale), Float((winOrigin.y - canvasPt.minY) * scale),
                      Float(winPt.width * scale), Float(winPt.height * scale))
        u.cursor = SIMD2(u.win.x + Float(26 * scale), u.win.y + Float(24 * scale))
        u.duration = Float(e.meta.duration)
        u.scale = Float(scale)
        u.event = Int32(event.rawValue)
        u.hasSnapshot = placeholder ? 0 : 1
        u.corner = Float(Images.demoCorner * scale)
        u.seed = 0.37
        u.shadow = CommandLine.arguments.contains("--shadow") ? 1 : 0

        var out: [CGImage] = []
        for i in 0..<count {
            let p = count == 1 ? 0.5 : Float(i) / Float(count - 1) * 0.96 + 0.02
            u.progress = p
            u.time = p * u.duration
            guard let frame = off.render(pipeline, uniforms: u, texture: tex) else { continue }
            // Place the canvas into the full screen frame.
            let sw = Int(screen.width * scale), sh = Int(screen.height * scale)
            guard let ctx = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { continue }
            if event == .open {
                // Open effects decorate a window that is still visible underneath.
                ctx.draw(snap, in: CGRect(x: winOrigin.x * scale, y: (screen.height - winOrigin.y - winPt.height) * scale,
                                          width: winPt.width * scale, height: winPt.height * scale))
            }
            let y = (screen.height - canvasPt.maxY) * scale  // CG origin is bottom-left
            ctx.draw(frame, in: CGRect(x: canvasPt.minX * scale, y: y, width: CGFloat(cw), height: CGFloat(ch)))
            if let img = ctx.makeImage() { out.append(img) }
        }
        return out
    }

    static func renderSheet(_ effects: [Effect], frames: Int, event: WindowEvent, placeholder: Bool) -> CGImage? {
        var rows: [(String, [CGImage])] = []
        for e in effects {
            guard let ps = e.pipeline else {
                rows.append(("✗ \(e.id)", []))
                continue
            }
            rows.append((e.meta.name, renderFrames(e, pipeline: ps, count: frames, event: event, placeholder: placeholder, scale: 1)))
        }
        return Images.contactSheet(rows: rows, cell: CGSize(width: 295, height: 190))
    }
}

private final class PingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<String, Error>?
    var result: Result<String, Error>? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
