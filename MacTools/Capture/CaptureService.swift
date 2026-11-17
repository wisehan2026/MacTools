import AppKit
import ScreenCaptureKit
import Vision

/// 统一表示区域、全屏和窗口采集目标；窗口 ID 有值时优先走窗口捕获分支。
struct CaptureTarget {
    var displayID: CGDirectDisplayID
    /// 相对目标显示器左上角的选区，单位为逻辑点；nil 表示整个显示器。
    var rect: CGRect?
    var windowID: CGWindowID?
    /// 显示器逻辑点到物理像素的倍率；窗口捕获则读取系统过滤器提供的倍率。
    var scale: CGFloat
}

/// 封装系统采集和 OCR 能力，供截图、长截图与录屏共用，不持有具体窗口状态。
@MainActor
enum CaptureService {
    static func globalBounds(for target: CaptureTarget) async throws -> CGRect {
        if let id = target.windowID {
            guard let window = try await content().windows.first(where: { $0.windowID == id }) else { throw AppFailure.message("所选窗口已关闭") }
            return CaptureGeometry.appKitRect(fromQuartz: window.frame, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
        }
        guard let screen = NSScreen.screens.first(where: { displayID($0) == target.displayID }) else { throw AppFailure.message("所选显示器已断开") }
        return target.rect.map { CaptureGeometry.globalRect(sourceRect: $0, screenFrame: screen.frame) } ?? screen.frame
    }

    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }

    /// 同时生成「捕获什么」的过滤器与「如何输出」的配置，统一各入口的坐标和分辨率规则。
    static func configuration(target: CaptureTarget, content: SCShareableContent, cursor: Bool = false) throws -> (SCContentFilter, SCStreamConfiguration) {
        let config = SCStreamConfiguration()
        config.showsCursor = cursor
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        let filter: SCContentFilter
        if let id = target.windowID {
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw AppFailure.message("所选窗口已关闭，请重新选择") }
            filter = SCContentFilter(desktopIndependentWindow: window)
            // 窗口可能位于不同缩放倍率的屏幕上，以过滤器提供的窗口像素倍率为准。
            config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        } else {
            guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else { throw AppFailure.message("所选显示器已断开") }
            // 排除本应用窗口，避免把选区遮罩、工具栏或录制控制窗口采进结果。
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let rect = target.rect ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
            // sourceRect 使用逻辑点；输出宽高使用像素，两者不能直接混用。
            config.sourceRect = rect
            config.width = max(1, Int((rect.width * target.scale).rounded()))
            config.height = max(1, Int((rect.height * target.scale).rounded()))
        }
        return (filter, config)
    }

    static func capture(_ target: CaptureTarget) async throws -> CGImage {
        let content = try await content()
        let (filter, config) = try configuration(target: target, content: content)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Vision 的同步识别放到后台执行；只传入图像并返回文字，不在后台操作界面状态。
    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}
