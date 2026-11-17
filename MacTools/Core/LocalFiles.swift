import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 集中管理应用私有目录、按日导出命名和图片编码，业务层不各自拼装存储规则。
enum LocalFiles {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacTools", isDirectory: true)
    }
    static var clipboard: URL { root.appendingPathComponent("Clipboard", isDirectory: true) }
    static var localMemes: URL { root.appendingPathComponent("LocalMemes", isDirectory: true) }
    static var cache: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacTools", isDirectory: true) }
    static func ensure(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    /// 未确认保存的录像放在系统临时目录；预览窗口拥有文件，关闭后负责删除。
    static func recordingDraftURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-RecordingDrafts", isDirectory: true)
        try ensure(directory)
        return directory.appendingPathComponent("录像草稿-\(UUID().uuidString).mp4")
    }
    /// 使用当前时区生成日期目录；固定格式，避免系统语言影响目录名称。
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    /// 创建当天目录，文件名附加随机后缀，降低短时间内多次导出时的重名概率。
    static func outputURL(directory: String, prefix: String, ext: String) throws -> URL {
        let folder = URL(fileURLWithPath: directory).appendingPathComponent(day(Date()), isDirectory: true)
        try ensure(folder)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH-mm-ss-SSS"
        return folder.appendingPathComponent("\(prefix)-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).\(ext)")
    }
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw AppFailure.message("无法创建图片编码器")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppFailure.message("图片编码失败") }
        return data as Data
    }
    static func image(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    /// 递归统计普通文件的逻辑字节数，不等同于文件系统实际分配的磁盘块大小。
    static func size(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) else { return 0 }
        return enumerator.compactMap { $0 as? URL }.reduce(0) { total, file in
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return total + (values?.isRegularFile == true ? Int64(values?.fileSize ?? 0) : 0)
        }
    }
}

// 清理规则独立于界面，便于测试自然日、收藏和容量边界。
enum ClipboardPolicy {
    /// 不读写磁盘的清理规则：先按自然日过滤，再按容量从旧到新淘汰非收藏记录。
    /// - Parameters:
    ///   - days: 包含今天的保留天数；3 天表示今天及前两天，而非最近 72 小时。
    ///   - capacity: 内容字节上限，不包含 JSON 索引和文件系统开销。
    ///   - now: 判断过期的基准时间，可由测试注入。
    ///   - calendar: 决定自然日边界与时区，可由测试固定。
    /// - Returns: 按最近复制时间倒序排列的记录；收藏单独超限时也不会被此方法删除。
    static func retained(_ entries: [ClipboardEntry], days: Int, capacity: Int64, now: Date = Date(), calendar: Calendar = .current) -> [ClipboardEntry] {
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
        var result = entries.filter { $0.favorite || $0.createdAt >= cutoff }.sorted { $0.createdAt > $1.createdAt }
        var total = result.reduce(Int64(0)) { $0 + $1.bytes }
        // result 已按时间倒序排列，反向遍历确保优先淘汰最旧记录。
        for entry in result.reversed() where !entry.favorite && total > capacity {
            result.removeAll { $0.id == entry.id }
            total -= entry.bytes
        }
        return result
    }
}
