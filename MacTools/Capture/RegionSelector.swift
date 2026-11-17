import AppKit

/// 按系统窗口前后顺序排列，命中时选择鼠标下最靠前的正常应用窗口。
struct WindowSuggestion {
    let frame: CGRect
    let title: String

    static func hit(at point: CGPoint, in suggestions: [WindowSuggestion]) -> WindowSuggestion? {
        suggestions.first { $0.frame.contains(point) }
    }
}

/// 将多屏选区的鼠标交互包装成一次异步调用，结束后返回采集目标，取消则返回 nil。
@MainActor
final class RegionSelector {
    static let shared = RegionSelector()
    private var panels: [SelectionWindow] = []
    private var continuation: CheckedContinuation<CaptureTarget?, Never>?
    private var keyMonitor: Any?
    var isSelecting: Bool { continuation != nil }

    /// pixelSize 是用户指定的最终像素尺寸；每块屏幕按自身倍率换算为选框的逻辑尺寸。
    func select(pixelSize: CGSize? = nil) async throws -> CaptureTarget? {
        // 同时只允许一个选区会话；开始新会话前先恢复旧调用，避免 continuation 悬挂。
        if continuation != nil { finish(nil) }
        let suggestions = windowSuggestions()
        let screens = NSScreen.screens
        var backgrounds: [CGDirectDisplayID: CGImage] = [:]
        // 遮罩必须保持不透明：完全透明的“挖空”区域会让 WindowServer 把点击交给底下的应用。
        // 在创建遮罩前取得屏幕底图，选中区域重绘原图，其余区域叠加暗色，视觉通透但输入不穿透。
        for screen in screens {
            let id = CaptureService.displayID(screen)
            backgrounds[id] = try await CaptureService.capture(CaptureTarget(displayID: id, scale: screen.backingScaleFactor))
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            NSApp.activate(ignoringOtherApps: true)
            // 每个显示器独立创建遮罩，选区坐标保持在该显示器内部，不拼接跨屏区域。
            for screen in screens {
                let panel = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                panel.level = .screenSaver
                panel.title = "截图选区"
                panel.backgroundColor = .black
                panel.isOpaque = true
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.ignoresMouseEvents = false
                panel.isReleasedWhenClosed = false
                panel.isMovable = false
                panel.acceptsMouseMovedEvents = true
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
                view.backgroundImage = backgrounds[CaptureService.displayID(screen)]
                view.pixelSize = pixelSize
                view.scale = screen.backingScaleFactor
                view.suggestions = suggestions.compactMap { suggestion in
                    let intersection = suggestion.frame.intersection(screen.frame)
                    guard !intersection.isNull, intersection.width >= 40, intersection.height >= 40 else { return nil }
                    let local = intersection.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                    return WindowSuggestion(frame: local, title: suggestion.title)
                }
                view.completed = { [weak self] rect in
                    guard let rect else { self?.finish(nil); return }
                    // AppKit 原点在左下角；屏幕采集的选区原点在左上角。
                    let source = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
                    self?.finish(CaptureTarget(displayID: CaptureService.displayID(screen), rect: source, scale: screen.backingScaleFactor))
                }
                panel.contentView = view
                panels.append(panel)
                panel.orderFrontRegardless()
                let pointer = NSEvent.mouseLocation
                if screen.frame.contains(pointer) {
                    view.suggest(at: CGPoint(x: pointer.x - screen.frame.minX, y: pointer.y - screen.frame.minY))
                }
            }
            // 多屏时将键盘焦点交给鼠标所在屏幕，避免默认落到最后创建的副屏遮罩。
            activateSelection()
            // Esc 在应用事件入口处理，不依赖某个显示器的选区视图恰好是 firstResponder。
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, self.isSelecting, event.keyCode == 53 else { return false }
                    self.finish(nil)
                    return true
                }
                return handled ? nil : event
            }
        }
    }

    func activateSelection() {
        guard let panel = panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? panels.first else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
    }

    private func windowSuggestions() -> [WindowSuggestion] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return windows.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ProcessInfo.processInfo.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary), bounds.width >= 80, bounds.height >= 60 else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? "应用窗口"
            let name = info[kCGWindowName as String] as? String ?? ""
            return WindowSuggestion(frame: CaptureGeometry.appKitRect(fromQuartz: bounds, primaryTop: primaryTop), title: name.isEmpty ? owner : "\(owner) · \(name)")
        }
    }

    /// 所有完成和取消路径统一到这里，先清空保存的 continuation，再恢复等待者，防止重复恢复。
    private func finish(_ target: CaptureTarget?) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        panels.forEach { $0.orderOut(nil); $0.close(); $0.contentView = nil }
        panels.removeAll()
        let completion = continuation
        continuation = nil
        completion?.resume(returning: target)
    }
}

