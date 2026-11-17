import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 从文件内容识别格式；始终保留原始字节，避免 GIF 经 NSImage 重编码后只剩第一帧。
struct MemeMedia: Sendable {
    let data: Data
    let typeIdentifier: String
    let fileExtension: String
    let frameCount: Int
    static let maximumBytes = 16 * 1_024 * 1_024

    init(data: Data, limitRemoteImage: Bool = true) throws {
        guard !data.isEmpty, (!limitRemoteImage || data.count <= Self.maximumBytes),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), type.conforms(to: .image),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              (!limitRemoteImage || (width <= 8192 && height <= 8192 && width * height <= 20_000_000)) else {
            throw AppFailure.message("图片无效或过大（单张最多 16 MB、2000 万像素）")
        }
        self.data = data
        typeIdentifier = identifier
        fileExtension = type.preferredFilenameExtension ?? "img"
        frameCount = CGImageSourceGetCount(source)
        if limitRemoteImage, frameCount > 1000 || Double(width) * Double(height) * Double(frameCount) > 120_000_000 {
            throw AppFailure.message("动图解码尺寸过大，暂不支持预览")
        }
    }

    /// 原格式优先，同时提供 PNG 首帧供只接受静图的目标应用使用。
    @MainActor
    func pasteboardItem(title: String? = nil) throws -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(typeIdentifier))
        if typeIdentifier != UTType.png.identifier,
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            item.setData(try LocalFiles.png(image), forType: .png)
        }
        if let title { item.setString(title, forType: Self.marker) }
        return item
    }

    static let marker = NSPasteboard.PasteboardType("local.wisehan.MacTools.meme")
    static let originalTypes = [UTType.gif, .webP, .png, .jpeg, .tiff, .heic].map { NSPasteboard.PasteboardType($0.identifier) }
}
