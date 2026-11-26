import AppKit
import Combine
import Metal

/// Wires window tracking, snapshots and overlays together and applies the user's rules.
final class ExitEngine: NSObject, WindowTrackerDelegate, EventInterceptorDelegate {
    static let shared = ExitEngine()

    let tracker = WindowTracker()
    let interceptor = EventInterceptor()
    let snapshots = SnapshotService()
    let overlay = OverlayController()
    private let settings = Settings.shared
    private let library = EffectLibrary.shared

    private(set) var running = false
    private var cancellables: Set<AnyCancellable> = []
    private var recentlyPlayed: [CGWindowID: Date] = [:]
    private var lastEffectID: String?
    private var focusCapture: DispatchWorkItem?
    private var refreshTimer: Timer?

    // State read from the event-tap thread.
    private let stateLock = NSLock()
    private var holdAllowed: Set<WindowEvent> = []
    private var excludedBundles: Set<String> = []
    private var buttonPending = false
    private var buttonWaiters: [() -> Void] = []
    private var quitIntent: (pid: pid_t, time: Date)?

    var cornerRadius: CGFloat {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 16 : 10
    }

    // MARK: Lifecycle

    /// Starts tracking. Requires Accessibility permission.
    func start() {
        guard !running, AX.isTrusted() else { return }
        running = true
        overlay.prewarm()
        tracker.delegate = self
        tracker.start()
        interceptor.delegate = self
        applySettings()

        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.applySettings() } }
            .store(in: &cancellables)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.periodicRefresh() }
        Task { await snapshots.refreshContent(force: true) }
        log.info("engine started")
    }

    private func applySettings() {
        snapshots.refreshPermission()
        var allowed: Set<WindowEvent> = []
        if settings.enabled && settings.preciseCapture && snapshots.permitted {
            for e in [WindowEvent.close, .quit, .minimize] where settings.assignment(for: e) != .off { allowed.insert(e) }
        }
        stateLock.withLock {
            holdAllowed = allowed
            excludedBundles = Set(settings.excludedApps)
        }
        if running {
            if allowed.isEmpty { interceptor.stop() } else { interceptor.start() }
        }
    }

    private func periodicRefresh() {
        let before = snapshots.permitted
        snapshots.refreshPermission()
        if before != snapshots.permitted { applySettings() }
        guard settings.enabled, settings.refreshFocused, snapshots.permitted,
              let focused = tracker.focusedWindow, tracker.isOnScreen(focused.windowID) else { return }
        if let s = snapshots.latest(for: focused.windowID), s.age < 3.5 { return }
        Task { _ = await snapshots.capture(focused.windowID, intent: false) }
    }

    // MARK: Choosing effects

    func chooseEffect(for event: WindowEvent) -> Effect? {
        switch settings.assignment(for: event) {
        case .off:
            return nil
        case .effect(let id):
            if let e = library.effect(id: id), e.isReady { return e }
            return randomEffect(for: event)
        case .random:
            return randomEffect(for: event)
        }
    }

    private func randomEffect(for event: WindowEvent) -> Effect? {
        var pool = library.readyEffects(for: event).filter { !settings.shuffleExcluded.contains($0.id) }
        if pool.isEmpty { pool = library.readyEffects(for: event) }
        if pool.count > 1 { pool.removeAll { $0.id == lastEffectID } }
        return pool.randomElement()
    }

    private func shouldPlay(_ window: WindowInfo) -> Bool {
        guard settings.enabled else { return false }
        if settings.respectReduceMotion && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return false }
        if let b = window.bundleID, settings.excludedApps.contains(b) { return false }
        let minSide = CGFloat(settings.minWindowSize)
        return window.frame.width >= minSide && window.frame.height >= minSide * 0.6
    }

    // MARK: Playing

    private func bestSnapshot(for window: WindowInfo) -> Snapshot? {
        guard let s = snapshots.latest(for: window.windowID) else { return nil }
        // A picture of a very different size would look wrong; prefer the stand-in.
        let dw = abs(s.frame.width - window.frame.width) / max(window.frame.width, 1)
        let dh = abs(s.frame.height - window.frame.height) / max(window.frame.height, 1)
        return (dw < 0.15 && dh < 0.15) ? s : nil
    }

    private func placeholderTexture(for window: WindowInfo, scale: CGFloat) -> MTLTexture? {
        let icon = NSRunningApplication(processIdentifier: window.pid)?.icon
        let img = Images.placeholder(size: window.frame.size, scale: min(scale, 2), icon: icon,
                                     title: window.title.isEmpty ? window.appName : window.title, corner: cornerRadius)
        return img.flatMap { Renderer.shared.makeTexture(from: $0) }
    }

    private var cursorPosition: CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: ScreenGeometry.primaryHeight - p.y)
    }

    func play(_ event: WindowEvent, window: WindowInfo, snapshot: Snapshot? = nil) {
        guard shouldPlay(window), let effect = chooseEffect(for: event) else { return }
        let now = Date()
        recentlyPlayed = recentlyPlayed.filter { now.timeIntervalSince($0.value) < 5 }
        if let last = recentlyPlayed[window.windowID], now.timeIntervalSince(last) < 1.5, event != .open { return }
        recentlyPlayed[window.windowID] = now

        let snap = snapshot ?? bestSnapshot(for: window)
        let scale = ScreenGeometry.screen(for: ScreenGeometry.toAppKit(window.frame))?.backingScaleFactor ?? 2
        let texture = snap?.texture ?? placeholderTexture(for: window, scale: scale)
        lastEffectID = effect.id
        overlay.play(OverlayJob(effect: effect, event: event, frame: window.frame, texture: texture,
                                hasSnapshot: snap != nil, cursor: cursorPosition, cornerRadius: cornerRadius,
                                speed: settings.speed, shadow: true))
        settings.playCount += 1
        if event != .open { snapshots.forget(window.windowID) }
    }

    /// Plays an effect on the demo window in the middle of the screen.
    func preview(_ effect: Effect, event: WindowEvent? = nil) {
        guard NSApp != nil, effect.isReady, let screen = NSScreen.main else { return }
        let size = CGSize(width: 720, height: 460)
        let vf = screen.visibleFrame
        let ak = CGRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height)
        let frame = CGRect(x: ak.minX, y: ScreenGeometry.primaryHeight - ak.maxY, width: size.width, height: size.height)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard let img = Images.demoWindow(size: size, scale: screen.backingScaleFactor, dark: dark),
              let tex = Renderer.shared.makeTexture(from: img) else { return }
        let ev = event ?? (effect.meta.events.contains(.close) ? .close : effect.meta.events.first ?? .close)
        overlay.play(OverlayJob(effect: effect, event: ev, frame: frame, texture: tex, hasSnapshot: true,
                                cursor: CGPoint(x: frame.minX + 26, y: frame.minY + 24), cornerRadius: Images.demoCorner,
                                speed: settings.speed))
    }

    // MARK: WindowTrackerDelegate

    func windowTracker(_ tracker: WindowTracker, observed event: WindowEvent, window: WindowInfo) {
        var event = event
        if event == .close, let q = stateLock.withLock({ quitIntent }), q.pid == window.pid, Date().timeIntervalSince(q.time) < 3 {
            event = .quit
        }
        switch event {
        case .open:
            guard settings.assignment(for: .open) != .off, shouldPlay(window) else { return }
            Task { @MainActor in
                let snap = await snapshots.capture(window.windowID, intent: false)
                play(.open, window: window, snapshot: snap)
            }
        default:
            if snapshots.isCapturing(window.windowID) {
                // The "last frame" photo is still developing; give it a moment.
                Task { @MainActor in
                    await snapshots.waitForCapture(window.windowID, timeout: 0.12)
                    play(event, window: window)
                }
            } else {
                play(event, window: window)
            }
        }
    }

    func windowTracker(_ tracker: WindowTracker, focusChangedTo window: WindowInfo?) {
        focusCapture?.cancel()
        guard let window, settings.enabled, snapshots.permitted else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.tracker.focusedWindow?.windowID == window.windowID else { return }
            Task { _ = await self.snapshots.capture(window.windowID, intent: false) }
        }
        focusCapture = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func windowTracker(_ tracker: WindowTracker, appTerminated pid: pid_t, windows: [WindowInfo]) {
        let largest = windows.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }.prefix(4)
        for w in largest where recentlyPlayed[w.windowID] == nil {
            play(.quit, window: w)
        }
    }

    // MARK: EventInterceptorDelegate (event-tap thread)

    func interceptorShouldHold(_ intent: Intent) -> Bool {
        guard let focused = tracker.focusedWindow else { return false }
        return stateLock.withLock {
            holdAllowed.contains(intent.event) && !excludedBundles.contains(focused.bundleID ?? "")
        }
    }

    func interceptorPrepare(_ intent: Intent, done: @escaping () -> Void) {
        guard let focused = tracker.focusedWindow else { done(); return }
        switch intent {
        case .closeWindow, .minimize:
            Task.detached(priority: .userInitiated) { [snapshots] in
                _ = await snapshots.capture(focused.windowID, intent: true)
                done()
            }
        case .quitApp:
            stateLock.withLock { quitIntent = (focused.pid, Date()) }
            let visible = tracker.onScreenWindows()
            let ids = tracker.windows(of: focused.pid)
                .filter { visible[$0.windowID] != nil }
                .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
                .prefix(4).map(\.windowID)
            Task.detached(priority: .userInitiated) { [snapshots] in
                await withTaskGroup(of: Void.self) { group in
                    for id in ids { group.addTask { _ = await snapshots.capture(id, intent: true) } }
                }
                done()
            }
        }
    }

    func interceptorMouseDown(at point: CGPoint) {
        let allowed = stateLock.withLock { holdAllowed.contains(.close) || holdAllowed.contains(.minimize) }
        guard allowed else { return }
        // Only clicks near the top edge of a visible window can hit its traffic lights.
        let hitsTitleBar = tracker.onScreenWindows().values.contains { r in
            r.contains(point) && point.y - r.minY < 56 && point.x - r.minX < 140
        }
        guard hitsTitleBar else { return }
        stateLock.withLock { buttonPending = true }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            var target: (CGWindowID, Intent)?
            if let el = AX.element(at: point), let subrole = AX.string(el, kAXSubroleAttribute) {
                let intent: Intent? = subrole == kAXCloseButtonSubrole as String ? .closeWindow
                    : subrole == kAXMinimizeButtonSubrole as String ? .minimize : nil
                if let intent, let win = AX.element(el, kAXWindowAttribute), let id = AX.windowID(win) {
                    let excluded = self.stateLock.withLock {
                        !self.holdAllowed.contains(intent.event)
                            || self.excludedBundles.contains(self.tracker.info(for: id)?.bundleID ?? "")
                    }
                    if !excluded { target = (id, intent) }
                }
            }
            guard let (id, _) = target else { self.finishButtonCapture(); return }
            Task.detached(priority: .userInitiated) {
                _ = await self.snapshots.capture(id, intent: true)
                self.finishButtonCapture()
            }
        }
    }

    private func finishButtonCapture() {
        let waiters: [() -> Void] = stateLock.withLock {
            buttonPending = false
            defer { buttonWaiters = [] }
            return buttonWaiters
        }
        waiters.forEach { $0() }
    }

    func interceptorButtonCapturePending() -> Bool { stateLock.withLock { buttonPending } }

    func interceptorWaitForButtonCapture(done: @escaping () -> Void) {
        let pending: Bool = stateLock.withLock {
            if buttonPending { buttonWaiters.append(done) }
            return buttonPending
        }
        if !pending { done() }
    }
}
