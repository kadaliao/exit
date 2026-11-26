import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    let navigation = SettingsNavigation()

    func applicationDidFinishLaunching(_ notification: Notification) {
        EffectLibrary.shared.loadAll()
        EffectLibrary.shared.startWatching()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Settings.shared.$enabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusIcon() } }
            .store(in: &cancellables)

        // `Exit --preview <effect-id>`: play one effect on the demo window, then quit.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
            let id = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let e = EffectLibrary.shared.effect(id: id) else { print("no effect \(id)"); exit(2) }
                EffectLibrary.shared.compile(e, synchronously: true)
                ExitEngine.shared.overlay.prewarm()
                ExitEngine.shared.preview(e)
                DispatchQueue.main.asyncAfter(deadline: .now() + e.meta.duration / Settings.shared.speed + 0.6) { exit(0) }
            }
            return
        }

        if AX.isTrusted() {
            ExitEngine.shared.start()
        } else {
            openSettings(tab: .permissions)
            waitForAccessibility()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(tab: nil)
        return true
    }

    private func waitForAccessibility() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard AX.isTrusted() else { return }
            t.invalidate()
            self?.permissionTimer = nil
            ExitEngine.shared.start()
        }
    }

    private func updateStatusIcon() {
        let name = Settings.shared.enabled ? "door.left.hand.open" : "door.left.hand.closed"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Exit")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        let toggle = NSMenuItem(title: T("Effects On", "特效已开启"), action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = s.enabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)

        if !AX.isTrusted() {
            let warn = NSMenuItem(title: T("⚠︎ Needs Accessibility permission…", "⚠︎ 需要辅助功能权限…"), action: #selector(openPermissions), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }
        menu.addItem(.separator())

        for event in [WindowEvent.close, .quit, .open, .minimize] {
            let item = NSMenuItem(title: "\(event.title): \(assignmentTitle(s.assignment(for: event)))", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: event.symbol, accessibilityDescription: nil)
            item.submenu = assignmentMenu(for: event)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let preview = NSMenuItem(title: T("Preview", "预览"), action: nil, keyEquivalent: "")
        preview.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: nil)
        let pm = NSMenu()
        for e in EffectLibrary.shared.effects {
            let it = NSMenuItem(title: e.meta.displayName, action: #selector(previewEffect(_:)), keyEquivalent: "")
            it.representedObject = e.id
            it.target = self
            it.isEnabled = e.isReady
            pm.addItem(it)
        }
        preview.submenu = pm
        menu.addItem(preview)

        let ai = NSMenuItem(title: T("Create an Effect with AI…", "用 AI 生成特效…"), action: #selector(openAI), keyEquivalent: "")
        ai.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        ai.target = self
        menu.addItem(ai)

        let folder = NSMenuItem(title: T("Open Effects Folder", "打开特效文件夹"), action: #selector(openFolder), keyEquivalent: "")
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folder.target = self
        menu.addItem(folder)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: T("Settings…", "设置…"), action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: T("Quit Exit", "退出 Exit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func assignmentTitle(_ a: Assignment) -> String {
        switch a {
        case .off: T("Off", "关闭")
        case .random: T("Shuffle", "随机")
        case .effect(let id): EffectLibrary.shared.effect(id: id)?.meta.displayName ?? id
        }
    }

    private func assignmentMenu(for event: WindowEvent) -> NSMenu {
        let m = NSMenu()
        let current = Settings.shared.assignment(for: event)
        func add(_ title: String, _ a: Assignment) {
            let it = NSMenuItem(title: title, action: #selector(assign(_:)), keyEquivalent: "")
            it.representedObject = AssignmentBox(event: event, assignment: a)
            it.state = current == a ? .on : .off
            it.target = self
            m.addItem(it)
        }
        add(T("Off", "关闭"), .off)
        add(T("Shuffle", "随机"), .random)
        m.addItem(.separator())
        for e in EffectLibrary.shared.effects where e.meta.events.contains(event) && e.isReady {
            add(e.meta.displayName, .effect(e.id))
        }
        return m
    }

    @objc private func toggleEnabled() { Settings.shared.enabled.toggle() }

    @objc private func assign(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? AssignmentBox else { return }
        Settings.shared.assignments[box.event] = box.assignment
    }

    @objc private func previewEffect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let e = EffectLibrary.shared.effect(id: id) else { return }
        // Let the menu close first so the preview isn't hidden behind it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ExitEngine.shared.preview(e) }
    }

    @objc private func openFolder() { NSWorkspace.shared.open(Paths.userEffects) }
    @objc private func openAI() { openSettings(tab: .ai) }
    @objc private func openPermissions() { openSettings(tab: .permissions) }
    @objc private func openSettingsAction() { openSettings(tab: nil) }

    func openSettings(tab: SettingsTab?) {
        if let tab { navigation.tab = tab }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(navigation))
            let w = NSWindow(contentViewController: host)
            w.title = "Exit"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.setContentSize(NSSize(width: 860, height: 600))
            w.minSize = NSSize(width: 760, height: 520)
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

private final class AssignmentBox: NSObject {
    let event: WindowEvent
    let assignment: Assignment
    init(event: WindowEvent, assignment: Assignment) {
        self.event = event
        self.assignment = assignment
    }
}
