import AppKit
import Combine
import ScreenCaptureKit

/// 截图、OCR 与长截图的交互状态；采集交给 CaptureService，图像匹配交给 ImageStitcher。
@MainActor
final class CaptureController: ObservableObject {
    // 与 CaptureTargetView 的分段选择器保持一致：0 区域、1 全屏、2 窗口。
    @Published var mode = 0
    @Published var screenIndex = 0
    @Published var windowID: CGWindowID = 0
    @Published var windows: [SCWindow] = []
    @Published var exactSize = false
    @Published var width = "1280"
    @Published var height = "720"
    @Published var busy = false
    @Published var message = ""
    @Published var scrolling = false
    @Published var frameCount = 0
    @Published var totalHeight = 0
    @Published var recognizedText = ""
    private var scrollTask: Task<Void, Never>?
    // 首帧两端只保存超出已覆盖范围的新条带，避免反复合成越来越大的长图。
    private var pieces: [CGImage] = []
    // 始终指向最近一次成功接入的完整帧；匹配失败时不能更新，否则会丢失重试基准。
    private var previous: CGImage?
    private var target: CaptureTarget?
    private var sampling = false
    private var rejectedFrames = 0
    private var scrollExtent = ScrollExtent(frameHeight: 0)
    var onImage: ((CGImage) -> Void)?
    var onResult: (() -> Void)?
    private let feature: Feature
    private var presentationID: UUID?

    init(feature: Feature = .screenshot) {
        self.feature = feature
        let key = "capture.\(feature.rawValue)."
        let defaults = UserDefaults.standard
        mode = defaults.integer(forKey: key + "mode")
        screenIndex = defaults.integer(forKey: key + "screen")
        exactSize = defaults.bool(forKey: key + "exact")
        width = defaults.string(forKey: key + "width") ?? "1280"
        height = defaults.string(forKey: key + "height") ?? "720"
    }

    private func saveCaptureOptions() {
        let key = "capture.\(feature.rawValue)."
        let defaults = UserDefaults.standard
        defaults.set(mode, forKey: key + "mode"); defaults.set(screenIndex, forKey: key + "screen")
        defaults.set(exactSize, forKey: key + "exact"); defaults.set(width, forKey: key + "width"); defaults.set(height, forKey: key + "height")
    }

    func loadWindows() async {
        do {
            windows = try await CaptureService.content().windows.filter {
                $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 60 && $0.frame.height > 60
            }
            if !windows.contains(where: { $0.windowID == windowID }) { windowID = windows.first?.windowID ?? 0 }
        } catch { message = "无法读取窗口，请在系统设置中允许屏幕录制：\(error.localizedDescription)" }
    }

