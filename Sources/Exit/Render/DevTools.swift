import AppKit
import Metal
import SwiftUI

/// Command-line helpers for effect authors and CI:
///   Exit --check                          compile every effect, print errors
///   Exit --render-sheet out.png [--only a,b] [--frames 6] [--event open] [--placeholder]
///   Exit --bench                          GPU time per frame at Retina size
enum DevTools {
    static func run(_ args: [String]) -> Int32? {
        guard let cmd = args.first(where: { $0.hasPrefix("--") }),
              ["--check", "--render-sheet", "--bench", "--render-frames", "--validate", "--generate", "--snapshot-ui"].contains(cmd) else { return nil }
        let lib = EffectLibrary.shared
        lib.loadAll(synchronously: true)

        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
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

        case "--validate":
            // Runs the same automatic checks the AI generator uses.
            var failed = 0
            for e in effects {
                let src = (try? String(contentsOf: e.url, encoding: .utf8)) ?? ""
                let problems = EffectGenerator.validate(src)
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

        case "--bench":
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
                print(String(format: "%@ %-22@ %6.2f ms/frame  (%dx%d)", ms > 8 ? "⚠︎" : "✓", e.id as NSString, ms, cw, ch))
            }
            return 0

        default:
            return nil
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
