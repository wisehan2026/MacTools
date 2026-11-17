import AppKit
import Combine

/// 本地与在线资源显式分流，导入文件不会进入网络层或搜索缓存。
enum MemeMediaLoader {
    static func load(_ result: MemeResult, thumbnail: Bool = false, reference: MemeCacheReference? = nil,
                     service: MemeSearchService = .shared, local: LocalMemeStore = .shared) async throws -> MemeMedia {
        if let id = result.localID { return try await local.media(id: id, thumbnail: thumbnail) }
        return try await service.media(thumbnail ? result.thumbnail : result.url, reference: reference)
    }
}

@MainActor
final class MemeImageLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var failed = false
    func load(_ result: MemeResult, reference: MemeCacheReference?) async {
        image = nil; failed = false
        do {
            let media = try await MemeMediaLoader.load(result, thumbnail: true, reference: reference)
            try Task.checkCancellation()
            image = NSImage(data: media.data)
            failed = image == nil
        } catch { if !Task.isCancelled { failed = true } }
    }
}
