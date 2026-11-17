import AppKit
import AVFoundation
import Combine
import CoreImage

/// 录像预览、时间裁剪和定时标注的状态入口；显式导出新文件，关闭时只丢弃本次临时草稿。
@MainActor
final class VideoEditorController: ObservableObject {
    let url: URL
    let temporary: Bool
    let player = AVPlayer()
    @Published var duration = 0.0
    @Published var currentTime = 0.0
    @Published var trimStart = 0.0
    @Published var trimEnd = 0.0
    @Published var size = CGSize(width: 16, height: 9)
    @Published var loading = true
    @Published var playing = false
    @Published var exporting = false
    @Published var exportProgress = 0.0
    @Published var message = ""
    @Published var annotations: [VideoAnnotation] = []
    @Published var selectedID: UUID?
    @Published var tool: AnnotationTool?
    @Published var color = NSColor.systemRed
    @Published var lineWidth: CGFloat = 6
    @Published var text = ""
    @Published var fontSize: CGFloat = 36
    @Published var annotationStart = 0.0
    @Published var annotationEnd = 0.0
    @Published var lastExport: URL?
    @Published var savedOriginal: URL?
    @Published var drawingFrame: CGImage?
    private var asset: AVURLAsset?
    private var timeObserver: Any?
    private var previewTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var exportSession: AVAssetExportSession?
    private var previewVersion = UUID()
    private var undoStack: [[VideoAnnotation]] = []
    private var redoStack: [[VideoAnnotation]] = []
    private var seeking = false
    private var closed = false
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var selected: VideoAnnotation? { annotations.first { $0.id == selectedID } }

    init(url: URL, temporary: Bool = false) { self.url = url; self.temporary = temporary }

