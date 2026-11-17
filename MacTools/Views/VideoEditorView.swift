import AVKit
import SwiftUI

struct VideoEditorView: View {
    @ObservedObject var controller: VideoEditorController
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "film.stack").foregroundStyle(.teal).font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("录像预览与编辑").font(.title2.weight(.semibold))
                    Text(controller.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("撤销") { controller.undo() }.disabled(!controller.canUndo || controller.exporting).keyboardShortcut("z", modifiers: .command)
                Button("重做") { controller.redo() }.disabled(!controller.canRedo || controller.exporting).keyboardShortcut("z", modifiers: [.command, .shift])
            }.padding(18)
            Divider()
            HSplitView {
                VStack(spacing: 14) {
                    GeometryReader { geometry in
                        let scale = min(geometry.size.width / controller.size.width, geometry.size.height / controller.size.height)
                        let size = CGSize(width: controller.size.width * scale, height: controller.size.height * scale)
                        ZStack {
                            VideoPlaybackView(player: controller.player)
                            if controller.tool != nil {
                                if controller.drawingFrame != nil {
                                    VideoDrawingCanvas(controller: controller)
                                } else { Color.black.opacity(0.7); ProgressView("准备标注画面…") }
                            }
                        }.frame(width: size.width, height: size.height).position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }.background(.black).frame(minHeight: 280)
                    HStack {
                        Button { controller.togglePlayback() } label: { Image(systemName: controller.playing ? "pause.fill" : "play.fill") }
                        Slider(value: Binding(get: { controller.currentTime }, set: { controller.seek(to: $0) }), in: 0...max(0.1, controller.duration))
                        Text("\(controller.currentTime, specifier: "%.1f") / \(controller.duration, specifier: "%.1f") 秒")
                            .font(.caption.monospacedDigit()).frame(width: 135)
                    }.disabled(controller.loading || controller.exporting)
                    HStack {
                        Text("裁剪时段")
                        numberField("开始", value: $controller.trimStart)
                        Text("至")
                        numberField("结束", value: $controller.trimEnd)
                        Text("秒").foregroundStyle(.secondary)
                        Spacer()
                        Button("当前位置设为开始") { controller.trimStart = controller.currentTime }
                        Button("设为结束") { controller.trimEnd = controller.currentTime }
                    }.disabled(controller.loading || controller.exporting)
                }.padding(16).frame(minWidth: 650)
                inspector.frame(minWidth: 260, idealWidth: 280, maxWidth: 320).disabled(controller.loading || controller.exporting)
            }
            Divider()
            VStack(spacing: 10) {
                if controller.exporting { ProgressView(value: controller.exportProgress) }
                HStack {
                    Text(controller.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                    Spacer()
                    if controller.exporting {
                        Button("取消导出") { controller.cancelExport() }
                    } else {
                        if controller.temporary && controller.savedOriginal == nil {
                            Button("保存原录像") { controller.saveOriginal() }.disabled(controller.loading)
                        }
                        if let url = controller.lastExport {
                            Button("播放导出视频") { NSWorkspace.shared.open(url) }
                            Button("定位") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        Button("导出新 MP4") { controller.export() }.buttonStyle(.borderedProminent).tint(.teal).disabled(controller.loading)
                    }
                }
            }.padding(16)
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("画面标注").font(.headline)
                Button("播放 / 浏览模式") { controller.selectTool(nil) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach([AnnotationTool.arrow, .text, .rectangle, .mosaic]) { tool in
                        Button { controller.selectTool(tool) } label: {
                            Label(tool.rawValue, systemImage: tool.icon).frame(maxWidth: .infinity)
                                .padding(.vertical, 5).background(controller.tool == tool ? Color.teal.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.borderless)
                    }
                }
                if controller.tool == .text {
                    EditorInput(text: $controller.text, placeholder: "输入文字，再点击画面").frame(height: 26)
                    HStack { Text("字号"); Slider(value: $controller.fontSize, in: 14...100); Text("\(Int(controller.fontSize))") }
                }
                ColorPicker("颜色", selection: Binding(get: { Color(nsColor: controller.color) }, set: { controller.color = NSColor($0) }))
                HStack { Text("粗细"); Slider(value: $controller.lineWidth, in: 2...20) }
                Text("箭头、矩形和马赛克：在画面上拖动。文字：输入后单击放置。标注位置固定，不自动跟踪物体。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("标注出现时段（原录像秒数）").font(.callout.weight(.medium))
                HStack { numberField("开始", value: $controller.annotationStart); Text("至"); numberField("结束", value: $controller.annotationEnd) }
                Button("应用到选中标注") { controller.applyTiming() }.disabled(controller.selectedID == nil)
                Divider()
                HStack { Text("标注列表").font(.headline); Spacer(); Text("\(controller.annotations.count)").foregroundStyle(.secondary) }
                ForEach(controller.annotations) { item in
                    Button { controller.selectAnnotation(item.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.label).lineLimit(1)
                            Text("\(item.start, specifier: "%.1f") – \(item.end, specifier: "%.1f") 秒").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                            .background(controller.selectedID == item.id ? Color.teal.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                Button("删除选中标注", role: .destructive) { controller.removeSelected() }.disabled(controller.selectedID == nil)
            }.padding(18)
        }
    }

    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        EditorTimeInput(title: title, value: value)
    }
}

/// 播放统一由控制器驱动，避免系统播放器的第二套控制按钮绕过裁剪区间与绘图状态。
private struct VideoPlaybackView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsVideoFrameAnalysis = false
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

private struct VideoDrawingCanvas: NSViewRepresentable {
    @ObservedObject var controller: VideoEditorController
    func makeNSView(context: Context) -> VideoDrawingView { let view = VideoDrawingView(); view.controller = controller; return view }
    func updateNSView(_ view: VideoDrawingView, context: Context) { view.controller = controller; view.needsDisplay = true }
}

private final class VideoDrawingView: NSView {
    weak var controller: VideoEditorController?
    private var draft: Annotation?
    override var isFlipped: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let frame = controller.drawingFrame, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: bounds.width / CGFloat(frame.width), y: bounds.height / CGFloat(frame.height))
        AnnotationRenderer.draw(image: frame, annotations: draft.map { [$0] } ?? [], in: context)
        context.restoreGState()
    }
    private func point(_ event: NSEvent, controller: VideoEditorController) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: max(0, min(controller.size.width, point.x / bounds.width * controller.size.width)),
                       y: max(0, min(controller.size.height, point.y / bounds.height * controller.size.height)))
    }
    override func mouseDown(with event: NSEvent) {
        guard let controller, !controller.exporting, let tool = controller.tool else { return }
        let point = point(event, controller: controller)
        draft = Annotation(tool: tool, points: [point, point], color: controller.color, width: controller.lineWidth, text: controller.text, fontSize: controller.fontSize)
        if tool == .text {
            if !controller.text.isEmpty, let draft { controller.add(draft) } else { controller.message = "先输入文字，再点击画面放置" }
            draft = nil
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let controller, draft != nil else { return }
        draft?.points[1] = point(event, controller: controller); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        if let draft, let first = draft.points.first, let last = draft.points.last, hypot(last.x - first.x, last.y - first.y) > 3 { controller?.add(draft) }
        draft = nil; needsDisplay = true
    }
}
