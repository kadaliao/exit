import AppKit
import ApplicationServices

struct WindowInfo: Hashable {
    let windowID: CGWindowID
    let pid: pid_t
    /// Global frame, top-left origin (AX / CGWindow space).
    var frame: CGRect
    var title: String
    let bundleID: String?
    let appName: String
}

protocol WindowTrackerDelegate: AnyObject {
    /// Main thread.
    func windowTracker(_ tracker: WindowTracker, observed event: WindowEvent, window: WindowInfo)
    /// Main thread.
    func windowTracker(_ tracker: WindowTracker, focusChangedTo window: WindowInfo?)
    /// Main thread. `windows` are the app's windows that were visible when it quit.
    func windowTracker(_ tracker: WindowTracker, appTerminated pid: pid_t, windows: [WindowInfo])
}

/// Follows every regular app's windows through Accessibility notifications and reports
/// open / close / minimize, plus focus changes.
final class WindowTracker {
    weak var delegate: WindowTrackerDelegate?

    private final class TrackedWindow {
        let element: AXUIElement
        var info: WindowInfo
        var minimized = false
        let created = Date()
        init(element: AXUIElement, info: WindowInfo) { self.element = element; self.info = info }
    }

    private final class App {
        let pid: pid_t
        let element: AXUIElement
        let bundleID: String?
        let name: String
        var observer: AXObserver?
        var windows: [TrackedWindow] = []
        init(_ app: NSRunningApplication) {
            pid = app.processIdentifier
            element = AXUIElementCreateApplication(pid)
            bundleID = app.bundleIdentifier
            name = app.localizedName ?? app.bundleIdentifier ?? "App"
            AXUIElementSetMessagingTimeout(element, 1.0)
        }
    }

    private let thread = RunLoopThread(name: "exit.ax")
    private var apps: [pid_t: App] = [:]            // AX thread only
    private var started = false

    // Shared state readable from any thread.
    private let lock = NSLock()
    private var _focused: WindowInfo?
    private var _onScreen: [CGWindowID: CGRect] = [:]
    /// The list before the latest refresh, so a window that vanished just before its destroy
    /// notification arrived still counts as visible.
    private var _prevOnScreen: [CGWindowID: CGRect] = [:]
    private var _windows: [CGWindowID: WindowInfo] = [:]
    /// Same windows as `_onScreen`, front to back, with their owners.
    private var _stack: [(id: CGWindowID, frame: CGRect, pid: pid_t)] = []
    /// Exit's own key window, if any.
    private var _ownKey: WindowInfo?

    private var screenTimer: DispatchSourceTimer?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var ownTokens: [NSObjectProtocol] = []
    /// Exit's own windows that are open (visible or minimized). Main thread only.
    private var ownOpen: Set<ObjectIdentifier> = []

    static let ignoredBundles: Set<String> = [
        "com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.loginwindow",
        "com.apple.screencaptureui", "com.apple.ScreenContinuity",
    ]

    // MARK: Public, thread-safe

    var focusedWindow: WindowInfo? { lock.withLock { _focused } }

    func info(for id: CGWindowID) -> WindowInfo? { lock.withLock { _windows[id] } }

    func windows(of pid: pid_t) -> [WindowInfo] { lock.withLock { _windows.values.filter { $0.pid == pid } } }

    /// Visible windows on the current Space with their frames (top-left origin).
    func onScreenWindows() -> [CGWindowID: CGRect] { lock.withLock { _onScreen } }

    func isOnScreen(_ id: CGWindowID) -> Bool { lock.withLock { _onScreen[id] != nil } }

