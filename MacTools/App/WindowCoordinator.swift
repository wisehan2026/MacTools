import AppKit
import SwiftUI

/// 管理 SwiftUI 内容与 NSWindow 的桥接，以及功能窗口、编辑窗口的不同生命周期。
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = WindowCoordinator()
    private let settings: SettingsStore
    private var windows: [String: NSWindow] = [:]
    private var captures: [Feature: CaptureController] = [:]
    private var videoEditors: [String: VideoEditorController] = [:]
    var hasActiveVideoExport: Bool { videoEditors.values.contains { $0.exporting } }

    init(settings: SettingsStore = .shared) { self.settings = settings; super.init() }

    func revealActiveVideoExport() {
        if let key = videoEditors.first(where: { $0.value.exporting })?.key, let window = windows[key] { activate(window) }
    }

    /// 快捷键与状态栏菜单直接执行；只有主页按钮通过 show 进入二级配置页。
    func performQuickAction(_ feature: Feature) {
        guard settings.isEnabled(feature) else { return }
        switch feature {
        case .screenshot, .ocr:
            Task { await captureController(for: feature).capture(ocr: feature == .ocr) }
        case .scrollshot:
            let controller = captureController(for: feature)
            if controller.scrolling { Task { await controller.finishScrolling() } }
            else { Task { await controller.startScrolling() } }
        case .recording:
            if RecordingController.shared.isRecording || RecordingController.shared.busy { CaptureOverlay.shared.reveal() }
            else { Task { await RecordingController.shared.start() } }
        default: show(feature)
        }
    }

    private func captureController(for feature: Feature) -> CaptureController {
        if let controller = captures[feature] { return controller }
        let controller = CaptureController(feature: feature)
        controller.onImage = { [weak self] in self?.edit($0) }
        controller.onResult = { [weak self] in self?.show(feature) }
        captures[feature] = controller
        return controller
    }

    /// 同一功能复用已创建的窗口，重复唤起时保留输入、筛选条件和控制器状态。
    func show(_ feature: Feature) {
        guard settings.isEnabled(feature) else { return }
        if let window = windows[feature.rawValue] { activate(window); return }
        let view: AnyView
        let size: CGSize
        switch feature {
        case .launcher: view = AnyView(LauncherView()); size = CGSize(width: 560, height: 700)
        case .clipboard: view = AnyView(ClipboardView()); size = CGSize(width: 940, height: 650)
        case .screenshot, .scrollshot, .ocr:
            let controller = captureController(for: feature)
            view = AnyView(CaptureView(feature: feature, controller: controller)); size = CGSize(width: 660, height: feature == .ocr ? 650 : 480)
        case .recording: view = AnyView(RecordingView()); size = CGSize(width: 680, height: 560)
        case .search: view = AnyView(SearchView()); size = CGSize(width: 920, height: 640)
        case .memes: view = AnyView(MemeSearchView()); size = CGSize(width: 960, height: 680)
        case .phrases: view = AnyView(PhrasesView()); size = CGSize(width: 800, height: 580)
        case .storage: view = AnyView(StorageView()); size = CGSize(width: 870, height: 600)
        case .settings: view = AnyView(SettingsView()); size = CGSize(width: 740, height: 660)
        }
        let window = makeWindow(title: feature.title, content: view, size: size)
        if feature == .memes { window.minSize = CGSize(width: 800, height: 520) }
        window.identifier = NSUserInterfaceItemIdentifier(feature.rawValue)
        window.setFrameAutosaveName("MacTools." + feature.rawValue)
        windows[feature.rawValue] = window
        activate(window)
    }

    /// 采集中的任务须先正常结束，避免关闭开关丢弃未完成的长截图或录像。
    func setFeatureEnabled(_ feature: Feature, enabled: Bool) -> String {
        if !enabled {
            if feature == .recording, RecordingController.shared.isRecording || RecordingController.shared.busy {
                return "录屏正在进行，请先停止录制或取消准备，再关闭此功能。"
            }
            if let capture = captures[feature], capture.busy || capture.scrolling {
                return "\(feature.title)正在进行，请先完成或取消当前采集，再关闭此功能。"
            }
        }
        settings.setFeatureEnabled(feature, enabled: enabled)
        return "\(feature.title)已\(enabled ? "启用" : "关闭")"
    }

    func applyFeatureSettings() {
        for feature in Feature.configurable where !settings.isEnabled(feature) {
            guard let window = windows[feature.rawValue] else { continue }
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel); sheet.close() }
            window.close()
        }
    }

    /// 每张截图创建独立文档和窗口，支持同时编辑多张图，撤销记录也互不影响。
    func edit(_ image: CGImage) {
        let document = AnnotationDocument(image: image)
        let key = "editor." + UUID().uuidString
        let window = makeWindow(title: "截图编辑", content: AnyView(AnnotationEditorView(document: document)), size: CGSize(width: 1000, height: 740))
        window.identifier = NSUserInterfaceItemIdentifier(key)
        windows[key] = window
        activate(window)
    }

    func editVideo(_ url: URL, temporary: Bool = false) {
        let key = "video." + UUID().uuidString
        let controller = VideoEditorController(url: url, temporary: temporary)
        videoEditors[key] = controller
        let window = makeWindow(title: "录像预览与编辑", content: AnyView(VideoEditorView(controller: controller)), size: CGSize(width: 1160, height: 800))
        window.minSize = CGSize(width: 980, height: 620)
        window.identifier = NSUserInterfaceItemIdentifier(key)
        windows[key] = window
        activate(window)
        // AppKit 承载的窗口由协调器显式启动加载，不依赖 SwiftUI .task 的挂载时机。
        Task { await controller.load() }
    }

    /// 置顶窗口只缩放显示尺寸，传入图片的像素数据保持不变。
    func pin(_ image: CGImage) {
        let ratio = min(1, 520 / CGFloat(image.width), 650 / CGFloat(image.height))
        let view = Image(decorative: image, scale: 1).resizable().scaledToFit().padding(4)
        let key = "pin." + UUID().uuidString
        let size = CGSize(width: max(180, CGFloat(image.width) * ratio), height: max(120, CGFloat(image.height) * ratio))
        let window = makeWindow(title: "置顶图片", content: AnyView(view), size: size)
        window.minSize = CGSize(width: 120, height: 100)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.identifier = NSUserInterfaceItemIdentifier(key)
        windows[key] = window
        activate(window)
    }

    private func makeWindow(title: String, content: AnyView, size: CGSize) -> NSWindow {
        let window = ToolWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        // 由 windows 字典持有并决定释放时机，普通功能窗口关闭后还可再次唤起。
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.tint(.teal))
        window.minSize = CGSize(width: min(size.width, 600), height: min(size.height, 420))
        window.delegate = self
        window.center()
        return window
    }

    private func activate(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
    }

    /// 临时图片窗口关闭即移除；长截图控制窗口关闭时必须取消后台采样。
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let key = window.identifier?.rawValue else { return }
        if key.hasPrefix("editor.") || key.hasPrefix("pin.") || key.hasPrefix("video.") { windows.removeValue(forKey: key) }
        if key == Feature.scrollshot.rawValue { captures[.scrollshot]?.cancelScrolling() }
        if let editor = videoEditors.removeValue(forKey: key) { editor.close() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 关闭的含义是丢弃本次未保存编辑；取消正在进行的导出，不隐式保存任何文件。
        if let key = sender.identifier?.rawValue { videoEditors[key]?.cancelExport() }
        return true
    }

    func discardRecordingDrafts() {
        for editor in videoEditors.values { editor.close() }
    }
}

/// 在窗口层接收关闭组合键，避免 field editor 或播放器截获后无法沿菜单响应链关闭。
final class ToolWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.keyCode == 13 {
            performClose(nil)
            return true
        }
        // 输入框内优先执行文本编辑，避免截图页的“复制图片/撤销标注”快捷键抢走按键。
        if let editor = firstResponder as? NSTextView, editor.isFieldEditor {
            if modifiers == [.command, .shift], event.keyCode == 6 { editor.undoManager?.redo(); return true }
            if modifiers == .command {
                switch event.keyCode {
                case 0: editor.selectAll(nil)
                case 7: editor.cut(nil)
                case 8: editor.copy(nil)
                case 9: editor.paste(nil)
                case 6: editor.undoManager?.undo()
                default: return super.performKeyEquivalent(with: event)
                }
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
