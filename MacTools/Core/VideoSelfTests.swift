import AppKit
import AVFoundation
import CoreImage

/// 合成短片验证真实编码与解码链路；不会读取屏幕、麦克风、剪贴板或用户的录像目录。
@MainActor
enum VideoSelfTests {
    static func run() async {
        var passed = 0, failed = 0
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
        }
        do {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/VideoTestArtifacts", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // 只替换测试专用目录中的固定文件，不触碰用户输出或媒体索引。
            let raw = directory.appendingPathComponent("silent.mp4"), source = directory.appendingPathComponent("source.mp4")
            let output = directory.appendingPathComponent("edited.mp4"), audio = directory.appendingPathComponent("tone.wav")
            for url in [raw, source, output, audio] where FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try await makeVideo(at: raw)
            try makeTone(at: audio)
            try await addAudio(video: raw, audio: audio, output: source)
            let original = try Data(contentsOf: source)
            let asset = AVURLAsset(url: source)
            let rectangle = Annotation(tool: .rectangle, points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 70)], color: .green, width: 8, text: "", fontSize: 20)
            let mosaic = Annotation(tool: .mosaic, points: [CGPoint(x: 130, y: 20), CGPoint(x: 230, y: 90)], color: .red, width: 8, text: "", fontSize: 20)
            let items = [VideoAnnotation(annotation: rectangle, start: 1, end: 1.8), VideoAnnotation(annotation: mosaic, start: 1, end: 1.8)]
            let plans = try VideoRenderService.plans(for: items, size: CGSize(width: 240, height: 160))
            check(plans.allSatisfy { !$0.active(at: 0.99) && $0.active(at: 1) && !$0.active(at: 1.8) }, "标注时间包含起点且排除终点")
            let session = try await VideoRenderService.exportSession(asset: asset, plans: plans, start: 0.4, end: 2.4)
            try await session.export(to: output, as: .mp4)
            let edited = AVURLAsset(url: output)
            let duration = try await edited.load(.duration).seconds
            check(abs(duration - 2) < 0.06, "真实 MP4 裁剪后时长为 2 秒：\(duration)")
            let videos = try await edited.loadTracks(withMediaType: .video)
            let dimensions = try await videos.first?.load(.naturalSize)
            check(dimensions == CGSize(width: 240, height: 160), "导出保留原始视频尺寸")
            let audioTracks = try await edited.loadTracks(withMediaType: .audio)
            check(audioTracks.count == 1, "视频编辑导出保留原音轨")
            check(try Data(contentsOf: source) == original, "导出新文件且原始录像字节保持不变")

            let before = try await frame(output, at: 0.3)
            let visible = try await frame(output, at: 0.8)
            let after = try await frame(output, at: 1.6)
            check(!isGreen(pixel(before, x: 50, y: 20)), "裁剪后标注出现前没有提前显示")
            check(isGreen(pixel(visible, x: 50, y: 20)), "标注按原时间轴写入导出画面且方向正确")
            check(!isGreen(pixel(after, x: 50, y: 20)), "超过标注结束时间后自动消失")
            check(!isGreen(pixel(visible, x: 50, y: 140)), "上方标注没有上下翻转")

            let unedited = try await frame(source, at: 1.2)
            let difference = meanDifference(visible, unedited, rect: CGRect(x: 140, y: 30, width: 80, height: 50))
            let untouched = meanDifference(visible, unedited, rect: CGRect(x: 140, y: 110, width: 80, height: 30))
            check(difference > 20, "马赛克真实改变所选区域像素：\(Int(difference))")
            check(untouched < 15, "马赛克不影响选区外画面：\(Int(untouched))")
            let beforeSource = try await frame(source, at: 0.7)
            check(meanDifference(before, beforeSource, rect: CGRect(x: 140, y: 30, width: 80, height: 50)) < 15, "马赛克在时间范围外不生效")
            let second = try await frame(output, at: 1.1)
            check(meanDifference(visible, second, rect: CGRect(x: 140, y: 30, width: 80, height: 50)) > 3, "马赛克逐帧更新而非覆盖静态截图")

            // 独立检查四类工具生成的图层，补充主导出用例中的矩形与马赛克。
            let arrow = Annotation(tool: .arrow, points: [CGPoint(x: 20, y: 30), CGPoint(x: 100, y: 70)], color: .red, width: 6, text: "", fontSize: 20)
            let text = Annotation(tool: .text, points: [CGPoint(x: 20, y: 20)], color: .red, width: 6, text: "测试", fontSize: 24)
            for annotation in [arrow, text] {
                let raster = try VideoRenderService.plans(for: [VideoAnnotation(annotation: annotation, start: 0, end: 3)], size: CGSize(width: 240, height: 160))
                let base = CIImage(cgImage: unedited)
                let rendered = VideoRenderService.render(base, at: 1, plans: raster)
                let image = CIContext().createCGImage(rendered, from: rendered.extent)!
                check(meanDifference(image, unedited, rect: CGRect(x: 10, y: 10, width: 100, height: 70)) > 1, "视频\(annotation.tool.rawValue)图层实际渲染")
            }
            let draft = try LocalFiles.recordingDraftURL()
            try FileManager.default.copyItem(at: source, to: draft)
            let draftEditor = VideoEditorController(url: draft, temporary: true)
            await draftEditor.load()
            check(!draftEditor.loading && draftEditor.duration > 0, "临时录像可以进入预览")
            draftEditor.close(); draftEditor.close()
            check(!FileManager.default.fileExists(atPath: draft.path), "关闭预览删除未保存的临时录像，重复关闭安全")
            let existingEditor = VideoEditorController(url: source)
            await existingEditor.load(); existingEditor.close()
            check(try Data(contentsOf: source) == original, "关闭已有录像预览不删除或修改原文件")
            print("VIDEO ARTIFACTS \(directory.path)")
        } catch { check(false, "视频集成测试：\(error.localizedDescription)") }
        print("VIDEO RESULT \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    /// 生成逐帧变化的灰阶纹理，颜色与测试标注可区分，同时可检测马赛克是否误用静态帧。
    private static func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 240, AVVideoHeightKey: 160])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 240, kCVPixelBufferHeightKey as String: 160
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AppFailure.message("测试视频无法开始写入") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<60 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? AppFailure.message("测试视频编码失败") }
                try await Task.sleep(for: .milliseconds(5))
            }
            var optional: CVPixelBuffer?
            guard let pool = adapter.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional) == kCVReturnSuccess, let buffer = optional else {
                throw AppFailure.message("测试视频无法分配像素缓冲")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<160 {
                for x in 0..<240 {
                    let value = UInt8(((x / 3 + y / 3 + index / 6) % 2 == 0 ? 25 : 170) + index)
                    let offset = y * stride + x * 4
                    bytes[offset] = value; bytes[offset + 1] = value; bytes[offset + 2] = value; bytes[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adapter.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 20)) else {
                throw writer.error ?? AppFailure.message("测试视频无法追加帧")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? AppFailure.message("测试视频编码未完成") }
    }

    private static func makeTone(at url: URL) throws {
        let rate = 8000, sampleCount = 24000
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        data.append(Data("RIFF".utf8)); word(UInt32(36 + sampleCount * 2)); data.append(Data("WAVEfmt ".utf8))
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(rate)); word(UInt32(rate * 2)); word(UInt16(2)); word(UInt16(16))
        data.append(Data("data".utf8)); word(UInt32(sampleCount * 2))
        for index in 0..<sampleCount { word(Int16(sin(Double(index) * 2 * .pi * 440 / Double(rate)) * 4000)) }
        try data.write(to: url)
    }

    private static func addAudio(video: URL, audio: URL, output: URL) async throws {
        let composition = AVMutableComposition()
        for (url, type) in [(video, AVMediaType.video), (audio, AVMediaType.audio)] {
            let asset = AVURLAsset(url: url)
            let source = try await asset.loadTracks(withMediaType: type).first!
            let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)!
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        }
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        try await session.export(to: output, as: .mp4)
    }

    nonisolated private static func frame(_ url: URL, at time: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    private static func rgba(_ image: CGImage) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        result.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }
    private static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let values = rgba(image), index = (y * image.width + x) * 4
        return Array(values[index..<(index + 3)])
    }
    private static func isGreen(_ value: [UInt8]) -> Bool { Int(value[1]) > Int(value[0]) + 70 && Int(value[1]) > Int(value[2]) + 70 }
    private static func meanDifference(_ first: CGImage, _ second: CGImage, rect: CGRect) -> Double {
        let a = rgba(first), b = rgba(second)
        var difference = 0, count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                for channel in 0..<3 {
                    let offset = (y * first.width + x) * 4 + channel
                    difference += abs(Int(a[offset]) - Int(b[offset])); count += 1
                }
            }
        }
        return Double(difference) / Double(max(1, count))
    }
}
