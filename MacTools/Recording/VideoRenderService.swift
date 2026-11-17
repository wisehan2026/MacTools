import AppKit
import AVFoundation
import CoreImage

/// 标注时间使用原录像时间轴，裁剪不会改变用户填写的起止时间。
struct VideoAnnotation: Identifiable {
    var id = UUID()
    var annotation: Annotation
    var start: Double
    var end: Double
    var label: String { annotation.tool == .text ? "文字：\(annotation.text)" : annotation.tool.rawValue }
}

/// 后台逐帧处理只读取不可变像素和数值，不访问 NSColor、SwiftUI 或可观察控制器。
struct VideoOverlayPlan: Sendable {
    var start: Double
    var end: Double
    var image: CGImage?
    var mosaicRect: CGRect?
    var blockSize: Double
    func active(at seconds: Double) -> Bool { seconds >= start && seconds < end }
}

enum VideoTimeline {
    static func validRange(start: Double, end: Double, duration: Double) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end <= duration + 0.001 && end - start >= 0.05
    }
}

enum VideoRenderService {
    @MainActor
    static func plans(for annotations: [VideoAnnotation], size: CGSize) throws -> [VideoOverlayPlan] {
        guard size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let transparent = context.makeImage() else { throw AppFailure.message("无法创建视频标注画布") }
        return try annotations.map { item in
            if item.annotation.tool == .mosaic {
                let rect = item.annotation.bounds.intersection(CGRect(origin: .zero, size: size))
                let coreImageRect = CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
                return VideoOverlayPlan(start: item.start, end: item.end, mosaicRect: coreImageRect, blockSize: max(8, item.annotation.width * 3))
            }
            let document = AnnotationDocument(image: transparent)
            document.annotations = [item.annotation]
            return VideoOverlayPlan(start: item.start, end: item.end, image: try document.rendered(), blockSize: 0)
        }
    }

    /// 预览和导出共享同一逐帧处理器；马赛克取当前视频帧，避免把某张静态截图贴到动态视频上。
    static func render(_ source: CIImage, at seconds: Double, plans: [VideoOverlayPlan]) -> CIImage {
        let extent = source.extent
        var result = source
        for plan in plans where plan.active(at: seconds) {
            if let rect = plan.mosaicRect, !rect.isEmpty, !rect.isNull {
                let region = rect.offsetBy(dx: extent.minX, dy: extent.minY).intersection(extent)
                let pixelated = result.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: plan.blockSize]).cropped(to: region)
                result = pixelated.composited(over: result)
            } else if let image = plan.image {
                let overlay = CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
                result = overlay.composited(over: result)
            }
        }
        return result.cropped(to: extent)
    }

    static func composition(asset: AVAsset, plans: [VideoOverlayPlan]) async throws -> AVVideoComposition {
        try await AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
            let image = render(request.sourceImage, at: request.compositionTime.seconds, plans: plans)
            request.finish(with: image, context: nil)
        })
    }

    /// 从原资产导出可以保留音轨；timeRange 只限制输出区间，不改写标注使用的原始时间轴。
    static func exportSession(asset: AVAsset, plans: [VideoOverlayPlan], start: Double, end: Double) async throws -> AVAssetExportSession {
        let composition = try await composition(asset: asset, plans: plans)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw AppFailure.message("无法创建视频导出器")
        }
        session.videoComposition = composition
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: end - start, preferredTimescale: 600))
        return session
    }
}
