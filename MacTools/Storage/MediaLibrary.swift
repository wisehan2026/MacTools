import AppKit
import Combine

/// 已成功导出的文件索引；只记录位置和大小，不把媒体内容复制进应用私有目录。
struct MediaItem: Identifiable, Codable {
    enum Kind: String, Codable { case screenshot = "截图", recording = "录像" }
    var id = UUID()
    var url: URL
    var createdAt: Date
    var kind: Kind
    var bytes: Int64
}

/// 维护本应用生成的媒体清单与占用统计，清理范围不扩展到用户目录中的其他文件。
@MainActor
final class MediaLibrary: ObservableObject {
    static let shared = MediaLibrary()
    @Published var items: [MediaItem] = []
    @Published var clipboardBytes: Int64 = 0
    @Published var cacheBytes: Int64 = 0
    @Published var message = ""
    private var manifest: URL { LocalFiles.root.appendingPathComponent("media.json") }
    init() {
        if let data = try? Data(contentsOf: manifest), let stored = try? JSONDecoder().decode([MediaItem].self, from: data) { items = stored }
    }
    func register(_ url: URL, kind: MediaItem.Kind) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        items.insert(MediaItem(url: url, createdAt: Date(), kind: kind, bytes: Int64(size)), at: 0)
        save()
    }
    /// 同步用户在 Finder 中删除或修改文件后的状态，再于后台统计历史与缓存目录。
    func refresh() async {
        items.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        for index in items.indices {
            items[index].bytes = Int64((try? items[index].url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        let sizes = await Task.detached(priority: .utility) { (LocalFiles.size(LocalFiles.clipboard), LocalFiles.size(LocalFiles.cache)) }.value
        clipboardBytes = sizes.0; cacheBytes = sizes.1
        save()
    }
    /// 先成功移至废纸篓，再移除索引；移动失败时保留记录并提示错误。
    func trash(_ item: MediaItem) {
        do {
            // 只操作本软件记录过的导出文件，不递归清理用户选择的目录。
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            items.removeAll { $0.id == item.id }
            save(); message = "已移至废纸篓"
        } catch { message = error.localizedDescription }
    }
    /// 仅删除可重建的应用缓存；剪贴板历史、收藏、截图和录像不属于这里的清理范围。
    func clearCache() async {
        do {
            try await MemeSearchService.shared.clearCache()
            if FileManager.default.fileExists(atPath: LocalFiles.cache.path) { try FileManager.default.removeItem(at: LocalFiles.cache) }
            try LocalFiles.ensure(LocalFiles.cache)
            cacheBytes = 0; message = "临时缓存已清理"
        } catch { message = error.localizedDescription }
    }
    private func save() {
        do { try LocalFiles.ensure(LocalFiles.root); try JSONEncoder().encode(items).write(to: manifest, options: .atomic) }
        catch { message = "保存媒体索引失败：\(error.localizedDescription)" }
    }
}
