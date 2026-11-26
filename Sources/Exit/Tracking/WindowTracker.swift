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

    private var screenTimer: DispatchSourceTimer?
    private var workspaceTokens: [NSObjectProtocol] = []

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
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { continue }
            map[id] = rect
        }
        lock.withLock {
            _prevOnScreen = _onScreen
            _onScreen = map
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
        if apps[pid] == nil, let running = NSRunningApplication(processIdentifier: pid) { observe(running, attempt: 0) }
        var info: WindowInfo?
        if let app = apps[pid], let el = AX.element(app.element, kAXFocusedWindowAttribute), let tw = track(el, in: app) {
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