/// 使用可成为主窗口的 NSWindow，避免工具面板默认焦点规则吞掉首次鼠标操作。
final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    var backgroundImage: CGImage?
    var pixelSize: CGSize?
    var scale: CGFloat = 2
    var completed: ((CGRect?) -> Void)?
    var suggestions: [WindowSuggestion] = []
    private var start: NSPoint?
    private var selection = CGRect.zero
    private var suggestionTitle: String?
    private var dragging = false
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) { if start == nil { suggest(at: convert(event.locationInWindow, from: nil)) } }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        if start == nil { selection = .zero; suggestionTitle = nil; needsDisplay = true }
    }
    func suggest(at point: CGPoint) {
        if let pixels = pixelSize {
            placeFixedSize(pixels, at: point)
            suggestionTitle = nil
        } else if let candidate = WindowSuggestion.hit(at: point, in: suggestions) {
            selection = candidate.frame; suggestionTitle = candidate.title
        } else { selection = .zero; suggestionTitle = nil }
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completed?(nil) }
    }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        dragging = false
        if let start { suggest(at: start) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        // 按住左键并移动超过 3 点即改为自由框选；保留轻微抖动容差，避免普通单击误变成很小的截图。
        if hypot(point.x - start.x, point.y - start.y) > 3 { dragging = true }
        if dragging { suggestionTitle = nil; update(event) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragging || pixelSize != nil { update(event) }
        // 单击采用悬停建议区域；拖动则采用自定义区域，不再弹二次确认。
        if selection.width >= 4 && selection.height >= 4 { completed?(selection) }
        start = nil; dragging = false
    }
    private func placeFixedSize(_ pixels: CGSize, at point: CGPoint) {
        let size = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        guard size.width <= bounds.width, size.height <= bounds.height else { selection = .zero; return }
        selection = CGRect(x: max(0, min(point.x, bounds.width - size.width)), y: max(0, min(point.y, bounds.height - size.height)), width: size.width, height: size.height)
    }
    private func update(_ event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let pixels = pixelSize {
            // 固定尺寸模式移动选框的位置，并将其限制在当前屏幕边界内。
            placeFixedSize(pixels, at: point)
        } else {
            selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y)).intersection(bounds)
        }
        // 先换算到像素取整再换回逻辑点，让 Retina 屏幕上的选框边缘落在完整像素上。
        selection = CGRect(x: (selection.minX * scale).rounded() / scale, y: (selection.minY * scale).rounded() / scale,
                           width: (selection.width * scale).rounded() / scale, height: (selection.height * scale).rounded() / scale)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.black.setFill()
        bounds.fill()
        if let backgroundImage { context.draw(backgroundImage, in: bounds) }
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if !selection.isEmpty {
            context.saveGState()
            context.clip(to: selection)
            if let backgroundImage { context.draw(backgroundImage, in: bounds) }
            context.restoreGState()
            NSColor.systemTeal.setStroke()
            let path = NSBezierPath(rect: selection)
            path.lineWidth = 2
            path.stroke()
        }
        let size = "\(Int(selection.width * scale)) × \(Int(selection.height * scale)) px"
        let label: String
        if let suggestionTitle { label = "\(String(suggestionTitle.prefix(26))) · \(size) · 单击截图 / 按住左键拖动自定义" }
        else { label = selection.isEmpty ? "悬停窗口后单击 · 按住左键拖动自定义 · Esc 取消" : "\(size) · 松开完成 · Esc 取消" }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: label, attributes: attributes)
        let box = CGRect(x: (bounds.width - text.size().width) / 2 - 18, y: bounds.height - 80, width: text.size().width + 36, height: 44)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        text.draw(at: CGPoint(x: box.minX + 18, y: box.minY + 12))
    }
}
