import AppKit
import SwiftUI

/// 用 SwiftUI 观察文档变化，再交由 AppKit 画布处理精确鼠标轨迹和图像绘制。
struct AnnotationCanvas: NSViewRepresentable {
    @ObservedObject var document: AnnotationDocument
    func makeNSView(context: Context) -> DrawingView { let view = DrawingView(); view.document = document; return view }
    func updateNSView(_ view: DrawingView, context: Context) { view.document = document; view.needsDisplay = true }
}

final class DrawingView: NSView {
    var document: AnnotationDocument?
    // 拖动中的临时标注只参与预览，松开鼠标后才作为一次操作加入撤销列表。
    private var draft: Annotation?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        guard let document, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: document.zoom, y: document.zoom)
        AnnotationRenderer.draw(image: document.image, annotations: document.annotations + (draft.map { [$0] } ?? []), in: context)
        context.restoreGState()
    }
    /// 将窗口坐标转到画布，再除以显示倍率还原为原图像素，并限制在图片边界内。
    private func point(_ event: NSEvent, document: AnnotationDocument) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: max(0, min(CGFloat(document.image.width), p.x / document.zoom)), y: max(0, min(CGFloat(document.image.height), p.y / document.zoom)))
    }
    override func mouseDown(with event: NSEvent) {
        guard let document else { return }
        let point = point(event, document: document)
        draft = Annotation(tool: document.tool, points: [point, point], color: document.color, width: document.lineWidth,
                           text: document.text, fontSize: document.fontSize)
        // 文字在单击时直接提交，不需要拖动确定结束点。
        if document.tool == .text {
            if !document.text.isEmpty, let draft { document.add(draft) } else { document.message = "先在工具栏输入文字，再点击图片放置" }
            draft = nil
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let document, draft != nil else { return }
        let p = point(event, document: document)
        if draft?.tool == .pen { draft?.points.append(p) } else { draft?.points[1] = p }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        if let draft { document?.add(draft) }
        draft = nil
        needsDisplay = true
    }
}
