import AppKit

/// 仅检查隔离偏好、菜单模型与命名剪贴板，不注册热键、不打开页面或采集真实屏幕。
@MainActor
enum SettingsSelfTests {
    static func run(check: (Bool, String) -> Void) {
        let suite = "MacTools.SettingsTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let board = NSPasteboard(name: NSPasteboard.Name(suite))
        let app = NSApplication.shared
        let priorAppearance = app.appearance
        defer {
            app.appearance = priorAppearance
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            board.releaseGlobally()
        }
        let settings = SettingsStore(defaults: defaults)
        check(settings.launcherFeatures == Feature.configurable && settings.disabledFeatures.isEmpty, "旧配置默认启用全部工具")
        check(settings.appearance == .system, "外观默认跟随系统")
        let originalShortcut = settings.shortcuts[Feature.memes.rawValue]
        settings.setFeatureEnabled(.memes, enabled: false)
        check(!settings.launcherFeatures.contains(.memes) && !settings.shortcutFeatures.contains(.memes), "关闭功能同时从主页与快捷键清单移除")
        check(settings.activeShortcut(for: .memes) == nil && settings.shortcuts[Feature.memes.rawValue] == originalShortcut, "关闭后快捷键失效且保留原组合键")
        let menu = AppDelegate.statusMenu(settings: settings)
        let menuIDs = menu.items.compactMap { ($0.representedObject as? String).flatMap(Feature.init(rawValue:)) }
        check(menuIDs == settings.enabledFeatures && !menuIDs.contains(.memes), "菜单仅包含启用项且顺序不变")
        check(SettingsStore(defaults: defaults).disabledFeatures == [.memes], "关闭状态重启后保持")
        settings.setFeatureEnabled(.memes, enabled: true)
        check(settings.activeShortcut(for: .memes) == originalShortcut && settings.launcherFeatures.contains(.memes), "重新启用恢复入口及原快捷键")
        for feature in Feature.allCases { settings.setFeatureEnabled(feature, enabled: false) }
        check(settings.enabledFeatures == [.launcher, .settings], "全部关闭后仍保留总入口与设置")
        let emptyMenu = AppDelegate.statusMenu(settings: settings)
        let emptyIDs = emptyMenu.items.compactMap { $0.representedObject as? String }
        check(emptyIDs == [Feature.launcher.rawValue, Feature.settings.rawValue], "菜单隐藏所有关闭的工具")
        let doubledSeparators = zip(emptyMenu.items, emptyMenu.items.dropFirst()).contains { $0.isSeparatorItem && $1.isSeparatorItem }
        check(!doubledSeparators, "全部关闭后菜单不出现连续空分组")
        let windowCount = app.windows.count
        let coordinator = WindowCoordinator(settings: settings)
        for feature in Feature.configurable { coordinator.show(feature); coordinator.performQuickAction(feature) }
        check(app.windows.count == windowCount, "直接路由也不能唤起关闭的功能或采集任务")
        settings.appearance = .dark
        settings.appearance.apply()
        check(app.appearance?.name == .darkAqua && SettingsStore(defaults: defaults).appearance == .dark, "深色立即应用并持久化")
        settings.appearance = .light
        settings.appearance.apply()
        check(app.appearance?.name == .aqua && SettingsStore(defaults: defaults).appearance == .light, "浅色立即应用并持久化")
        settings.appearance = .system
        settings.appearance.apply()
        check(app.appearance == nil && SettingsStore(defaults: defaults).appearance == .system, "跟随系统清除强制外观并持久化")
        defaults.set("invalid", forKey: "appearance")
        defaults.set(["unknown", Feature.launcher.rawValue, Feature.settings.rawValue, Feature.search.rawValue], forKey: "disabledFeatures")
        let repaired = SettingsStore(defaults: defaults)
        check(repaired.appearance == .system && repaired.disabledFeatures == [.search], "无效偏好不会隐藏设置入口或破坏默认外观")

        settings.setFeatureEnabled(.clipboard, enabled: true)
        settings.excludedApps = ""
        let store = ClipboardStore(directory: directory, board: board, settings: settings)
        board.clearContents(); board.setString("before disabling", forType: .string); store.poll()
        check(store.entries.count == 1, "启用时正常记录剪贴板")
        settings.setFeatureEnabled(.clipboard, enabled: false)
        store.synchronizeFeatureState()
        board.clearContents(); board.setString("disabled content", forType: .string); store.poll()
        check(store.entries.count == 1, "关闭剪贴板后不再收录且不清空已有记录")
        do {
            let gif = try MemeSelfTests.animatedFixture()
            let notice = try store.copyMeme(MemeMedia(data: gif), title: "本地测试", source: "本地表情")
            check(store.entries.count == 1 && notice.contains("功能已关闭") && board.data(forType: .init("com.compuserve.gif")) == gif,
                  "关闭历史时表情仍可复制但不新增记录")
            settings.setFeatureEnabled(.clipboard, enabled: true)
            store.synchronizeFeatureState(); store.poll()
            check(store.entries.count == 1, "重新开启不补录关闭期间内容")
            board.clearContents(); board.setString("new after enabling", forType: .string); store.poll()
            check(store.entries.count == 2 && store.entries.first?.text == "new after enabling", "重新开启后记录新的复制内容")
        } catch { check(false, "功能开关剪贴板集成：\(error.localizedDescription)") }
    }
}
