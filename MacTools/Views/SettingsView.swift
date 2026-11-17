import SwiftUI
import Carbon

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var hotkeys = HotKeyManager.shared
    @State private var tab = 0
    @State private var message = ""
    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .settings)
            Picker("设置分类", selection: $tab) {
                Text("通用").tag(0); Text("功能开关").tag(5); Text("快捷键").tag(1)
                if settings.isEnabled(.clipboard) { Text("剪贴板").tag(2) }
                if settings.isEnabled(.memes) { Text("表情包").tag(4) }
                Text("权限与关于").tag(3)
            }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if tab == 0 {
                        Text("应用外观").font(.headline)
                        Picker("外观", selection: $settings.appearance) {
                            ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        Text("立即应用到所有窗口；跟随系统会自动响应 macOS 的深色与浅色切换。")
                            .font(.callout).foregroundStyle(.secondary)
                        Divider()
                        Toggle("登录后自动启动", isOn: Binding(get: { settings.launchAtLogin }, set: { enabled in
                            do { try settings.setLaunchAtLogin(enabled) }
                            catch { message = error.localizedDescription }
                        }))
                        Text("关闭窗口后仍在菜单栏运行；使用菜单栏中的「退出」完全结束。").font(.callout).foregroundStyle(.secondary)
                        Divider()
                        if settings.isEnabled(.screenshot) || settings.isEnabled(.scrollshot) {
                            directoryRow(title: "截图保存目录", path: settings.screenshotDirectory, recording: false)
                        }
                        if settings.isEnabled(.recording) { directoryRow(title: "录像保存目录", path: settings.recordingDirectory, recording: true) }
                        if settings.isEnabled(.screenshot) || settings.isEnabled(.scrollshot) || settings.isEnabled(.ocr) || settings.isEnabled(.recording) {
                            Divider()
                            Text("常用截图尺寸").font(.headline)
                            ForEach(settings.presets, id: \.self) { preset in
                                HStack { Text(preset); Spacer(); Button("移除") { settings.presets.removeAll { $0 == preset } } }
                            }
                            Text("在截图窗口输入宽高后，点击 + 添加常用尺寸。").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if tab == 5 {
                        Text("功能开关").font(.headline)
                        Text("关闭后隐藏主页、菜单栏及快捷键入口，并关闭该功能窗口。再次打开即可恢复，原有设置和已保存数据保留。")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("总入口与设置始终保留。剪贴板历史关闭后停止记录；正在采集的截图、长截图或录像需先完成或取消。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Feature.configurable) { feature in
                            Toggle(isOn: Binding(get: { settings.isEnabled(feature) }, set: { enabled in
                                message = WindowCoordinator.shared.setFeatureEnabled(feature, enabled: enabled)
                            })) {
                                Label(feature.title, systemImage: feature.icon)
                            }
                            Divider()
                        }
                    } else if tab == 1 {
                        Text("点击组合键后按下新快捷键，Esc 取消。截图、长截图、OCR 和录屏直接执行采集，其余功能打开窗口。").foregroundStyle(.secondary)
                        ForEach(settings.shortcutFeatures) { feature in
                            HStack {
                                Label(feature.title, systemImage: feature.icon)
                                Spacer()
                                ShortcutRecorder(feature: feature, message: $message).frame(width: 180, height: 30)
                                Button("恢复") {
                                    settings.shortcuts[feature.rawValue] = Shortcut.standard(for: feature)
                                    hotkeys.register()
                                }
                                Button("停用") { settings.shortcuts.removeValue(forKey: feature.rawValue); hotkeys.register() }
                            }
                            Divider()
                        }
                        ForEach(hotkeys.failures, id: \.self) { Text($0).foregroundStyle(.orange).font(.callout) }
                    } else if tab == 2 {
                        Stepper("保留 \(settings.retentionDays) 天（包含今天）", value: $settings.retentionDays, in: 1...365)
                        Stepper("容量上限：\(settings.capacityMB) MB", value: $settings.capacityMB, in: 64...16_384, step: 64)
                        Text("天数与容量同时生效，收藏不自动删除。修改规则后立即应用；收藏占满容量时暂停新增记录。").font(.callout).foregroundStyle(.secondary)
                        Divider()
                        Text("不记录这些应用").font(.headline)
                        Text("每行一个 Bundle ID。带有保密或临时标记的剪贴板内容会自动跳过。").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $settings.excludedApps).font(.system(.body, design: .monospaced)).frame(minHeight: 130).padding(6)
                        Button("添加正在运行的应用…") { chooseExcludedApp() }
                    } else if tab == 4 {
                        Text("搜索来源（可多选）").font(.headline)
                        Text("拖动左侧手柄调整顺序，搜索结果按来源从上到下依次显示。右键手柄也可上移、下移。")
                            .font(.callout).foregroundStyle(.secondary)
                        Toggle("自定义每个来源的数量", isOn: Binding(get: { settings.memeCustomDistribution }, set: { settings.setMemeCustomDistribution($0) }))
                        ForEach(settings.memeSourceOrder) { source in MemeSourceSettingsRow(source: source) }
                        Text("已选 \(settings.memeSources.count) 个来源，最多显示 \(settings.memeSearchPlan.total) 条；重复或返回不足时按实际结果显示。")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("默认最多 50 条平均分配。自定义时每源 1～50 条，总量按填写数量相加；关闭自定义可恢复平均分配。")
                            .font(.callout).foregroundStyle(.secondary)
                        Divider()
                        Text("搜索缓存").font(.headline)
                        Stepper("缓存保留 \(settings.memeCacheDays) 天", value: $settings.memeCacheDays, in: 1...365)
                        Text("默认 3 天，从最近一次成功搜索刷新起计算。修改后立即清理超过保留时间的缓存。")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("缓存按关键词、来源组合及分配数量保存；每源优先更新，超限或失败时使用该源有效缓存。调整顺序可复用缓存，读取不会续期。")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("搜索缓存、剪贴板历史与本地表情独立。清理缓存不会删除已复制、收藏或手动导入的表情包。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("清理表情搜索缓存") {
                            Task {
                                do { try await MemeSearchService.shared.clearCache(); message = "表情搜索缓存已清理" }
                                catch { message = "清理失败：\(error.localizedDescription)" }
                            }
                        }
                    } else {
                        Label("MacTools \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")", systemImage: "square.grid.2x2").font(.title2.weight(.medium))
                        Text("Swift 原生工具 · 仅在本机保存数据").foregroundStyle(.secondary)
                        Divider()
                        permissionRow("屏幕录制", detail: "截图、滚动长截图、文字识别和录屏需要此权限。", action: PermissionLinks.screen)
                        permissionRow("麦克风", detail: "只在你开启麦克风录制时请求。", action: PermissionLinks.microphone)
                        permissionRow("文件访问", detail: "指定目录搜索遇到受保护位置时，可在系统设置中调整访问权限。", action: PermissionLinks.files)
                        Divider()
                        Text("开源依赖").font(.headline)
                        Text("表情搜索仅访问设置中选中的来源。memecub 匿名每日 20 次；其他来源有各自限制。结果和图片缓存保存在本机，其余工具使用 macOS 系统框架。")
                            .font(.callout).foregroundStyle(.secondary)
                        Link("查看 memecub 开源项目", destination: MemeSearchService.repository)
                    }
                    StatusLine(text: message)
                }.padding(24)
            }
        }.onChange(of: settings.disabledFeatures) { _, _ in
            if (tab == 2 && !settings.isEnabled(.clipboard)) || (tab == 4 && !settings.isEnabled(.memes)) { tab = 5 }
        }
    }
    private func directoryRow(title: String, path: String, recording: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text(title).font(.headline); Spacer(); Button("更改…") { settings.chooseDirectory(recording: recording) } }
            Text(path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
    private func permissionRow(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("打开设置", action: action)
        }
    }
    private func chooseExcludedApp() {
        let menu = NSMenu()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in apps {
            guard let id = app.bundleIdentifier else { continue }
            let item = NSMenuItem(title: "\(app.localizedName ?? id)（\(id)）", action: #selector(ExcludedAppAction.select(_:)), keyEquivalent: "")
            item.representedObject = id; item.target = ExcludedAppAction.shared
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

@MainActor
private final class ExcludedAppAction: NSObject {
    static let shared = ExcludedAppAction()
    @objc func select(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let settings = SettingsStore.shared
        if !settings.excludedApps.components(separatedBy: .newlines).contains(id) { settings.excludedApps += "\n" + id }
    }
}

/// 通过 AppKit 按钮捕获真实键码和修饰键，SwiftUI 负责展示配置和错误信息。
struct ShortcutRecorder: NSViewRepresentable {
    let feature: Feature
    @Binding var message: String
    func makeNSView(context: Context) -> ShortcutButton {
        let view = ShortcutButton()
        view.feature = feature
        view.onResult = { message = $0 }
        return view
    }
    func updateNSView(_ view: ShortcutButton, context: Context) {
        view.feature = feature
        if !view.recording { view.title = SettingsStore.shared.shortcuts[feature.rawValue]?.label ?? "点击设置" }
    }
}

final class ShortcutButton: NSButton {
    var feature = Feature.launcher
    var recording = false
    var onResult: ((String) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded; title = "点击设置"; target = self; action = #selector(begin)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func begin() {
        recording = true; title = "请按组合键…"
        HotKeyManager.shared.beginRecordingShortcut()
        window?.makeFirstResponder(self)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 录入时先接收包含 Command 的组合键，避免它提前被普通菜单快捷键处理。
        if recording { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { end(); return }
        // 只读取设备无关的修饰键标记，再转换成 Carbon 注册所需的位掩码。
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        label += event.keyCode == 49 ? "空格" : (event.charactersIgnoringModifiers?.uppercased() ?? "\(event.keyCode)")
        let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label)
        onResult?(HotKeyManager.shared.set(shortcut, for: feature) ?? "快捷键已更新")
        end()
    }
    private func end() {
        if recording { HotKeyManager.shared.endRecordingShortcut() }
        recording = false; title = SettingsStore.shared.shortcuts[feature.rawValue]?.label ?? "点击设置"
    }
    // 用户点击其他控件或切走窗口时也结束录入，恢复之前暂停的全局快捷键。
    override func resignFirstResponder() -> Bool { end(); return super.resignFirstResponder() }
}
