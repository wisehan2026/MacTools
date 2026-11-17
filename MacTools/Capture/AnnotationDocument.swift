import AppKit
import Combine

enum AnnotationTool: String, CaseIterable, Identifiable {
    case arrow = "箭头", text = "文字", rectangle = "矩形", ellipse = "椭圆", pen = "画笔", mosaic = "马赛克"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .pen: "pencil.tip"
        case .mosaic: "square.grid.3x3.fill"
        }
    }
}

/// 一次可撤销的标注操作；坐标以原图左上角为原点，单位为像素，与画布显示倍率无关。
struct Annotation {
    var tool: AnnotationTool
    // 画笔保存轨迹点；形状和箭头使用首尾点；文字使用第一个点作为放置位置。
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text: String
    var fontSize: CGFloat
    var bounds: CGRect {
        guard let start = points.first, let end = points.last else { return .zero }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

/// 保存不可变原图与可撤销的标注列表；界面预览和最终导出使用同一套渲染逻辑。
@MainActor
final class AnnotationDocument: ObservableObject {
    let image: CGImage
    @Published var annotations: [Annotation] = []
    @Published var redoStack: [Annotation] = []
    @Published var tool: AnnotationTool = .arrow
    @Published var color: NSColor = .systemRed
    @Published var lineWidth: CGFloat = 5
    @Published var text = ""
    @Published var fontSize: CGFloat = 32
    @Published var zoom: CGFloat = 0.5
    @Published var message = ""
    init(image: CGImage) { self.image = image; zoom = min(1, 760 / CGFloat(image.width)) }
    // 新操作会形成新的编辑分支，之前撤销的操作不再允许重做。
    func add(_ annotation: Annotation) { annotations.append(annotation); redoStack = [] }
    func undo() { if let last = annotations.popLast() { redoStack.append(last) } }
    func redo() { if let last = redoStack.popLast() { annotations.append(last) } }

    /// 以原始像素尺寸导出，zoom 只影响屏幕预览，不参与最终图片分辨率计算。
    func rendered() throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppFailure.message("图片过大，无法创建编辑画布")
        }
        // 位图上下文默认原点在左下，翻转成与 DrawingView 一致的左上原点后再渲染。
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        AnnotationRenderer.draw(image: image, annotations: annotations, in: context)
        guard let result = context.makeImage() else { throw AppFailure.message("无法生成编辑后的图片") }
        return result
    }

    /// 单次渲染可用于复制、保存或两者同时执行；文件成功写入后才登记到空间管理索引。
    func export(copy: Bool, save: Bool) {
        do {
            let result = try rendered()
            var path: String?
            if save {
                let url = try LocalFiles.outputURL(directory: SettingsStore.shared.screenshotDirectory, prefix: "截图", ext: "png")
                try LocalFiles.png(result).write(to: url, options: .atomic)
                MediaLibrary.shared.register(url, kind: .screenshot)
                path = url.path
            }
            if copy {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([NSImage(cgImage: result, size: .zero)])
            }
            message = path.map { "已保存至 \($0)" } ?? "已复制，按 ⌘V 粘贴"
        } catch { message = error.localizedDescription }
    }
}

/// 调用方需提供左上原点的上下文；依次绘制原图与标注，使预览和导出顺序一致。
@MainActor
enum AnnotationRenderer {
    static func draw(image: CGImage, annotations: [Annotation], in context: CGContext) {
        let size = CGSize(width: image.width, height: image.height)
        drawImage(image, rect: CGRect(origin: .zero, size: size), context: context)
        for item in annotations {
            guard let first = item.points.first, let last = item.points.last else { continue }
            // 每条标注隔离画笔、颜色和插值设置，避免马赛克等操作影响后续标注。
            context.saveGState()
            context.setStrokeColor(item.color.cgColor)
            context.setFillColor(item.color.cgColor)
            context.setLineWidth(item.width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            switch item.tool {
            case .rectangle: context.stroke(item.bounds)
            case .ellipse: context.strokeEllipse(in: item.bounds)
            case .pen:
                context.addLines(between: item.points); context.strokePath()
            case .arrow:
                context.move(to: first); context.addLine(to: last); context.strokePath()
                let angle = atan2(last.y - first.y, last.x - first.x)
                let length = max(15, item.width * 4)
                context.move(to: CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)))
                context.addLine(to: last)
                context.addLine(to: CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6)))
                context.strokePath()
            case .text:
                // NSAttributedString 使用 AppKit 绘制，需临时绑定同一个已翻转的 CGContext。
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: item.fontSize, weight: .medium), .foregroundColor: item.color]
                NSAttributedString(string: item.text, attributes: attributes).draw(at: first)
                NSGraphicsContext.restoreGraphicsState()
            case .mosaic:
                // 从原图取出选区，先缩小再无插值放大，生成真正写入导出结果的像素块。
                // 取样源是原图，不包含此前绘制的标注；该块按当前标注顺序覆盖画布。
                let rect = item.bounds.integral.intersection(CGRect(origin: .zero, size: size))
                if rect.width > 0, rect.height > 0, let crop = image.cropping(to: rect) {
                    let block = max(8, Int(item.width * 3))
                    let w = max(1, crop.width / block), h = max(1, crop.height / block)
                    if let small = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        small.interpolationQuality = .low
                        small.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
                        if let pixelated = small.makeImage() { context.interpolationQuality = .none; drawImage(pixelated, rect: rect, context: context) }
                    }
                }
            }
            context.restoreGState()
        }
    }

    /// 图像绘制时局部翻转 Y 轴，抵消外层左上坐标系，避免 CGImage 在画布中上下颠倒。
    private static func drawImage(_ image: CGImage, rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}
