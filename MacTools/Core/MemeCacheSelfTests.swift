import AppKit

/// 使用模拟网络与临时目录验证真实服务的更新、超限回退及图片落盘，不消耗匿名 API 额度。
@MainActor
enum MemeCacheSelfTests {
    static func run() async {
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ name: String) {
            if condition { passed += 1; print("PASS \(name)") }
            else { failed += 1; print("FAIL \(name)") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-CacheTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let gif = try MemeSelfTests.animatedFixture()
            let response = try MemeSearchService.decode(MemeCacheTransport.response(title: "旧结果", count: 55))
            let disk = MemeSearchCache(directory: directory.appendingPathComponent("Disk"))
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let reference = try disk.replace(query: "  HELLO   无语 \n", response: response, now: now)
            let saved = try disk.lookup(query: "hello 无语", days: 3, now: now)
            check(saved?.results.count == 50, "相同关键词规范化匹配且最多缓存 50 条")
            try disk.storeMedia(gif, url: response.results[0].url, reference: reference, days: 3, now: now)
            let restarted = MemeSearchCache(directory: disk.directory)
            check(restarted.media(response.results[0].url, reference: reference, days: 3, now: now) == gif, "重启可读取磁盘 GIF 原始字节")
            check(try restarted.lookup(query: "hello 无语", days: 3, now: now.addingTimeInterval(3 * 86400 - 1))?.cachedAt == now,
                  "过期前可读取且不延长缓存时间")
            check(try restarted.lookup(query: "hello 无语", days: 3, now: now.addingTimeInterval(3 * 86400)) == nil, "满 72 小时自动失效")
            check(LocalFiles.size(disk.directory) == 0, "过期同时清除索引与原图")

            let old = try disk.replace(query: "无语", response: response, now: now)
            try disk.storeMedia(gif, url: response.results[0].url, reference: old, days: 3, now: now)
            let updateTime = now.addingTimeInterval(86400)
            let next = try disk.replace(query: "无语", response: MemeSearchResponse(results: Array(response.results.prefix(2)), total: 2), now: updateTime)
            let updatedDisk = try disk.lookup(query: "无语", days: 3, now: updateTime)
            check(next.generation != old.generation && updatedDisk?.results.count == 2,
                  "新结果替换旧结果并重新计算保留期")
            try disk.storeMedia(gif, url: response.results[0].url, reference: old, days: 3, now: updateTime)
            check(disk.media(response.results[0].url, reference: old, days: 3, now: updateTime) == nil, "旧批次延迟下载不能复活或覆盖新缓存")
            _ = try disk.replace(query: "无语", response: MemeSearchResponse(results: [], total: 0), now: updateTime)
            check(try disk.lookup(query: "无语", days: 3, now: updateTime)?.results.isEmpty == true, "成功的空搜索结果也替换旧数据")
            _ = try disk.replace(query: "更久", response: response, now: now)
            try disk.prune(days: 7, now: now.addingTimeInterval(4 * 86400))
            check(try disk.lookup(query: "更久", days: 7, now: now.addingTimeInterval(4 * 86400)) != nil, "延长设置保留有效缓存")
            try disk.prune(days: 1, now: now.addingTimeInterval(4 * 86400))
            check(LocalFiles.size(disk.directory) == 0, "缩短保留时间立即清除已到期关键词及图片")

            let remote = MemeCacheTransport(image: gif)
            let serviceDirectory = directory.appendingPathComponent("Service")
            let service = MemeSearchService(cacheDirectory: serviceDirectory, transport: { url, limit in try await remote.fetch(url, maximumBytes: limit) })
            let fresh = try await service.search(query: "开心")
            await service.finishPendingCacheWrites()
            check(fresh.cachedAt == nil && fresh.results.count == 50 && fresh.cacheReference != nil, "首次联网成功显示并持久化前 50 条")
            let mediaCalls = await remote.mediaCalls
            check(mediaCalls == 100, "后台完整缓存 50 张缩略图与 50 张原图")
            await remote.setMode(.quota)
            // 新服务实例模拟进程重启；本地图片读取不依赖第一次搜索的内存缓存。
            let offline = MemeSearchService(cacheDirectory: serviceDirectory, transport: { url, limit in try await remote.fetch(url, maximumBytes: limit) })
            let fallback = try await offline.search(query: "开心")
            check(fallback.cachedAt == fresh.cacheReference?.refreshedAt && fallback.notice.contains("接口超限"), "接口超限自动显示重启后的本地结果")
            let image = try await offline.media(fallback.results[49].url, reference: fallback.cacheReference)
            let thumb = try await offline.media(fallback.results[49].thumbnail, reference: fallback.cacheReference)
            check(image.data == gif && thumb.data == gif && image.frameCount == 2, "未浏览的第 50 张也能完全离线预览和复制 GIF")
            check(await remote.mediaCalls == mediaCalls, "本地回退预览不再下载已缓存图片")
            do { _ = try await offline.search(query: "从未搜索"); check(false, "无缓存超限") }
            catch { check(error is MemeServiceFailure, "无缓存时明确报告超限，不显示其他关键词结果") }
            await remote.setMode(.unavailable)
            let networkFallback = try await offline.search(query: "开心")
            check(networkFallback.notice.contains("联网失败"), "断网时也可显示有效缓存")
            await remote.setMode(.success("新结果", 2))
            let updated = try await offline.search(query: "开心")
            await offline.finishPendingCacheWrites()
            check(updated.results.count == 2 && updated.results[0].title == "新结果", "有缓存仍优先联网，用最新结果替换显示")
            let networkImageCalls = await remote.mediaCalls
            check(networkImageCalls == mediaCalls + 4, "同 URL 新批次重新下载图片，避免旧内容残留")
            await remote.setMode(.quota)
            check(try await offline.search(query: "开心").results.count == 2, "更新后超限只返回最新缓存")
            try await offline.clearCache()
            check(LocalFiles.size(serviceDirectory) == 0, "手动清理同时删除搜索索引和图片")

            // 控制两个并发请求的返回顺序，确认慢旧响应不能回写覆盖最新缓存。
            await remote.setMode(.success("慢旧响应", 4))
            await remote.holdNextSearch()
            let slow = Task { try await service.search(query: "顺序") }
            await remote.waitForHeldSearch()
            await remote.setMode(.success("快新响应", 1))
            _ = try await service.search(query: "顺序")
            await remote.releaseHeldSearch()
            do { _ = try await slow.value; check(false, "乱序请求") }
            catch { check(error is CancellationError, "旧请求晚返回也不能覆盖新请求") }
            await service.finishPendingCacheWrites()
            await remote.setMode(.quota)
            check(try await service.search(query: "顺序").results.first?.title == "快新响应", "乱序请求后磁盘保留最新结果")
            try await service.clearCache()
        } catch { check(false, "缓存集成测试：\(error.localizedDescription)") }
        print("MEME CACHE RESULT \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

private actor MemeCacheTransport {
    enum Mode { case success(String, Int), quota, unavailable }
    var mode = Mode.success("旧结果", 55)
    let image: Data
    private(set) var mediaCalls = 0
    private var hold = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    init(image: Data) { self.image = image }
    func setMode(_ mode: Mode) { self.mode = mode }
    func holdNextSearch() { hold = true }
    func waitForHeldSearch() async {
        if held == nil { await withCheckedContinuation { waiting = $0 } }
    }
    func releaseHeldSearch() { held?.resume(); held = nil }
    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        if url.path == "/api/v1/search" {
            let result = mode
            if hold {
                hold = false
                await withCheckedContinuation { held = $0; waiting?.resume(); waiting = nil }
            }
            switch result {
            case .success(let title, let count): return Self.response(title: title, count: count)
            case .quota: throw MemeServiceFailure.quotaExceeded
            case .unavailable: throw URLError(.notConnectedToInternet)
            }
        }
        if case .quota = mode { throw URLError(.notConnectedToInternet) }
        mediaCalls += 1
        return image
    }
    static func response(title: String, count: Int) -> Data {
        let rows = (0..<count).map { ["title": title, "url": "https://example.com/\($0).gif", "thumb_url": "https://example.com/\($0)-thumb.gif", "kind": "gif"] }
        return try! JSONSerialization.data(withJSONObject: ["data": rows, "total": count])
    }
}
