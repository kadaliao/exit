import AppKit

/// What the user is about to do.
enum Intent {
    case closeWindow, quitApp, minimize

    var event: WindowEvent {
        switch self {
        case .closeWindow: .close
        case .quitApp: .quit
        case .minimize: .minimize
        }
    }
}

protocol EventInterceptorDelegate: AnyObject {
    /// Tap thread, must return immediately: should this shortcut be held while we snapshot?
    func interceptorShouldHold(_ intent: Intent) -> Bool
    /// Tap thread: start the snapshot (asynchronously) and call `done` from any thread.
    func interceptorPrepare(_ intent: Intent, done: @escaping () -> Void)
    /// Tap thread: a left click happened (never held). Used to detect traffic-light buttons.
    func interceptorMouseDown(at point: CGPoint)
    /// Tap thread: is a close/minimize-button snapshot still running?
    func interceptorButtonCapturePending() -> Bool
    /// Tap thread: call `done` once the pending button snapshot finishes.
    func interceptorWaitForButtonCapture(done: @escaping () -> Void)
}

/// A session event tap that briefly holds ⌘W / ⌘Q / ⌘M (and the mouse-up on a close button)
/// so the window can be photographed in its true final state before it disappears.
/// Only those shortcuts are ever looked at; every other event passes straight through.
final class EventInterceptor {
    weak var delegate: EventInterceptorDelegate?

    private let thread = RunLoopThread(name: "exit.tap")
    private var threadStarted = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private static let tag: Int64 = 0x4558_4954  // "EXIT": marks events we re-post

    private let lock = NSLock()
    private var holding = false
    private var held: [CGEvent] = []
    private var holdStarted: CFAbsoluteTime = 0
    private var generation = 0

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        if !threadStarted { thread.startAndWait(); threadStarted = true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: tapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log.error("event tap creation failed (Accessibility not granted?)")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        source = src
        thread.async { [thread] in
            CFRunLoopAddSource(thread.runLoop, src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return true
    }

    func stop() {
        guard let tap, let source else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        let src = source
        thread.async { [thread] in CFRunLoopRemoveSource(thread.runLoop, src, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.source = nil
        releaseAll()
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.tag { return pass }

        // While something is held, queue everything after it so order is preserved.
        lock.lock()
        if holding {
            if CFAbsoluteTimeGetCurrent() - holdStarted > 0.4 {
                // Failsafe: never keep input hostage.
                lock.unlock()
                releaseAll()
                return pass
            }
            if let copy = event.copy() { held.append(copy) }
            lock.unlock()
            return nil
        }
        lock.unlock()

        guard let delegate else { return pass }
        switch type {
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return pass }
            let flags = event.flags
            guard flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskAlternate) else { return pass }
            let intent: Intent?
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 13: intent = .closeWindow                                   // W (⇧⌘W closes windows in browsers)
            case 12: intent = flags.contains(.maskShift) ? nil : .quitApp    // Q (⇧⌘Q is Log Out)
            case 46: intent = flags.contains(.maskShift) ? nil : .minimize   // M
            default: intent = nil
            }
            guard let intent, delegate.interceptorShouldHold(intent) else { return pass }
            hold(event, timeout: 0.16) { done in delegate.interceptorPrepare(intent, done: done) }
            return nil

        case .leftMouseDown:
            delegate.interceptorMouseDown(at: event.location)
            return pass

        case .leftMouseUp:
            guard delegate.interceptorButtonCapturePending() else { return pass }
            hold(event, timeout: 0.14) { done in delegate.interceptorWaitForButtonCapture(done: done) }
            return nil

        default:
            return pass
        }
    }

    private func hold(_ event: CGEvent, timeout: Double, work: (@escaping () -> Void) -> Void) {
        guard let copy = event.copy() else { return }
        lock.lock()
        holding = true
        held = [copy]
        holdStarted = CFAbsoluteTimeGetCurrent()
        generation += 1
        let gen = generation
        lock.unlock()

        let release: () -> Void = { [weak self] in self?.release(generation: gen) }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + timeout, execute: release)
        work(release)
    }

    private func release(generation gen: Int) {
        lock.lock()
        guard holding, generation == gen else { lock.unlock(); return }
        let events = held
        held = []
        holding = false
        lock.unlock()
        repost(events)
    }

    private func releaseAll() {
        lock.lock()
        let events = held
        held = []
        holding = false
        lock.unlock()
        repost(events)
    }

    private func repost(_ events: [CGEvent]) {
        for e in events {
            e.setIntegerValueField(.eventSourceUserData, value: Self.tag)
            e.post(tap: .cgSessionEventTap)
        }
    }
}

private func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventInterceptor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