    func load() async {
        guard asset == nil, !closed else { return }
        message = "正在读取视频…"
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw AppFailure.message("录像没有可播放的视频轨道")
            }
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: natural).applying(transform)
            guard !closed else { return }
            self.size = CGSize(width: abs(bounds.width), height: abs(bounds.height))
            self.asset = asset; self.duration = duration; trimEnd = duration; annotationEnd = duration
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
                let seconds = time.seconds
                Task { @MainActor in
                    guard let self, !self.seeking, seconds.isFinite else { return }
                    self.currentTime = seconds
                    if seconds >= self.trimEnd && self.playing { self.pause() }
                }
            }
            loading = false
            message = temporary ? "这是临时录像，点击保存或导出才会保留；关闭窗口会丢弃。" : "拖动时间轴预览；标注时间相对于原录像。"
        } catch { loading = false; message = error.localizedDescription }
    }

    func pause() { player.pause(); playing = false }
    func togglePlayback() {
        if playing { pause(); return }
        tool = nil; drawingFrame = nil
        if currentTime < trimStart || currentTime >= trimEnd { seek(to: trimStart) }
        player.play(); playing = true
    }
    func seek(to seconds: Double) {
        let value = max(0, min(duration, seconds))
        currentTime = value; seeking = true
        player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.seeking = false }
        }
        if tool != nil { Task { await refreshDrawingFrame() } }
    }

    func selectTool(_ value: AnnotationTool?) {
        pause(); tool = value
        // 播放到末尾后开始标注时回到裁剪起点，保证新标注立即处在可见时间范围。
        if value != nil && (currentTime < trimStart || currentTime >= trimEnd) { seek(to: trimStart) }
        annotationStart = max(trimStart, min(currentTime, max(trimStart, trimEnd - 0.1)))
        annotationEnd = trimEnd
        if value != nil { Task { await refreshDrawingFrame() } } else { drawingFrame = nil }
    }

    private func refreshDrawingFrame() async {
        guard let asset, tool != nil else { return }
        let requestedTime = currentTime
        do {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: CMTime(seconds: min(requestedTime, max(0, duration - 0.04)), preferredTimescale: 600)).image
            guard tool != nil, abs(currentTime - requestedTime) < 0.15 else { return }
            let plans = try VideoRenderService.plans(for: annotations, size: size)
            let rendered = VideoRenderService.render(CIImage(cgImage: frame), at: requestedTime, plans: plans)
            drawingFrame = CIContext().createCGImage(rendered, from: rendered.extent)
        } catch { message = "无法提取当前帧：\(error.localizedDescription)" }
    }

    func add(_ annotation: Annotation) {
        guard VideoTimeline.validRange(start: annotationStart, end: annotationEnd, duration: duration) else {
            message = "请输入有效的标注起止时间"; return
        }
        rememberUndo()
        let item = VideoAnnotation(annotation: annotation, start: annotationStart, end: annotationEnd)
        annotations.append(item); selectedID = item.id
        rebuildPreview()
    }

    func selectAnnotation(_ id: UUID?) {
        selectedID = id
        if let selected { annotationStart = selected.start; annotationEnd = selected.end }
    }

    func applyTiming() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard let index = annotations.firstIndex(where: { $0.id == selectedID }),
              VideoTimeline.validRange(start: annotationStart, end: annotationEnd, duration: duration) else {
            message = "选择标注并填写有效时间"; return
        }
        rememberUndo(); annotations[index].start = annotationStart; annotations[index].end = annotationEnd
        rebuildPreview()
    }

    func removeSelected() {
        guard selectedID != nil else { return }
        rememberUndo(); annotations.removeAll { $0.id == selectedID }; selectedID = nil; rebuildPreview()
    }
    private func rememberUndo() { undoStack.append(annotations); redoStack = [] }
    func undo() { if let previous = undoStack.popLast() { redoStack.append(annotations); annotations = previous; selectedID = nil; rebuildPreview() } }
    func redo() { if let next = redoStack.popLast() { undoStack.append(annotations); annotations = next; selectedID = nil; rebuildPreview() } }

    private func rebuildPreview() {
        pause()
        previewTask?.cancel()
        previewVersion = UUID()
        let version = previewVersion
        guard let asset else { return }
        previewTask = Task {
            do {
                let plans = try VideoRenderService.plans(for: annotations, size: size)
                let composition = try await VideoRenderService.composition(asset: asset, plans: plans)
                guard !Task.isCancelled, version == previewVersion else { return }
                player.currentItem?.videoComposition = composition
                seek(to: currentTime)
                await refreshDrawingFrame()
                message = "标注预览已更新，导出时将写入视频画面。"
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }

    func export() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard !exporting, !closed, let asset else { return }
        guard VideoTimeline.validRange(start: trimStart, end: trimEnd, duration: duration) else { message = "裁剪结束时间必须大于开始时间，且位于视频时长内"; return }
        pause(); exporting = true; exportProgress = 0; message = "正在导出新视频…"
        // 固定当前编辑快照，导出期间禁用编辑，防止用户以为新改动已写入正在输出的文件。
        let snapshot = annotations, size = size, start = trimStart, end = trimEnd
        exportTask = Task {
            var outputURL: URL?
            var progressTask: Task<Void, Never>?
            defer { progressTask?.cancel(); exportSession = nil; exporting = false; exportTask = nil }
            do {
                let plans = try VideoRenderService.plans(for: snapshot, size: size)
                let session = try await VideoRenderService.exportSession(asset: asset, plans: plans, start: start, end: end)
                try Task.checkCancellation()
                exportSession = session
                let destination = try LocalFiles.outputURL(directory: SettingsStore.shared.recordingDirectory, prefix: "录屏-已编辑", ext: "mp4")
                outputURL = destination
                progressTask = Task {
                    for await state in session.states(updateInterval: 0.2) {
                        if case .exporting(let progress) = state { self.exportProgress = progress.fractionCompleted }
                    }
                }
                try await session.export(to: destination, as: .mp4)
                // 关闭窗口可能恰好发生在导出完成时，仍需检查取消，避免留下未确认的文件。
                try Task.checkCancellation()
                lastExport = destination; exportProgress = 1
                MediaLibrary.shared.register(destination, kind: .recording)
                RecordingController.shared.lastURL = destination
                message = "已导出：\(destination.lastPathComponent)"
            } catch {
                if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
                message = Task.isCancelled ? "已取消导出" : "导出失败：\(error.localizedDescription)"
            }
        }
    }

    /// 保存原片是显式操作；复制而非移动，使本次编辑仍能读取自己的临时源文件。
    func saveOriginal() {
        guard temporary, savedOriginal == nil, !loading, !exporting, !closed else { return }
        do {
            let destination = try LocalFiles.outputURL(directory: SettingsStore.shared.recordingDirectory, prefix: "录屏", ext: "mp4")
            try FileManager.default.copyItem(at: url, to: destination)
            savedOriginal = destination
            MediaLibrary.shared.register(destination, kind: .recording)
            RecordingController.shared.lastURL = destination
            message = "原录像已保存：\(destination.lastPathComponent)"
        } catch { message = "保存失败：\(error.localizedDescription)" }
    }

    func cancelExport() { exportTask?.cancel(); exportSession?.cancelExport() }
    func close() {
        guard !closed else { return }
        closed = true
        pause(); previewTask?.cancel(); cancelExport()
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        player.replaceCurrentItem(with: nil)
        asset = nil
        // 只删除明确由本次录制移交的草稿；打开已有视频时绝不删除源文件。
        if temporary { try? FileManager.default.removeItem(at: url) }
    }
}
