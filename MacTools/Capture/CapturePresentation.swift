import AppKit

/// 统一管理采集前的界面收起与焦点恢复；会话令牌阻止快速连按产生重叠选区。
@MainActor
final class CapturePresentation {
    static let shared = CapturePresentation()
    private var session: UUID?
    private var hiddenWindows: [NSWindow] = []
    private var previousApplication: NSRunningApplication?
    private var observer: NSObjectProtocol?

    func observeApplications() {
        remember(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.remember(application) }
        }
    }

    private func remember(_ application: NSRunningApplication?) {
        if let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication = application }
    }

    func begin() async throws -> UUID {
        guard session == nil else { throw AppFailure.message("已有截图或录屏任务，请先完成或取消当前操作") }
        let id = UUID()
        session = id
        remember(NSWorkspace.shared.frontmostApplication)
        (NSApp.delegate as? AppDelegate)?.dismissToolMenus()
        let keyWindow = NSApp.keyWindow
        hiddenWindows = NSApp.windows.filter { $0.isVisible && $0.identifier != nil }
        if let keyWindow, let index = hiddenWindows.firstIndex(of: keyWindow) {
            hiddenWindows.remove(at: index); hiddenWindows.insert(keyWindow, at: 0)
        }
        hiddenWindows.forEach { $0.orderOut(nil) }
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
        restoreTargetApplication()
        // 等待菜单收起和窗口合成完成，避免选区建议仍命中刚隐藏的工具窗口。
        try? await Task.sleep(for: .milliseconds(180))
        return id
    }

    func restoreTargetApplication() { previousApplication?.activate(options: []) }

    func end(_ id: UUID?, restoreWindows: Bool) {
        guard let id, session == id else { return }
        session = nil
        let windows = hiddenWindows
        hiddenWindows = []
        if restoreWindows {
            windows.forEach { $0.orderFront(nil) }
            if let window = windows.first { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
        }
    }
}

/// 纯坐标换算统一放在此处，选区、窗口建议和录制边框使用同一规则。
enum CaptureGeometry {
    static func appKitRect(fromQuartz rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func globalRect(sourceRect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + sourceRect.minX, y: screenFrame.maxY - sourceRect.maxY, width: sourceRect.width, height: sourceRect.height)
    }
}
