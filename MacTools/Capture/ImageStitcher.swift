import CoreGraphics
import Foundation

/// 双向重叠匹配；正位移表示向下浏览，负位移表示向上浏览。
enum ImageStitcher {
    struct Match { var addedRows: Int; var error: Double }

    static func displacement(previous: CGImage, next: CGImage) throws -> Match {
        guard previous.width == next.width, previous.height == next.height else { throw AppFailure.message("截图尺寸发生变化，请重新框选") }
        let width = min(192, previous.width)
        let ratio = Double(width) / Double(previous.width)
        let height = max(24, Int(Double(previous.height) * ratio))
        let a = try grayscale(previous, width: width, height: height)
        let b = try grayscale(next, width: width, height: height)
        let stable = score(a, b, width: width, height: height, shift: 0)
        if stable < 0.5 { return Match(addedRows: 0, error: stable) }
        let limit = max(1, height * 4 / 5)
        let scores = (-limit...limit).filter { $0 != 0 }.map { shift in
            (shift, score(a, b, width: width, height: height, shift: shift))
        }.sorted { $0.1 < $1.1 }
        // 缩略图的重采样相位会影响文字边缘，不能在此用过严阈值提前否决正确位移。
        var candidates: [Int] = []
        for item in scores where candidates.allSatisfy({ abs($0 - item.0) > 3 }) {
            candidates.append(item.0)
            if candidates.count == 24 { break }
        }
        let fullA = try grayscale(previous, width: previous.width, height: previous.height)
        let fullB = try grayscale(next, width: next.width, height: next.height)
        let radius = max(2, Int(ceil(1 / ratio)))
        let fullLimit = previous.height * 4 / 5
        var refined: [Int: Double] = [:]
        for candidate in candidates {
            let estimate = Int((Double(candidate) / ratio).rounded())
            let lower = max(-fullLimit, estimate - radius), upper = min(fullLimit, estimate + radius)
            guard lower <= upper else { continue }
            for shift in lower...upper where shift != 0 && refined[shift] == nil {
                refined[shift] = score(fullA, fullB, width: previous.width, height: previous.height, shift: shift)
            }
        }
        let ordered = refined.sorted { $0.value < $1.value }
        let nativeStable = score(fullA, fullB, width: previous.width, height: previous.height, shift: 0)
        guard let best = ordered.first, best.value < 18, best.value < nativeStable * 0.85 else {
            throw AppFailure.message("暂未找到可靠重叠，请稍停滚动，或滚回最近成功的位置后重试")
        }
        if let alternate = ordered.first(where: { abs($0.key - best.key) > 3 }), alternate.value < best.value + 0.15 {
            throw AppFailure.message("画面重复过多，请选择包含更多正文细节的区域")
        }
        return Match(addedRows: best.key, error: best.value)
    }

    /// 同时裁掉两帧的固定边缘；按横向分区评分，舍弃误差最大的一区以容忍局部动画和光标。
    /// 纹理极少的区块不参与投票，避免大块空白把错误位移的分数拉到零。
    private static func score(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, shift: Int) -> Double {
        let margin = max(2, height / 16)
        let lower = max(margin, margin - shift), upper = min(height - margin, height - margin - shift)
        guard lower < upper else { return 255 }
        var totals = [Double](repeating: 0, count: 6)
        var signals = [Double](repeating: 0, count: 6)
        var counts = [Int](repeating: 0, count: 6)
        for y in stride(from: lower, to: upper, by: max(1, height / 150)) {
            for x in stride(from: max(1, width / 12), to: min(width - 1, width * 11 / 12), by: max(1, width / 100)) {
                let i = (y + shift) * width + x, j = y * width + x
                let band = min(5, x * 6 / width)
                totals[band] += Double(abs(Int(a[i]) - Int(b[j])))
                signals[band] += Double(abs(Int(a[i]) - Int(a[i - 1])) + abs(Int(b[j]) - Int(b[j - 1])))
                counts[band] += 1
            }
        }
        let values = (0..<6).compactMap { band -> Double? in
            guard counts[band] > 0, signals[band] / Double(counts[band]) > 0.5 else { return nil }
            return totals[band] / Double(counts[band])
        }.sorted()
        // 空白且完全一致可以静止，但不能据此证明一个非零滚动位移。
        guard !values.isEmpty else { return shift == 0 && a == b ? 0 : 255 }
        let usable = values.count >= 4 ? Array(values.dropLast()) : values
        return usable.reduce(0, +) / Double(usable.count)
    }

    /// 转为单通道灰度数组，索引为 y * width + x；只在缓冲区有效期间使用 CGContext 写入。
    static func grayscale(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let success = bytes.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(data: pointer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw AppFailure.message("没有足够内存处理长截图") }
        return bytes
    }

    /// pieces 必须按从上到下排列：首帧两端可插入新增条带；所有条带宽度应一致。
    static func assemble(_ pieces: [CGImage]) throws -> CGImage {
        guard let first = pieces.first else { throw AppFailure.message("尚未采集图片") }
        let height = pieces.reduce(0) { $0 + $1.height }
        guard height <= 50_000, Int64(first.width) * Int64(height) <= 100_000_000 else { throw AppFailure.message("长图已达到安全尺寸上限，请分段截图") }
        guard let context = CGContext(data: nil, width: first.width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppFailure.message("没有足够内存合成长图")
        }
        // 位图绘制坐标从左下开始，将第一段放在最上方，再依次向下摆放条带。
        var top = height
        for piece in pieces {
            top -= piece.height
            context.draw(piece, in: CGRect(x: 0, y: top, width: piece.width, height: piece.height))
        }
        guard let image = context.makeImage() else { throw AppFailure.message("长图合成失败") }
        return image
    }
}