    /// 解析界面参数并等待必要的选区交互；nil 表示用户取消，抛错表示目标或参数不可用。
    func chooseTarget() async throws -> CaptureTarget? {
        // 窗口 ID 在应用重启或目标关闭后失效，回退到可悬停吸附的区域选择。
        if mode == 2 {
            let content = try await CaptureService.content()
            if !content.windows.contains(where: { $0.windowID == windowID }) { mode = 0 }
        }
        saveCaptureOptions()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw AppFailure.message("没有可用显示器") }
        if mode == 0 {
            var size: CGSize?
            if exactSize {
                guard let w = Int(width), let h = Int(height), w > 0, h > 0 else { throw AppFailure.message("请输入有效的像素宽高") }
                size = CGSize(width: w, height: h)
                guard screens.contains(where: { $0.frame.width * $0.backingScaleFactor >= CGFloat(w) && $0.frame.height * $0.backingScaleFactor >= CGFloat(h) }) else {
                    throw AppFailure.message("指定尺寸超过显示器可捕获的像素范围")
                }
            }
            return try await RegionSelector.shared.select(pixelSize: size)
        }
        // 显示器列表可能因拔插而缩短，避免沿用旧下标越界。
        let screen = screens[max(0, min(screenIndex, screens.count - 1))]
        if mode == 2 && windowID == 0 { throw AppFailure.message("请先刷新并选择窗口") }
        return CaptureTarget(displayID: CaptureService.displayID(screen), windowID: mode == 2 ? windowID : nil, scale: screen.backingScaleFactor)
    }

    func capture(ocr: Bool = false) async {
        guard SettingsStore.shared.isEnabled(feature), !busy else { return }
        busy = true; message = ""
        defer { busy = false }
        do {
            presentationID = try await CapturePresentation.shared.begin()
            guard let target = try await chooseTarget() else { finishPresentation(restore: true); return }
            let image = try await CaptureService.capture(target)
            finishPresentation(restore: false)
            if ocr {
                recognizedText = try await CaptureService.recognize(image)
                message = recognizedText.isEmpty ? "未识别到文字，请选择更清晰的区域" : "识别完成，可编辑后按 ⌘C 复制"
                onResult?()
            } else { onImage?(image) }
        } catch { finishPresentation(restore: true); message = error.localizedDescription; onResult?() }
    }

    /// 先采集基准帧，再串行轮询画面；滚动由用户在原应用中完成，不注入鼠标事件。
    func startScrolling() async {
        guard SettingsStore.shared.isEnabled(feature), !scrolling, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            presentationID = try await CapturePresentation.shared.begin()
            guard let selected = try await RegionSelector.shared.select() else { finishPresentation(restore: true); return }
            target = selected
            let first = try await CaptureService.capture(selected)
            previous = first; pieces = [first]; frameCount = 1; totalHeight = first.height
            scrollExtent = ScrollExtent(frameHeight: first.height)
            rejectedFrames = 0
            scrolling = true
            message = "可向上或向下滚动，已采集内容不会重复拼接，完成后点击「结束并编辑」。"
            let bounds = try await CaptureService.globalBounds(for: selected)
            CaptureOverlay.shared.show(rect: bounds, title: "长截图 · 支持上下滚动", actionTitle: "结束并编辑", action: { [weak self] in
                Task { await self?.finishScrolling() }
            }, cancel: { [weak self] in self?.cancelScrolling() })
            CapturePresentation.shared.restoreTargetApplication()
            scrollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self, self.scrolling else { break }
                    await self.sample()
                }
            }
        } catch {
            scrolling = false
            if presentationID != nil { CaptureOverlay.shared.hide(); finishPresentation(restore: true) }
            message = error.localizedDescription; onResult?()
        }
    }

    /// 每次采样只有匹配成功且会话仍有效时才能追加，避免异步计算结束后写入已取消的会话。
    private func sample() async {
        guard !sampling, let target, let previous, let session = presentationID else { return }
        sampling = true
        defer { sampling = false }
        do {
            let next = try await CaptureService.capture(target)
            // 像素比较属于 CPU 密集任务，在后台执行；返回后再由主线程更新可观察状态。
            let match = try await Task.detached(priority: .userInitiated) { try ImageStitcher.displacement(previous: previous, next: next) }.value
            guard scrolling, presentationID == session else { return }
            if match.addedRows == 0 { rejectedFrames = 0; return }
            var extent = scrollExtent
            let growth = extent.move(by: match.addedRows)
            let newHeight = extent.height
            // 同时限制高度和总像素，防止极长或极宽的结果耗尽合成画布内存。
            guard newHeight <= 50_000, Int64(newHeight) * Int64(next.width) <= 100_000_000 else {
                message = "已到长图尺寸上限，请结束并编辑。"
                CaptureOverlay.shared.update(title: "已到尺寸上限，请结束并编辑")
                scrollTask?.cancel()
                return
            }
            // 新内容只在已覆盖范围之外追加：向上放到头部，向下放到尾部。
            let head = growth.prepend > 0 ? next.cropping(to: CGRect(x: 0, y: 0, width: next.width, height: growth.prepend)) : nil
            let tail = growth.append > 0 ? next.cropping(to: CGRect(x: 0, y: next.height - growth.append, width: next.width, height: growth.append)) : nil
            guard (growth.prepend == 0 || head != nil), (growth.append == 0 || tail != nil) else { throw AppFailure.message("无法读取新增图像，请稍停滚动后重试") }
            if let head { pieces.insert(head, at: 0); frameCount += 1 }
            if let tail { pieces.append(tail); frameCount += 1 }
            scrollExtent = extent; self.previous = next; totalHeight = newHeight
            rejectedFrames = 0
            message = "已拼接 \(frameCount) 段 · \(totalHeight) px，可继续上下滚动。"
            CaptureOverlay.shared.update(title: "\(frameCount) 段 · \(totalHeight) px")
        } catch {
            guard presentationID == session else { return }
            rejectedFrames += 1
            // 连续失败再提示，减少滚动动画造成的短暂不匹配对用户的干扰。
            if rejectedFrames >= 3 {
                message = error.localizedDescription + " 未匹配的画面未加入，请回滚至上一段附近重试。"
                CaptureOverlay.shared.update(title: "匹配失败，请回滚后慢速重试")
            }
        }
    }

    /// 结束后仍允许当前正在处理的一帧完成，再合成长图，避免与清空图片数组发生竞争。
    func finishScrolling() async {
        guard scrolling, !busy else { return }
        busy = true
        scrollTask?.cancel()
        // cancel 只发出取消信号；等待任务真正返回后，才改变会话状态并合成已有条带。
        if let scrollTask { await scrollTask.value }
        scrolling = false
        CaptureOverlay.shared.hide()
        finishPresentation(restore: false)
        defer { busy = false; pieces = []; previous = nil }
        do { onImage?(try ImageStitcher.assemble(pieces)) }
        catch { message = error.localizedDescription; onResult?() }
    }

    func cancelScrolling() {
        guard scrolling || presentationID != nil else { return }
        scrolling = false; scrollTask?.cancel(); pieces = []; previous = nil; message = "已取消"
        CaptureOverlay.shared.hide(); finishPresentation(restore: true)
    }

    private func finishPresentation(restore: Bool) {
        CapturePresentation.shared.end(presentationID, restoreWindows: restore)
        presentationID = nil
    }
    func savePreset() {
        guard let w = Int(width), let h = Int(height), w > 0, h > 0 else { message = "请输入有效尺寸"; return }
        let value = "\(w) × \(h)"
        if !SettingsStore.shared.presets.contains(value) { SettingsStore.shared.presets.append(value) }
    }
}
