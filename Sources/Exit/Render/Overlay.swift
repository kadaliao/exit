import AppKit
import Metal
import MetalKit
import QuartzCore

struct OverlayJob {
    let effect: Effect
    let event: WindowEvent
    /// Window frame, top-left global points.
    let frame: CGRect
    let texture: MTLTexture?
    let hasSnapshot: Bool
    /// Cursor position, top-left global points.
    let cursor: CGPoint
    let cornerRadius: CGFloat
    var speed: Double = 1
    /// Fade out a stand-in for the window's drop shadow (real windows only).
    var shadow = false
}

/// A click-through, non-activating panel that plays one effect and then hides itself.
final class OverlayPanel: NSPanel, MTKViewDelegate {
    private let mtkView: MTKView
    private var job: OverlayJob?
    private var pipeline: MTLRenderPipelineState?
    private var uniforms = ExitUniforms()
    private var start: CFTimeInterval = 0
    private var duration: Double = 1
    private var frames = 0
    private static let debug = ProcessInfo.processInfo.environment["EXIT_DEBUG"] != nil
    var onFinish: ((OverlayPanel) -> Void)?

    init() {
        mtkView = MTKView(frame: .zero, device: Renderer.shared.device)
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.layer?.isOpaque = false
        (mtkView.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        mtkView.autoResizeDrawable = false
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.delegate = self
        contentView = mtkView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var isBusy: Bool { job != nil }

    func play(_ job: OverlayJob) {
        guard let pipeline = job.effect.pipeline else { return }
        let winAK = ScreenGeometry.toAppKit(job.frame)
        guard let screen = ScreenGeometry.screen(for: winAK) else { return }
        let scale = screen.backingScaleFactor

        var canvas: CGRect
        if let pad = job.effect.meta.padding {
            canvas = winAK.insetBy(dx: -pad, dy: -pad).intersection(screen.frame)
        } else {
            canvas = screen.frame
        }
        canvas = canvas.integral
        guard canvas.width >= 1, canvas.height >= 1 else { return }

        self.job = job
        self.pipeline = pipeline
        duration = max(0.1, job.effect.meta.duration / max(job.speed, 0.1))

        setFrame(canvas, display: false)
        mtkView.frame = CGRect(origin: .zero, size: canvas.size)
        mtkView.drawableSize = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        mtkView.preferredFramesPerSecond = screen.maximumFramesPerSecond

        var u = ExitUniforms()
        u.size = SIMD2(Float(canvas.width * scale), Float(canvas.height * scale))
        u.win = SIMD4(Float((winAK.minX - canvas.minX) * scale), Float((canvas.maxY - winAK.maxY) * scale),
                      Float(winAK.width * scale), Float(winAK.height * scale))
        let cur = ScreenGeometry.toAppKit(job.cursor)
        u.cursor = SIMD2(Float((cur.x - canvas.minX) * scale), Float((canvas.maxY - cur.y) * scale))
        u.duration = Float(duration)
        u.seed = Float.random(in: 0..<1)
        u.scale = Float(scale)
        u.event = Int32(job.event.rawValue)
        u.hasSnapshot = job.hasSnapshot ? 1 : 0
        u.corner = Float(job.cornerRadius * scale)
        u.shadow = job.shadow && job.event != .open ? 1 : 0
        if let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
            u.accent = SIMD4(Float(accent.redComponent), Float(accent.greenComponent), Float(accent.blueComponent), 1)
        }
        uniforms = u

        start = CACurrentMediaTime()
        frames = 0
        alphaValue = 1
        orderFrontRegardless()
        mtkView.draw()           // first frame right away: the window must not blink
        mtkView.isPaused = false
    }

    func stop() {
        if Self.debug, let job {
            let elapsed = CACurrentMediaTime() - start
            print(String(format: "[overlay] %@ %d frames in %.2fs (%.0f fps) canvas %.0fx%.0f",
                         job.effect.id, frames, elapsed, Double(frames) / max(elapsed, 0.001), frame.width, frame.height))
        }
        mtkView.isPaused = true
        orderOut(nil)
        job = nil
        pipeline = nil
        onFinish?(self)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard job != nil, let pipeline else { return }
        let elapsed = CACurrentMediaTime() - start
        let progress = elapsed / duration
        if progress >= 1.0 {
            stop()
            return
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = Renderer.shared.queue.makeCommandBuffer() else { return }
        uniforms.progress = Float(progress)
        uniforms.time = Float(elapsed)
        Renderer.shared.encode(pipeline, uniforms: uniforms, texture: job?.texture, pass: pass, commandBuffer: cb)
        cb.present(drawable)
        cb.commit()
        frames += 1
    }
}

/// Keeps a small pool of overlay panels so effects start instantly.
final class OverlayController {
    private var idle: [OverlayPanel] = []
    private var active: [OverlayPanel] = []

    func prewarm(count: Int = 2) {
        while idle.count < count {
            let p = makePanel()
            // Show once off-screen so the first real play doesn't pay the window-server setup cost.
            p.setFrame(CGRect(x: -20000, y: -20000, width: 4, height: 4), display: false)
            p.alphaValue = 0
            p.orderFrontRegardless()
            p.orderOut(nil)
            idle.append(p)
        }
    }

    func play(_ job: OverlayJob) {
        let panel = idle.popLast() ?? makePanel()
        active.append(panel)
        panel.play(job)
    }

    var activeCount: Int { active.count }

    func stopAll() { for p in active { p.stop() } }

    private func makePanel() -> OverlayPanel {
        let p = OverlayPanel()
        p.onFinish = { [weak self] panel in
            guard let self else { return }
            self.active.removeAll { $0 === panel }
            if self.idle.count < 4 { self.idle.append(panel) }
        }
        return p
    }
}
