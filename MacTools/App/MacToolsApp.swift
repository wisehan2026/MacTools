import AppKit
import Combine

/// 原生应用入口：建立 AppKit 事件循环，具体功能由窗口协调器和各业务控制器管理。
@main
struct MacToolsApp {
    @MainActor
    static func main() {
        // 自测在启动菜单栏、快捷键和剪贴板监听前运行，避免干扰用户当前会话。
        if CommandLine.arguments.contains("--self-test") { SelfTests.run(); return }
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--local-memes-self-test") {
            Task { @MainActor in await LocalMemeSelfTests.run() }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--meme-sources-self-test") || CommandLine.arguments.contains("--meme-sources-live-test") {
            Task { @MainActor in
                if CommandLine.arguments.contains("--meme-sources-live-test") { await MemeSourceSelfTests.live() }
                else { await MemeSourceSelfTests.run() }
            }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--meme-cache-self-test") {
            Task { @MainActor in await MemeCacheSelfTests.run() }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--meme-live-test") {
            Task { @MainActor in await MemeSelfTests.live() }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--video-self-test") {
            Task { @MainActor in await VideoSelfTests.run() }
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        // accessory 模式隐藏 Dock 图标，但仍允许显示窗口和菜单栏入口。
        app.setActivationPolicy(.accessory)
        // NSApplication 的 delegate 不负责强持有对象，需让代理存活至事件循环结束。
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// 负责应用级生命周期；在主线程统一连接菜单、快捷键、剪贴板和录屏状态。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem?
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "MacTools")
        rebuildStatusMenu()
        SettingsStore.shared.$appearance.removeDuplicates().sink { $0.apply() }.store(in: &subscriptions)
        SettingsStore.shared.$disabledFeatures.dropFirst().removeDuplicates().sink { [weak self] _ in
            // @Published 在赋值前通知，下一次主线程调度后统一读取新设置。
            Task { @MainActor in
                self?.rebuildStatusMenu()
                HotKeyManager.shared.register()
                WindowCoordinator.shared.applyFeatureSettings()
                if !SettingsStore.shared.isEnabled(.memes) { await MemeSearchService.shared.suspendRequests() }
            }
        }.store(in: &subscriptions)
        CapturePresentation.shared.observeApplications()
        // 状态栏与快捷键共用直接执行入口；主页的功能按钮仍调用 show 进入配置页。
        HotKeyManager.shared.onFeature = { WindowCoordinator.shared.performQuickAction($0) }
        HotKeyManager.shared.register()
        ClipboardStore.shared.start()
        // 启动、修改保留天数及每分钟均执行缓存清理，未打开搜索窗口时也会自动过期。
        SettingsStore.shared.$memeCacheDays.removeDuplicates().sink { days in
            Task { await MemeSearchService.shared.configureCache(days: days, startMaintenance: true) }
        }.store(in: &subscriptions)
        // 控制器独立于窗口存活，关闭录屏窗口后仍可通过菜单栏看见录制状态。
        RecordingController.shared.$isRecording.sink { [weak self] recording in
            self?.item?.button?.image = NSImage(systemSymbolName: recording ? "record.circle.fill" : "square.grid.2x2", accessibilityDescription: recording ? "正在录制，打开控制窗口停止" : "MacTools")
        }.store(in: &subscriptions)
        if let index = CommandLine.arguments.firstIndex(of: "--preview-video"), index + 1 < CommandLine.arguments.count {
            WindowCoordinator.shared.editVideo(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        } else if let index = CommandLine.arguments.firstIndex(of: "--preview-image"), index + 1 < CommandLine.arguments.count,
                  let image = LocalFiles.image(URL(fileURLWithPath: CommandLine.arguments[index + 1])) {
            WindowCoordinator.shared.edit(image)
        } else if !CommandLine.arguments.contains("--background") { WindowCoordinator.shared.show(.launcher) }
    }

    /// 菜单与主页、快捷键使用同一启用清单，关闭项不留占位，也不留下空分组。
    static func statusMenu(settings: SettingsStore, target: AnyObject? = nil) -> NSMenu {
        let menu = NSMenu()
        let groups: [[Feature]] = [[.launcher], settings.launcherFeatures, [.settings]]
        for group in groups where !group.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for feature in group {
                let entry = NSMenuItem(title: feature.title, action: #selector(openFeature(_:)), keyEquivalent: "")
                entry.representedObject = feature.rawValue; entry.target = target
                entry.image = NSImage(systemSymbolName: feature.icon, accessibilityDescription: nil)
                let shortcut = settings.activeShortcut(for: feature)
                entry.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
                entry.keyEquivalentModifierMask = shortcut?.menuModifiers ?? []
                menu.addItem(entry)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 MacTools", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func rebuildStatusMenu() {
        let menu = Self.statusMenu(settings: .shared, target: self)
        menu.delegate = self
        item?.menu = menu
    }

    @objc private func openFeature(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let feature = Feature(rawValue: raw) else { return }
        dismissToolMenus()
        WindowCoordinator.shared.performQuickAction(feature)
    }

    /// 每次展开菜单都读取最新配置，修改、停用或恢复快捷键后无需重启。
    func menuNeedsUpdate(_ menu: NSMenu) { updateStatusShortcuts(menu) }
    private func updateStatusShortcuts(_ menu: NSMenu) {
        for entry in menu.items {
            guard let raw = entry.representedObject as? String, let feature = Feature(rawValue: raw) else { continue }
            let shortcut = SettingsStore.shared.activeShortcut(for: feature)
            entry.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
            entry.keyEquivalentModifierMask = shortcut?.menuModifiers ?? []
        }
    }

    func dismissToolMenus() {
        item?.menu?.cancelTrackingWithoutAnimation()
        NSApp.mainMenu?.cancelTrackingWithoutAnimation()
    }

    /// 通过 AppKit 响应链处理标准编辑和窗口操作，保留输入框内的 ⌘C、⌘V 等行为。
    private func configureMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 MacTools", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; main.addItem(editItem)
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu; main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    /// 录制、倒计时或文件收尾期间阻止退出，避免输出文件尚未完成就结束进程。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if WindowCoordinator.shared.hasActiveVideoExport {
            let alert = NSAlert()
            alert.messageText = "请先完成或取消视频导出"
            alert.addButton(withTitle: "返回编辑窗口")
            alert.runModal()
            WindowCoordinator.shared.revealActiveVideoExport()
            return .terminateCancel
        }
        if RecordingController.shared.isRecording || RecordingController.shared.busy {
            let alert = NSAlert()
            alert.messageText = "请先完成录制"
            alert.informativeText = "请先停止录制，并在预览中保存或丢弃录像后退出。"
            alert.addButton(withTitle: "打开录屏窗口")
            alert.runModal()
            WindowCoordinator.shared.show(.recording)
            return .terminateCancel
        }
        return .terminateNow
    }
    // 窗口与进程的生命周期分离：没有可见窗口时也继续提供菜单栏和剪贴板历史。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { WindowCoordinator.shared.discardRecordingDrafts() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if RegionSelector.shared.isSelecting { RegionSelector.shared.activateSelection() }
        else { WindowCoordinator.shared.show(.launcher) }
        return true
    }
}
