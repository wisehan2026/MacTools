import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

/// 管理从权限检查、选区、倒计时到写入完成的录屏生命周期，独立于控制窗口存活。
/// busy 表示准备或收尾中，isRecording 在输出代理确认开始后置为 true；phase 仅用于显示提示。
@MainActor
final class RecordingController: NSObject, ObservableObject, SCRecordingOutputDelegate, SCStreamDelegate {
    static let shared = RecordingController()
    let capture = CaptureController(feature: .recording)
    @Published var systemAudio = false
    @Published var microphone = false
    @Published var fps = 30
    @Published var countdown = 3
    @Published var phase = ""
    @Published var isRecording = false
    @Published var busy = false
    @Published var startedAt: Date?
    @Published var lastURL: URL?
    @Published var message = ""
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    // 录制输出先存临时文件；预览中的保存或导出操作才登记媒体索引和 lastURL。
    private var pendingURL: URL?
    private var presentationID: UUID?
    private var cancelledStart = false
    private var statusTimer: Timer?

    /// 防止重复启动；仅在启用麦克风时申请其权限，再建立系统采集流与 MP4 输出。
    func start() async {
        guard SettingsStore.shared.isEnabled(.recording), !isRecording, !busy else { return }
        busy = true; message = ""; cancelledStart = false
        do {
            presentationID = try await CapturePresentation.shared.begin()
            if microphone {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard allowed else { throw AppFailure.message("请在系统设置中允许 MacTools 使用麦克风") }
            }
            guard let target = try await capture.chooseTarget() else { busy = false; finishPresentation(restore: true); return }
            let content = try await CaptureService.content()
            let (filter, config) = try CaptureService.configuration(target: target, content: content, cursor: true)
            // H.264 使用偶数尺寸，避免编码器拒绝奇数宽高。
            config.width = max(2, config.width / 2 * 2)
            config.height = max(2, config.height / 2 * 2)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.capturesAudio = systemAudio
            config.excludesCurrentProcessAudio = true
            config.captureMicrophone = microphone
            let url = try LocalFiles.recordingDraftURL()
            let recordingConfig = SCRecordingOutputConfiguration()
            recordingConfig.outputURL = url
            recordingConfig.outputFileType = .mp4
            recordingConfig.videoCodecType = .h264
            let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            // 启动采集前接入录制输出，确保输出器从首批样本开始接收视频和所选音频。
            try stream.addRecordingOutput(output)
            self.stream = stream; self.output = output; pendingURL = url
            let bounds = try await CaptureService.globalBounds(for: target)
            CaptureOverlay.shared.show(rect: bounds, title: "准备录制", actionTitle: "停止并编辑", action: { [weak self] in
                Task { await self?.stop() }
            }, cancel: { [weak self] in self?.cancelledStart = true }, enabled: false)
            CapturePresentation.shared.restoreTargetApplication()
            if countdown > 0 {
                for value in stride(from: countdown, through: 1, by: -1) {
                    phase = "\(value) 秒后开始"
                    CaptureOverlay.shared.update(title: phase)
                    try await Task.sleep(for: .seconds(1))
                    if cancelledStart { throw CancellationError() }
                }
            }
            phase = "正在开始录制…"
            if cancelledStart { throw CancellationError() }
            // 调用返回后仍由输出代理确认真实开始时间，倒计时不计入录像时长。
            try await stream.startCapture()
        } catch {
            let draft = pendingURL
            let activeStream = stream
            stream = nil; output = nil; pendingURL = nil
            try? await activeStream?.stopCapture()
            if let draft { try? FileManager.default.removeItem(at: draft) }
            if presentationID != nil { CaptureOverlay.shared.hide(); finishPresentation(restore: true) }
            busy = false; phase = ""; message = error is CancellationError ? "已取消录制" : error.localizedDescription
            if !(error is CancellationError) { WindowCoordinator.shared.show(.recording) }
        }
    }

    /// 停止采集后保持收尾状态；由输出代理确认临时 MP4 已完成，随后才打开预览。
    func stop() async {
        guard let stream, isRecording, !busy else { return }
        busy = true; phase = "正在完成文件…"
        CaptureOverlay.shared.update(title: phase, actionEnabled: false)
        do { try await stream.stopCapture() }
        catch { await fail(error.localizedDescription) }
    }

    // 系统代理回调不假定执行线程，所有可观察状态更新显式切回 MainActor。
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let id = ObjectIdentifier(recordingOutput)
        Task { @MainActor [self] in
            guard self.output.map(ObjectIdentifier.init) == id else { return }
            self.isRecording = true; self.busy = false; self.startedAt = Date(); self.phase = "正在录制"
            CaptureOverlay.shared.update(title: "正在录制 · 00:00", actionEnabled: true)
            CaptureOverlay.shared.disableCancel()
            self.statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRecording, !self.busy, let start = self.startedAt else { return }
                    let seconds = Int(Date().timeIntervalSince(start))
                    CaptureOverlay.shared.update(title: String(format: "正在录制 · %02d:%02d", seconds / 60, seconds % 60))
                }
            }
        }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let id = ObjectIdentifier(recordingOutput)
        Task { @MainActor in
            guard self.output.map(ObjectIdentifier.init) == id else { return }
            let finishedURL = self.pendingURL
            self.message = "录制完成，请在预览中保存或导出；直接关闭会丢弃临时录像。"
            self.isRecording = false; self.busy = false; self.phase = ""
            self.stream = nil; self.output = nil; self.pendingURL = nil
            self.statusTimer?.invalidate(); self.statusTimer = nil
            CaptureOverlay.shared.hide()
            self.finishPresentation(restore: false)
            if let finishedURL { WindowCoordinator.shared.editVideo(finishedURL, temporary: true) }
        }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let description = error.localizedDescription
        let id = ObjectIdentifier(recordingOutput)
        Task { @MainActor in if self.output.map(ObjectIdentifier.init) == id { await self.fail(description) } }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let description = error.localizedDescription
        let id = ObjectIdentifier(stream)
        Task { @MainActor in if self.stream.map(ObjectIdentifier.init) == id { await self.fail(description) } }
    }
    /// 采集流和文件输出都可能报错，集中回收状态；先解除流引用，再等待其停止。
    private func fail(_ description: String) async {
        let activeStream = stream
        let draft = pendingURL
        stream = nil; output = nil; pendingURL = nil
        try? await activeStream?.stopCapture()
        if let draft { try? FileManager.default.removeItem(at: draft) }
        output = nil; pendingURL = nil; isRecording = false; busy = false; phase = ""
        message = "录制中断：\(description)"
        statusTimer?.invalidate(); statusTimer = nil
        CaptureOverlay.shared.hide(); finishPresentation(restore: true)
        WindowCoordinator.shared.show(.recording)
    }

    private func finishPresentation(restore: Bool) {
        CapturePresentation.shared.end(presentationID, restoreWindows: restore)
        presentationID = nil
    }
}
