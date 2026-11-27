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
        NSApp.appearance = Settings.shared.appearance.nsAppearance
        installMainMenu()
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

        MainActor.assumeIsolated {
            MarketStore.shared.startAutoRefresh()
            Updater.shared.start()
        }

        if AX.isTrusted() {
            ExitEngine.shared.start()
        } else {
            openSettings(tab: .permissions)
            waitForAccessibility()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Updater.shared.installOnQuit() }
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

    /// Exit shows no menu bar of its own, but the Settings window's shortcuts (⌘W, ⌘M, ⌘Q, and
    /// cut / copy / paste in text fields) still come from the main menu.
    private func installMainMenu() {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String,
                  _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = modifiers
            i.target = target
            return i
        }
        func add(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
        }
        add("Exit", [
            item(T("Settings…", "设置…"), #selector(openSettingsAction), ",", target: self),
            item(T("Check for Updates…", "检查更新…"), #selector(checkForUpdates), "", target: self),
            .separator(),
            item(T("Quit Exit", "退出 Exit"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        add(T("Edit", "编辑"), [
            item(T("Undo", "撤销"), Selector(("undo:")), "z"),
            item(T("Redo", "重做"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(T("Cut", "剪切"), #selector(NSText.cut(_:)), "x"),
            item(T("Copy", "拷贝"), #selector(NSText.copy(_:)), "c"),
            item(T("Paste", "粘贴"), #selector(NSText.paste(_:)), "v"),
            item(T("Select All", "全选"), #selector(NSText.selectAll(_:)), "a"),
        ])
        add(T("Window", "窗口"), [
            item(T("Close", "关闭"), #selector(NSWindow.performClose(_:)), "w"),
            item(T("Minimize", "最小化"), #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        NSApp.mainMenu = main
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

        // A new version waiting goes first.
        let updateTitle: String? = MainActor.assumeIsolated {
            let u = Updater.shared
            guard let r = u.release, !u.isWorking else { return nil }
            if case .installed = u.state { return T("Relaunch to Use Exit \(r.version)", "重新打开以使用 Exit \(r.version)") }
            return T("Update to Exit \(r.version)…", "更新到 Exit \(r.version)…")
        }
        if let updateTitle {
            let up = NSMenuItem(title: updateTitle, action: #selector(updateNow), keyEquivalent: "")
            up.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            up.target = self
            menu.addItem(up)
            menu.addItem(.separator())
        }

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
            it.toolTip = e.meta.displayDescription
            pm.addItem(it)
        }
        preview.submenu = pm
        menu.addItem(preview)

        let ai = NSMenuItem(title: T("Create an Effect with AI…", "用 AI 生成特效…"), action: #selector(openAI), keyEquivalent: "")
        ai.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        ai.target = self
        menu.addItem(ai)

        let market = NSMenuItem(title: T("Effect Market…", "特效市场…"), action: #selector(openMarket), keyEquivalent: "")
        market.image = NSImage(systemSymbolName: "storefront", accessibilityDescription: nil)
        market.target = self
        menu.addItem(market)

        let folder = NSMenuItem(title: T("Open Effects Folder", "打开特效文件夹"), action: #selector(openFolder), keyEquivalent: "")
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folder.target = self
        menu.addItem(folder)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: T("Settings…", "设置…"), action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let check = NSMenuItem(title: T("Check for Updates…", "检查更新…"), action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
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
        func add(_ title: String, _ a: Assignment, tip: String? = nil) {
            let it = NSMenuItem(title: title, action: #selector(assign(_:)), keyEquivalent: "")
            it.toolTip = tip
            it.representedObject = AssignmentBox(event: event, assignment: a)
            it.state = current == a ? .on : .off
            it.target = self
            m.addItem(it)
        }
        add(T("Off", "关闭"), .off)
        add(T("Shuffle", "随机"), .random)
        m.addItem(.separator())
        for e in EffectLibrary.shared.effects where e.meta.events.contains(event) && e.isReady {
            add(e.meta.displayName, .effect(e.id), tip: e.meta.displayDescription)
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

    @objc private func checkForUpdates() {
        MainActor.assumeIsolated { _ = Task { await Updater.shared.check(userInitiated: true) } }
    }

    @objc private func updateNow() {
        MainActor.assumeIsolated {
            let u = Updater.shared
            if case .installed = u.state { u.relaunch() } else if let r = u.release { u.offer(r) }
        }
    }

    @objc private func openFolder() { NSWorkspace.shared.open(Paths.userEffects) }
    @objc private func openAI() { openSettings(tab: .ai) }
    @objc private func openMarket() { openSettings(tab: .market) }
    @objc private func openPermissions() { openSettings(tab: .permissions) }
    @objc private func openSettingsAction() { openSettings(tab: nil) }

    func openSettings(tab: SettingsTab?) {
        if let tab { navigation.tab = tab }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(navigation))
            let w = ExitWindow(contentViewController: host)
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

/// Exit's own window. Closing or minimizing it (button, ⌘W, ⌘M) waits a moment while the engine
/// photographs it, so its effect starts from the real last frame.
final class ExitWindow: NSWindow {
    private var waiting = false

    override func performClose(_ sender: Any?) {
        hold(.close) { super.performClose(sender) }
    }

    override func performMiniaturize(_ sender: Any?) {
        hold(.minimize) { super.performMiniaturize(sender) }
    }

    private func hold(_ event: WindowEvent, then action: @escaping () -> Void) {
        guard !waiting else { return }
        waiting = true
        ExitEngine.shared.prepareOwnWindow(self, for: event) { [weak self] in
            self?.waiting = false
            action()
        }
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
