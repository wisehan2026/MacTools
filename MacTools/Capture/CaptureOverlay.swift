import AppKit
import Combine
import SwiftUI

@MainActor
final class CaptureOverlayState: ObservableObject {
    @Published var title = ""
    @Published var actionTitle = ""
    @Published var actionEnabled = true
    var action: (() -> Void)?
    var cancel: (() -> Void)?
}

/// 边框面板不接收鼠标，控制条单独放置；两者均属于当前应用，会被屏幕采集过滤器排除。
@MainActor
final class CaptureOverlay {
    static let shared = CaptureOverlay()
    private var border: NSPanel?
    private var controls: NSPanel?
    private let state = CaptureOverlayState()

    func show(rect: CGRect, title: String, actionTitle: String, action: @escaping () -> Void, cancel: (() -> Void)? = nil, enabled: Bool = true) {
        hide()
        state.title = title; state.actionTitle = actionTitle; state.action = action; state.cancel = cancel; state.actionEnabled = enabled
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let expanded = rect.insetBy(dx: -3, dy: -3)
        let visible = screen.map { expanded.intersection($0.frame) } ?? expanded
        let outline = NSPanel(contentRect: visible, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        outline.isOpaque = false; outline.backgroundColor = .clear; outline.hasShadow = false
        outline.level = .floating; outline.ignoresMouseEvents = true
        outline.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        outline.contentView = CaptureBorderView(frame: CGRect(origin: .zero, size: visible.size))
        outline.orderFrontRegardless(); border = outline

        let area = screen?.visibleFrame ?? rect
        let width = min(450.0, area.width - 16), height = 56.0
        let x = max(area.minX + 8, min(rect.minX, area.maxX - width - 8))
        let y = rect.maxY + height + 10 <= area.maxY ? rect.maxY + 8 : max(area.minY + 8, rect.minY - height - 8)
        let panel = NSPanel(contentRect: CGRect(x: x, y: y, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: CaptureHUDView(state: state))
        panel.orderFrontRegardless(); controls = panel
    }

    func update(title: String, actionEnabled: Bool? = nil) {
        state.title = title
        if let actionEnabled { state.actionEnabled = actionEnabled }
    }
    func reveal() { controls?.orderFrontRegardless(); border?.orderFrontRegardless() }
    func disableCancel() { state.cancel = nil; state.objectWillChange.send() }
    func hide() { border?.orderOut(nil); controls?.orderOut(nil); border = nil; controls = nil; state.action = nil; state.cancel = nil }
}

private final class CaptureBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4)
        path.lineWidth = 2
        path.stroke()
    }
}

private struct CaptureHUDView: View {
    @ObservedObject var state: CaptureOverlayState
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text(state.title).font(.callout.monospacedDigit()).lineLimit(2)
            Spacer(minLength: 4)
            if state.cancel != nil { Button("取消") { state.cancel?() }.buttonStyle(.borderless) }
            Button(state.actionTitle) { state.action?() }.buttonStyle(.borderedProminent).tint(.red).disabled(!state.actionEnabled)
        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
