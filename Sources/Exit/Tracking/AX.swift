import AppKit
import ApplicationServices

/// Private but long-stable API used by AltTab, yabai, Hammerspoon and friends.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static func isTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? { copy(el, attr) as? String }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? { (copy(el, attr) as? NSNumber)?.boolValue }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        guard let v = copy(el, attr), let arr = v as? [AnyObject] else { return [] }
        return arr.compactMap { obj in
            CFGetTypeID(obj) == AXUIElementGetTypeID() ? (obj as! AXUIElement) : nil
        }
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = copy(el, kAXPositionAttribute), let s = copy(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(el, &id) == .success && id != 0 ? id : nil
    }

    static func pid(_ el: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(el, &pid) == .success ? pid : nil
    }

    /// Topmost accessibility element under a global (top-left origin) point.
    static func element(at point: CGPoint, timeout: Float = 0.15) -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, timeout)
        var el: AXUIElement?
        return AXUIElementCopyElementAtPosition(sys, Float(point.x), Float(point.y), &el) == .success ? el : nil
    }
}

/// A thread with its own run loop. All Accessibility observers live here so a hung app can
/// never stall the UI.
final class RunLoopThread: Thread {
    private var loop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    init(name: String) {
        super.init()
        self.name = name
        qualityOfService = .userInteractive
    }

    override func main() {
        loop = CFRunLoopGetCurrent()
        RunLoop.current.add(NSMachPort(), forMode: .default)  // keep the loop alive
        ready.signal()
        while !isCancelled {
            _ = RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }

    func startAndWait() {
        start()
        ready.wait()
    }

    var runLoop: CFRunLoop { loop! }

    func async(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}
