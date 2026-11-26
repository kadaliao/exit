import AppKit
import MetalKit
import SwiftUI

struct EffectsPane: View {
    @ObservedObject var library = EffectLibrary.shared
    @ObservedObject var settings = Settings.shared
    @EnvironmentObject var nav: SettingsNavigation

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 300), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text(T("\(library.effects.count) effects · each one is a single Metal file you can edit.",
                           "共 \(library.effects.count) 个特效 · 每个都是一个可以直接修改的 Metal 文件。"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { nav.tab = .ai } label: { Label(T("Create with AI", "AI 生成"), systemImage: "wand.and.stars") }
                    Button { NSWorkspace.shared.open(Paths.userEffects) } label: { Label(T("Folder", "文件夹"), systemImage: "folder") }
                    Button {
                        let guide = T("EFFECTS.md", "EFFECTS.zh-CN.md")
                        if let url = URL(string: "https://github.com/kadaliao/exit/blob/main/docs/\(guide)") { NSWorkspace.shared.open(url) }
                    } label: {
                        Label(T("Guide", "编写指南"), systemImage: "book")
                    }
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(library.effects) { effect in
                        EffectCard(effect: effect)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct EffectCard: View {
    @ObservedObject var effect: Effect
    @ObservedObject var settings = Settings.shared
    @State private var hovering = false

    private var inShuffle: Binding<Bool> {
        Binding(get: { !settings.shuffleExcluded.contains(effect.id) },
                set: { on in
                    if on { settings.shuffleExcluded.remove(effect.id) } else { settings.shuffleExcluded.insert(effect.id) }
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let error = effect.error {
                    ScrollView {
                        Text(error).font(.system(size: 10, design: .monospaced)).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .background(Color.red.opacity(0.06))
                } else {
                    EffectThumbnail(effect: effect)
                }
            }
            .frame(height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .onTapGesture { ExitEngine.shared.preview(effect) }
            .help(T("Click to play it on screen", "点击在屏幕上播放"))

            HStack(spacing: 6) {
                Text(effect.meta.displayName).font(.headline).lineLimit(1)
                if !effect.isBuiltIn {
                    Text(T("Custom", "自定义")).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
                Spacer()
                ForEach(effect.meta.events.sorted { $0.rawValue < $1.rawValue }) { e in
                    Image(systemName: e.symbol).font(.caption).foregroundStyle(.secondary).help(e.title)
                }
            }
            Text(effect.meta.displayDescription ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)

            HStack {
                Toggle(T("Shuffle", "随机"), isOn: inShuffle).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button { ExitEngine.shared.preview(effect) } label: { Image(systemName: "play.fill") }
                    .help(T("Play on screen", "在屏幕上播放")).disabled(!effect.isReady)
                Button { edit() } label: { Image(systemName: "pencil") }
                    .help(effect.isBuiltIn ? T("Copy to your folder and edit", "复制到你的文件夹并编辑") : T("Edit", "编辑"))
                Button { NSWorkspace.shared.activateFileViewerSelecting([effect.url]) } label: { Image(systemName: "folder") }
                    .help(T("Show in Finder", "在访达中显示"))
                if !effect.isBuiltIn {
                    Button { trash() } label: { Image(systemName: "trash") }.help(T("Move to Trash", "移到废纸篓"))
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
    }

    private func edit() {
        var url = effect.url
        if effect.isBuiltIn, let copy = EffectLibrary.shared.duplicateToUserFolder(effect) { url = copy }
        NSWorkspace.shared.open(url)
    }

    private func trash() {
        try? FileManager.default.trashItem(at: effect.url, resultingItemURL: nil)
        EffectLibrary.shared.rescan()
    }
}

/// A looping live preview of an effect on the demo window.
struct EffectThumbnail: NSViewRepresentable {
    @ObservedObject var effect: Effect
    /// Change it to start the loop over (e.g. on hover).
    var replay = 0

    private var restartKey: String { "\(effect.id)#\(effect.revision)#\(replay)" }

    func makeNSView(context: Context) -> ThumbnailView {
        let v = ThumbnailView()
        v.effect = effect
        v.restartKey = restartKey
        return v
    }

    func updateNSView(_ v: ThumbnailView, context: Context) {
        // Restart only when the effect or its code changed, not on every SwiftUI update.
        guard v.effect !== effect || v.restartKey != restartKey else { return }
        v.effect = effect
        v.restartKey = restartKey
        v.restart()
    }
}

final class ThumbnailView: NSView, MTKViewDelegate {
    var effect: Effect?
    var restartKey = ""
    private let mtk = MTKView(frame: .zero, device: Renderer.shared.device)
    private let windowLayer = CALayer()
    private let backdrop = CAGradientLayer()
    private var texture: MTLTexture?
    private var start = CACurrentMediaTime()
    /// Demo window picture and texture, light and dark, shared by every thumbnail.
    private static var demo: [Bool: (image: CGImage, texture: MTLTexture)] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        backdrop.colors = [CGColor(red: 0.24, green: 0.36, blue: 0.55, alpha: 1), CGColor(red: 0.47, green: 0.32, blue: 0.52, alpha: 1)]
        backdrop.startPoint = CGPoint(x: 0, y: 0)
        backdrop.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(backdrop)
        layer?.addSublayer(windowLayer)
        windowLayer.contentsGravity = .resize

        mtk.colorPixelFormat = .bgra8Unorm
        mtk.framebufferOnly = true
        mtk.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtk.layer?.isOpaque = false
        (mtk.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        mtk.preferredFramesPerSecond = 60
        mtk.delegate = self
        addSubview(mtk)

        useDemoWindow()
    }

    private func useDemoWindow() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if Self.demo[dark] == nil, let img = Images.demoWindow(size: CGSize(width: 720, height: 460), scale: 1, dark: dark),
           let tex = Renderer.shared.makeTexture(from: img) {
            Self.demo[dark] = (img, tex)
        }
        texture = Self.demo[dark]?.texture
        windowLayer.contents = Self.demo[dark]?.image
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        useDemoWindow()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Purely visual: let clicks reach the SwiftUI button or tap gesture around it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func restart() { start = CACurrentMediaTime() }

    private var windowRect: CGRect {
        // Demo window at 62% of the width, centered (view coordinates, bottom-left origin).
        let w = bounds.width * 0.62, h = w * 460 / 720
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        mtk.frame = bounds
        windowLayer.frame = windowRect
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        mtk.isPaused = window == nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let effect, let pipeline = effect.pipeline, let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let cb = Renderer.shared.queue.makeCommandBuffer() else { return }
        let isOpen = effect.meta.events == [.open]
        let duration = effect.meta.duration
        let cycle = duration + 0.9
        let t = (CACurrentMediaTime() - start).truncatingRemainder(dividingBy: cycle)
        let progress = min(t / duration, 1)

        // Closing effects replace the window; opening ones decorate it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        windowLayer.isHidden = !isOpen && t < duration
        CATransaction.commit()

        let px = view.drawableSize.width / max(bounds.width, 1)
        let r = windowRect
        var u = ExitUniforms()
        u.size = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        u.win = SIMD4(Float(r.minX * px), Float((bounds.height - r.maxY) * px), Float(r.width * px), Float(r.height * px))
        u.cursor = SIMD2(u.win.x + u.win.z * 0.04, u.win.y + u.win.w * 0.05)
        u.progress = Float(t < duration ? progress : (isOpen ? 1 : 0))
        u.time = Float(min(t, duration))
        u.duration = Float(duration)
        u.seed = 0.37
        u.scale = Float(r.width * px / 720)   // keep proportions of a real 720 pt window
        u.event = Int32(isOpen ? WindowEvent.open.rawValue : WindowEvent.close.rawValue)
        u.corner = Float(Images.demoCorner) * u.scale
        if let a = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
            u.accent = SIMD4(Float(a.redComponent), Float(a.greenComponent), Float(a.blueComponent), 1)
        }
        if t >= duration && !isOpen {
            // Pause on the intact window between loops.
            u.progress = 0
        }
        Renderer.shared.encode(pipeline, uniforms: u, texture: texture, pass: pass, commandBuffer: cb)
        cb.present(drawable)
        cb.commit()
    }
}