    /// The frontmost ordinary window under a global (top-left origin) point.
    func topWindow(at point: CGPoint) -> (id: CGWindowID, frame: CGRect, pid: pid_t)? {
        lock.withLock { _stack.first { $0.frame.contains(point) } }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        thread.startAndWait()

        let nc = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.thread.async { self?.observe(app, attempt: 0) }
        })
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.thread.async { self?.appTerminated(app.processIdentifier) }
        })
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.thread.async { self?.refreshFocus(pid: app.processIdentifier) }
        })
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshOnScreen()
        })
        startOwnWindows()

        let running = NSWorkspace.shared.runningApplications
        thread.async { [weak self] in
            guard let self else { return }
            for app in running { self.observe(app, attempt: 0) }
            if let front = NSWorkspace.shared.frontmostApplication { self.refreshFocus(pid: front.processIdentifier) }
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(700), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.refreshOnScreen() }
        timer.resume()
        screenTimer = timer
    }

    // MARK: On-screen list (CGWindowList; needs no permission for bounds)

    func refreshOnScreen() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        var map: [CGWindowID: CGRect] = [:]
        var stack: [(id: CGWindowID, frame: CGRect, pid: pid_t)] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { continue }
            map[id] = rect
            stack.append((id, rect, (w[kCGWindowOwnerPID as String] as? pid_t) ?? 0))
        }
        lock.withLock {
            _prevOnScreen = _onScreen
            _onScreen = map
            _stack = stack
            // Keep cached frames fresh even if a move notification was missed.
            for (id, rect) in map where _windows[id] != nil { _windows[id]?.frame = rect }
        }
    }

    // MARK: AX thread

    private func observe(_ running: NSRunningApplication, attempt: Int) {
        let pid = running.processIdentifier
        guard apps[pid] == nil, pid != getpid(), running.activationPolicy == .regular,
              !Self.ignoredBundles.contains(running.bundleIdentifier ?? "") else { return }

        let app = App(running)
        var observer: AXObserver?
        guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let r1 = AXObserverAddNotification(observer, app.element, kAXWindowCreatedNotification as CFString, refcon)
        _ = AXObserverAddNotification(observer, app.element, kAXFocusedWindowChangedNotification as CFString, refcon)
        if r1 != .success && r1 != .notificationAlreadyRegistered {
            // Freshly launched apps are often not ready yet; retry a few times.
            if attempt < 6 {
                let delay = [0.3, 0.6, 1.0, 2.0, 4.0, 8.0][attempt]
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.thread.async { self?.observe(running, attempt: attempt + 1) }
                }
            }
            return
        }
        CFRunLoopAddSource(thread.runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        app.observer = observer
        apps[pid] = app
        for w in AX.elements(app.element, kAXWindowsAttribute) { track(w, in: app) }
    }

    @discardableResult
    private func track(_ el: AXUIElement, in app: App) -> TrackedWindow? {
        if let existing = app.windows.first(where: { CFEqual($0.element, el) }) { return existing }
        guard AX.string(el, kAXRoleAttribute) == kAXWindowRole as String else { return nil }
        let subrole = AX.string(el, kAXSubroleAttribute) ?? ""
        guard subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String else { return nil }
        guard let id = AX.windowID(el), let frame = AX.frame(el) else { return nil }
        let info = WindowInfo(windowID: id, pid: app.pid, frame: frame,
                              title: AX.string(el, kAXTitleAttribute) ?? "", bundleID: app.bundleID, appName: app.name)
        let tw = TrackedWindow(element: el, info: info)
        tw.minimized = AX.bool(el, kAXMinimizedAttribute) ?? false
        if let observer = app.observer {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for n in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                      kAXWindowDeminiaturizedNotification, kAXMovedNotification, kAXResizedNotification] {
                AXObserverAddNotification(observer, el, n as CFString, refcon)
            }
        }
        app.windows.append(tw)
        lock.withLock { _windows[id] = info }
        return tw
    }

    private func find(_ el: AXUIElement) -> (App, TrackedWindow)? {
        if let pid = AX.pid(el), let app = apps[pid], let w = app.windows.first(where: { CFEqual($0.element, el) }) {
            return (app, w)
        }
        for app in apps.values {
            if let w = app.windows.first(where: { CFEqual($0.element, el) }) { return (app, w) }
        }
        return nil
    }

    fileprivate func handle(_ notification: String, element el: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            guard let pid = AX.pid(el), let app = apps[pid], let tw = track(el, in: app) else { return }
            // Give the window a moment to appear on screen before decorating it.
            let id = tw.info.windowID
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.refreshOnScreen()
                self?.thread.async {
                    guard let self, let (_, w) = self.find(el), !w.minimized, self.isOnScreen(id) else { return }
                    if let f = AX.frame(el) { self.updateFrame(w, f) }
                    let info = w.info
                    DispatchQueue.main.async { self.delegate?.windowTracker(self, observed: .open, window: info) }
                }
            }

        case kAXUIElementDestroyedNotification:
            guard let (app, w) = find(el) else { return }
            app.windows.removeAll { $0 === w }
            let id = w.info.windowID
            let visible: Bool = lock.withLock {
                _windows[id] = nil
                let onScreen = _onScreen[id] != nil || _prevOnScreen[id] != nil
                let fresh = Date().timeIntervalSince(w.created) < 1.0
                return !w.minimized && (onScreen || fresh)
            }
            guard visible else { return }
            let info = lock.withLock { () -> WindowInfo in
                var i = w.info
                if let f = _onScreen[id] ?? _prevOnScreen[id] { i.frame = f }
                return i
            }
            DispatchQueue.main.async { self.delegate?.windowTracker(self, observed: .close, window: info) }

        case kAXWindowMiniaturizedNotification:
            guard let (_, w) = find(el), !w.minimized else { return }
            w.minimized = true
            let info = w.info
            DispatchQueue.main.async { self.delegate?.windowTracker(self, observed: .minimize, window: info) }

        case kAXWindowDeminiaturizedNotification:
            find(el)?.1.minimized = false

        case kAXMovedNotification, kAXResizedNotification:
            guard let (_, w) = find(el), let f = AX.frame(el) else { return }
            updateFrame(w, f)

        case kAXFocusedWindowChangedNotification:
            guard let pid = AX.pid(el), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            refreshFocus(pid: pid)

        default:
            break
        }
    }

    private func updateFrame(_ w: TrackedWindow, _ f: CGRect) {
        w.info.frame = f
        let id = w.info.windowID
        lock.withLock { _windows[id]?.frame = f }
    }

    private func refreshFocus(pid: pid_t) {
        var info: WindowInfo?
        if pid == getpid() {
            info = lock.withLock { _ownKey }
        } else if apps[pid] == nil, let running = NSRunningApplication(processIdentifier: pid) {
            observe(running, attempt: 0)
        }
        if pid != getpid(), let app = apps[pid], let el = AX.element(app.element, kAXFocusedWindowAttribute), let tw = track(el, in: app) {
            if let f = AX.frame(el) { updateFrame(tw, f) }
            tw.info.title = AX.string(el, kAXTitleAttribute) ?? tw.info.title
            info = tw.info
        }
        let changed: Bool = lock.withLock {
            let old = _focused
            _focused = info
            if let info { _windows[info.windowID] = info }
            return old?.windowID != info?.windowID
        }
        if changed {
            DispatchQueue.main.async { self.delegate?.windowTracker(self, focusChangedTo: info) }
        }
    }

    // MARK: Exit's own windows (main thread)
    //
    // Exit isn't watched through Accessibility like other apps (that would mean asking its own
    // main thread for answers), so its Settings window is followed through AppKit instead.

    private static func isOwnTracked(_ w: NSWindow) -> Bool {
        !(w is NSPanel) && w.styleMask.contains(.titled)
    }

    private func ownInfo(_ w: NSWindow) -> WindowInfo? {
        guard w.windowNumber > 0 else { return nil }
        return WindowInfo(windowID: CGWindowID(w.windowNumber), pid: getpid(), frame: ScreenGeometry.toGlobal(w.frame),
                          title: w.title, bundleID: Bundle.main.bundleIdentifier, appName: "Exit")
    }

    private func startOwnWindows() {
        let handlers: [(Notification.Name, (WindowTracker, NSWindow) -> Void)] = [
            (NSWindow.didChangeOcclusionStateNotification, { $0.ownWindowMaybeOpened($1) }),
            (NSWindow.didBecomeKeyNotification, { $0.ownWindowMaybeOpened($1); $0.ownFocusChanged() }),
            (NSWindow.didResignKeyNotification, { t, _ in t.ownFocusChanged() }),
            (NSWindow.willMiniaturizeNotification, { $0.ownWindowWillMiniaturize($1) }),
            (NSWindow.willCloseNotification, { $0.ownWindowWillClose($1) }),
        ]
        for (name, handler) in handlers {
            ownTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let self, let w = n.object as? NSWindow, Self.isOwnTracked(w) else { return }
                handler(self, w)
            })
        }
        // Settings may already be up: it asks for permissions before tracking can start.
        for w in NSApp.windows where Self.isOwnTracked(w) && w.isVisible { ownWindowMaybeOpened(w, announce: false) }
        ownFocusChanged()
    }

    private func ownWindowMaybeOpened(_ w: NSWindow, announce: Bool = true) {
        let key = ObjectIdentifier(w)
        guard !ownOpen.contains(key), w.isVisible, !w.isMiniaturized, let info = ownInfo(w) else { return }
        ownOpen.insert(key)
        lock.withLock { _windows[info.windowID] = info }
        guard announce else { return }
        // Let it reach the screen and draw first, as with other apps' new windows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak w] in
            guard let self, let w, w.isVisible, let info = self.ownInfo(w) else { return }
            self.refreshOnScreen()
            self.delegate?.windowTracker(self, observed: .open, window: info)
        }
    }

    private func ownWindowWillMiniaturize(_ w: NSWindow) {
        guard ownOpen.contains(ObjectIdentifier(w)), let info = ownInfo(w) else { return }
        delegate?.windowTracker(self, observed: .minimize, window: info)
    }

    private func ownWindowWillClose(_ w: NSWindow) {
        guard ownOpen.remove(ObjectIdentifier(w)) != nil, let info = ownInfo(w) else { return }
        lock.withLock { _windows[info.windowID] = nil }
        if !w.isMiniaturized { delegate?.windowTracker(self, observed: .close, window: info) }
    }

    private func ownFocusChanged() {
        let key = NSApp.keyWindow.flatMap { Self.isOwnTracked($0) ? ownInfo($0) : nil }
        let active = NSApp.isActive
        let changed: Bool = lock.withLock {
            _ownKey = key
            if let key { _windows[key.windowID] = key }
            guard active else { return false }
            let old = _focused
            _focused = key
            return old?.windowID != key?.windowID
        }
        if changed { delegate?.windowTracker(self, focusChangedTo: key) }
    }

    private func appTerminated(_ pid: pid_t) {
        guard let app = apps.removeValue(forKey: pid) else { return }
        let visible: [WindowInfo] = lock.withLock {
            var out: [WindowInfo] = []
            for w in app.windows {
                let id = w.info.windowID
                if !w.minimized, let f = _onScreen[id] ?? _prevOnScreen[id] {
                    var i = w.info
                    i.frame = f
                    out.append(i)
                }
                _windows[id] = nil
            }
            if _focused?.pid == pid { _focused = nil }
            return out
        }
        if let observer = app.observer {
            CFRunLoopRemoveSource(thread.runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        DispatchQueue.main.async { self.delegate?.windowTracker(self, appTerminated: pid, windows: visible) }
    }
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    tracker.handle(notification as String, element: element)
}
