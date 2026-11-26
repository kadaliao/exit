import AppKit
import Metal
import ScreenCaptureKit

/// A window picture ready for the GPU.
final class Snapshot {
    let windowID: CGWindowID
    let texture: MTLTexture
    /// Frame at capture time, top-left global points.
    let frame: CGRect
    let time: Date
    /// Taken right before a close/quit/minimize the user just asked for.
    let isIntent: Bool

    init(windowID: CGWindowID, texture: MTLTexture, frame: CGRect, time: Date, isIntent: Bool) {
        self.windowID = windowID
        self.texture = texture
        self.frame = frame
        self.time = time
        self.isIntent = isIntent
    }

    var age: TimeInterval { Date().timeIntervalSince(time) }
}

/// Captures single windows with ScreenCaptureKit and keeps a small in-memory cache.
/// Nothing is ever written to disk.
final class SnapshotService {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    private let lock = NSLock()
    private var cache: [CGWindowID: Snapshot] = [:]
    private var order: [CGWindowID] = []
    private let capacity = 6
    private var content: SCShareableContent?
    private var contentTime = Date.distantPast
    private var inFlight: [CGWindowID: Task<Snapshot?, Never>] = [:]

    /// Cached permission flag, refreshed periodically from the main thread.
    private(set) var permitted = SnapshotService.hasPermission

    func refreshPermission() {
        let p = Self.hasPermission
        lock.withLock { permitted = p }
    }

    func latest(for id: CGWindowID) -> Snapshot? { lock.withLock { cache[id] } }

    func forget(_ id: CGWindowID) {
        lock.withLock {
            cache[id] = nil
            order.removeAll { $0 == id }
        }
    }

    /// Takes a fresh picture of a window. Concurrent requests for the same window share one capture.
    func capture(_ id: CGWindowID, intent: Bool) async -> Snapshot? {
        guard lock.withLock({ permitted }) else { return nil }
        let task: Task<Snapshot?, Never> = lock.withLock {
            if let t = inFlight[id] { return t }
            let t = Task.detached(priority: .userInitiated) { [weak self] () -> Snapshot? in
                await self?.performCapture(id, intent: intent)
            }
            inFlight[id] = t
            return t
        }
        let result = await task.value
        lock.withLock { inFlight[id] = nil }
        return result
    }

    func isCapturing(_ id: CGWindowID) -> Bool { lock.withLock { inFlight[id] != nil } }

    /// Waits (briefly) for an in-flight capture of this window to land in the cache.
    func waitForCapture(_ id: CGWindowID, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isCapturing(id) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    private func scWindow(_ id: CGWindowID) -> SCWindow? {
        lock.withLock { content?.windows.first { $0.windowID == id } }
    }

    func refreshContent(force: Bool = false) async {
        if !force, lock.withLock({ Date().timeIntervalSince(contentTime) < 0.25 }) { return }
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            lock.withLock {
                content = c
                contentTime = Date()
            }
        } catch {
            log.error("shareable content failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func performCapture(_ id: CGWindowID, intent: Bool) async -> Snapshot? {
        var window = scWindow(id)
        if window == nil {
            await refreshContent(force: true)
            window = scWindow(id)
        }
        guard let window else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        var w = filter.contentRect.width * scale
        var h = filter.contentRect.height * scale
        let maxDim: CGFloat = 3600
        if max(w, h) > maxDim { let k = maxDim / max(w, h); w *= k; h *= k }
        guard w >= 8, h >= 8 else { return nil }
        config.width = Int(w)
        config.height = Int(h)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let tex = Renderer.shared.makeTexture(from: image) else { return nil }
            let snap = Snapshot(windowID: id, texture: tex, frame: window.frame, time: Date(), isIntent: intent)
            store(snap)
            return snap
        } catch {
            log.error("capture \(id) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func store(_ s: Snapshot) {
        lock.withLock {
            // Never let a background refresh replace a fresh intent snapshot.
            if let existing = cache[s.windowID], existing.isIntent, existing.age < 2, !s.isIntent { return }
            cache[s.windowID] = s
            order.removeAll { $0 == s.windowID }
            order.append(s.windowID)
            while order.count > capacity {
                let old = order.removeFirst()
                cache[old] = nil
            }
        }
    }
}
