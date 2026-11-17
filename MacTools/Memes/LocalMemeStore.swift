import AppKit
import ImageIO
import CryptoKit

struct LocalMeme: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let filename: String
    let thumbnailName: String
    let animated: Bool
    let createdAt: Date
    var fingerprint: String?
}

struct LocalMemeAddition: Sendable {
    let entry: LocalMeme
    let inserted: Bool
}

/// 用户导入的永久图库，与搜索缓存及剪贴板目录独立；只允许显式增删改，不执行过期清理。
actor LocalMemeStore {
    static let shared = LocalMemeStore()
    let directory: URL
    private var entries: [LocalMeme]?
    private var manifest: URL { directory.appendingPathComponent("library.json") }
    private var images: URL { directory.appendingPathComponent("Images", isDirectory: true) }

    init(directory: URL = LocalFiles.localMemes) { self.directory = directory }

    func list() throws -> [LocalMeme] {
        if let entries { return entries }
        let stored = FileManager.default.fileExists(atPath: manifest.path)
            ? try JSONDecoder().decode([LocalMeme].self, from: Data(contentsOf: manifest)) : []
        guard Set(stored.map(\.id)).count == stored.count,
              stored.allSatisfy({ safeFilename($0.filename) && safeFilename($0.thumbnailName) }) else { throw AppFailure.message("本地表情索引损坏，原文件已保留") }
        entries = stored
        return stored
    }

    func results() throws -> [MemeResult] {
        try list().map {
            MemeResult(title: $0.name, url: images.appendingPathComponent($0.filename), thumbnail: images.appendingPathComponent($0.thumbnailName),
                       pageURL: nil, animated: $0.animated, attribution: nil, source: nil, localID: $0.id)
        }
    }

    func media(id: UUID, thumbnail: Bool = false) throws -> MemeMedia {
        guard let entry = try list().first(where: { $0.id == id }) else { throw AppFailure.message("此本地表情已被删除") }
        return try MemeMedia(data: Data(contentsOf: images.appendingPathComponent(thumbnail ? entry.thumbnailName : entry.filename)))
    }

    /// 搜索结果一键收藏：按原始内容去重，复用已有条目并保留用户改过的名称。
    func addSearchResult(name: String, media: MemeMedia) throws -> LocalMemeAddition {
        try Task.checkCancellation()
        let fingerprint = Self.fingerprint(media.data)
        for entry in try list() {
            let original = images.appendingPathComponent(entry.filename)
            // 兼容未保存指纹的旧索引；不存在的原图不能被当作已成功收藏。
            let known = entry.fingerprint ?? (try? Data(contentsOf: original)).map(Self.fingerprint)
            if known == fingerprint, FileManager.default.fileExists(atPath: original.path) {
                return LocalMemeAddition(entry: entry, inserted: false)
            }
        }
        try Task.checkCancellation()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "表情包" : String(trimmed.prefix(100))
        return LocalMemeAddition(entry: try save(name: title, media: media), inserted: true)
    }

    /// 文件名由 UUID 生成，自定义名称仅存入索引；索引提交失败时回滚新文件，保留旧记录和原图。
    @discardableResult
    func save(id: UUID? = nil, name: String, media: MemeMedia? = nil) throws -> LocalMeme {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw AppFailure.message("请输入 1～100 个字的表情名称") }
        var next = try list()
        let old = next.first { $0.id == id }
        if id != nil, old == nil { throw AppFailure.message("此本地表情已被删除") }
        guard media != nil || old != nil else { throw AppFailure.message("请先选择表情图片") }
        var newFiles: [URL] = []
        let entry: LocalMeme
        do {
            if let media {
                let token = UUID().uuidString
                let filename = token + "." + media.fileExtension, thumbnail = token + "-thumb.png"
                try LocalFiles.ensure(images)
                let originalURL = images.appendingPathComponent(filename), thumbnailURL = images.appendingPathComponent(thumbnail)
                newFiles = [originalURL, thumbnailURL]
                try media.data.write(to: originalURL, options: .atomic)
                try Self.thumbnail(media.data).write(to: thumbnailURL, options: .atomic)
                entry = LocalMeme(id: old?.id ?? UUID(), name: name, filename: filename, thumbnailName: thumbnail,
                                  animated: media.frameCount > 1, createdAt: old?.createdAt ?? Date(), fingerprint: Self.fingerprint(media.data))
            } else {
                var renamed = old!
                renamed.name = name
                entry = renamed
            }
            if let index = next.firstIndex(where: { $0.id == entry.id }) { next[index] = entry }
            else { next.insert(entry, at: 0) }
            try persist(next)
        } catch {
            for file in newFiles { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        entries = next
        if let old, media != nil { removeFiles(old) }
        return entry
    }

    func delete(id: UUID) throws {
        var next = try list()
        guard let entry = next.first(where: { $0.id == id }) else { return }
        next.removeAll { $0.id == id }
        try persist(next)
        entries = next
        removeFiles(entry)
    }

    private func persist(_ items: [LocalMeme]) throws {
        try LocalFiles.ensure(directory)
        try JSONEncoder().encode(items).write(to: manifest, options: .atomic)
    }
    private func removeFiles(_ entry: LocalMeme) {
        for name in [entry.filename, entry.thumbnailName] { try? FileManager.default.removeItem(at: images.appendingPathComponent(name)) }
    }
    private func safeFilename(_ value: String) -> Bool { !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") }
    private static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func thumbnail(_ data: Data) throws -> Data {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256,
                                      kCGImageSourceCreateThumbnailWithTransform: true]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw AppFailure.message("无法生成表情缩略图") }
        return try LocalFiles.png(image)
    }

    /// 导入只读取用户选定的文件，校验后保留原始字节，不经 NSImage 重编码。
    static func readImport(_ url: URL) throws -> MemeMedia {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard url.isFileURL, values.isRegularFile == true, let size = values.fileSize, size <= MemeMedia.maximumBytes else {
            throw AppFailure.message("请选择不超过 16 MB 的图片文件")
        }
        return try MemeMedia(data: Data(contentsOf: url))
    }
}
