import AppKit
import Metal
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
                    Button { nav.tab = .market } label: { Label(T("Market", "特效市场"), systemImage: "storefront") }
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
                        VStack(alignment: .leading, spacing: 6) {
                            Text(error).font(.system(size: 10, design: .monospaced)).foregroundStyle(.red)
                            if effect.stoppedByGuard {
                                Button(T("Turn Back On", "重新启用")) { EffectLibrary.shared.reenable(effect) }
                                    .controlSize(.small)
                            }
                        }
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
                if effect.origin != .builtIn {
                    Text(effect.origin == .market ? T("Market", "市场") : T("Custom", "自定义"))
                        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill((effect.origin == .market ? Color.green : Color.accentColor).opacity(0.18)))
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
                    .help(effect.origin == .user ? T("Edit", "编辑") : T("Copy to your folder and edit", "复制到你的文件夹并编辑"))
                Button { NSWorkspace.shared.activateFileViewerSelecting([effect.url]) } label: { Image(systemName: "folder") }
                    .help(T("Show in Finder", "在访达中显示"))
                if effect.origin == .user {
                    Button { trash() } label: { Image(systemName: "trash") }.help(T("Move to Trash", "移到废纸篓"))
                } else if effect.origin == .market {
                    Button { MarketStore.shared.uninstall(id: effect.id) } label: { Image(systemName: "trash") }
                        .help(T("Uninstall", "卸载"))
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
    }

    private func edit() {
        var url = effect.url
        if effect.origin != .user, let copy = EffectLibrary.shared.duplicateToUserFolder(effect) { url = copy }
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

/// Draws one looping thumbnail. Each frame is computed on the main thread (cheap) and rendered
/// on a background queue: a Metal layer that isn't being composited hands out no new drawables,
/// and waiting for one on the main thread froze clicks in Settings for up to a second per frame.
final class ThumbnailView: NSView {
    var effect: Effect?
    var restartKey = ""
    private let metalLayer = CAMetalLayer()
    private let windowLayer = CALayer()
    private let backdrop = CAGradientLayer()
    private var texture: MTLTexture?
    private var start = CACurrentMediaTime()
    private var displayLink: CADisplayLink?
    private var occlusionToken: NSObjectProtocol?
    private let renderQueue = DispatchQueue(label: "exit.thumbnail", qos: .userInitiated)
    /// Main thread: the previous frame is still being rendered.
    private var rendering = false
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

        metalLayer.device = Renderer.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer?.addSublayer(metalLayer)

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

    deinit {
        if let occlusionToken { NotificationCenter.default.removeObserver(occlusionToken) }
    }

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
        metalLayer.frame = bounds
        windowLayer.frame = windowRect
        CATransaction.commit()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The display link holds on to this view, so it only exists while the view is in a window.
        displayLink?.invalidate()
        displayLink = nil
        if let occlusionToken { NotificationCenter.default.removeObserver(occlusionToken) }
        occlusionToken = nil
        guard let window else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        occlusionToken = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                object: window, queue: .main) { [weak self] _ in self?.updatePaused() }
        updatePaused()
        updateDrawableSize()
    }

    /// Settings stays alive after it's closed, thumbnails and all: draw only while it's on screen.
    private func updatePaused() {
        displayLink?.isPaused = !(window?.occlusionState.contains(.visible) ?? false)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard !rendering, !visibleRect.isEmpty, !isHiddenOrHasHiddenAncestor,
              let effect, let pipeline = effect.pipeline else { return }
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

        let size = metalLayer.drawableSize
        let px = size.width / max(bounds.width, 1)
        let r = windowRect
        var u = ExitUniforms()
        u.size = SIMD2(Float(size.width), Float(size.height))
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

        rendering = true
        let layer = metalLayer, texture = texture, uniforms = u
        renderQueue.async { [weak self] in
            if let drawable = layer.nextDrawable(), let cb = Renderer.shared.queue.makeCommandBuffer() {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = drawable.texture
                Renderer.shared.encode(pipeline, uniforms: uniforms, texture: texture, pass: pass, commandBuffer: cb)
                EffectGuard.watch(cb, effect: effect)
                cb.present(drawable)
                cb.commit()
            }
            DispatchQueue.main.async { self?.rendering = false }
        }
    }
}
