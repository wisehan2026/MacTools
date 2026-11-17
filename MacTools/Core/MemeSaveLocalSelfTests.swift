import AppKit
import ImageIO

/// 模拟原图下载验证一键添加，不访问接口、不操作用户图库或剪贴板。
@MainActor
enum MemeSaveLocalSelfTests {
    static func run(root: URL, check: (Bool, String) -> Void) async {
        let suite = "MacTools.SaveLocalTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            let gif = try MemeSelfTests.animatedFixture()
            guard let source = CGImageSourceCreateWithData(gif as CFData, nil), let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw AppFailure.message("无法解码测试图片")
            }
            let png = try LocalFiles.png(frame)
            let transport = SaveLocalTransport(gif: gif, png: png)
            let service = MemeSearchService(cacheDirectory: root.appendingPathComponent("SearchCache"), transport: { url, _ in try await transport.fetch(url) })
            let directory = root.appendingPathComponent("SavedResults")
            let store = LocalMemeStore(directory: directory)
            let settings = SettingsStore(defaults: defaults)
            let controller = MemeSearchController(service: service, localStore: store, settings: settings)
            func result(_ filename: String, title: String) -> MemeResult {
                let url = URL(string: "https://images.example/" + filename)!
                return MemeResult(title: title, url: url, thumbnail: URL(string: "https://images.example/thumbnail.png")!,
                                  pageURL: nil, animated: filename.hasSuffix("gif"), attribution: nil, source: .xiao)
            }
            let animated = result("original.gif", title: String(repeating: "猫", count: 120))
            let firstTask = controller.addToLocal(animated)
            check(firstTask != nil && controller.addToLocal(animated) == nil, "添加中拦截重复点击")
            await firstTask?.value
            let first = try await store.list()[0]
            let saved = try await store.media(id: first.id)
            check(first.name.count == 100 && saved.data == gif && saved.frameCount == 2 && controller.status.contains("已添加到本地"),
                  "一键保存搜索原图、完整 GIF 与有效默认名称")
            check(await transport.requestedURLs() == [animated.url], "添加读取原图而非列表缩略图")
            check(controller.localLibraryRevision == 1 && controller.addingLocalID == nil, "成功添加通知本地列表刷新并恢复按钮")
            _ = try await store.save(id: first.id, name: "我的名字")
            await controller.addToLocal(result("another-source.gif", title: "其他来源标题"))?.value
            check(try await store.list().count == 1 && controller.status.contains("我的名字"), "跨来源相同原图去重并保留自定义名称")
            await controller.addToLocal(result("still.png", title: " \n "))?.value
            let still = try await store.list().first { !$0.animated }!
            let stillMedia = try await store.media(id: still.id)
            check(still.name == "表情包" && stillMedia.data == png, "静图一键添加与空标题回退")
            let manifest = directory.appendingPathComponent("library.json")
            var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [[String: Any]]
            for index in legacy.indices { legacy[index].removeValue(forKey: "fingerprint") }
            try JSONSerialization.data(withJSONObject: legacy).write(to: manifest, options: .atomic)
            let reopened = LocalMemeStore(directory: directory)
            let reused = try await reopened.addSearchResult(name: "新标题", media: MemeMedia(data: gif))
            check(!reused.inserted && reused.entry.id == first.id && reused.entry.name == "我的名字", "兼容旧图库索引并跨重启去重")
            try await service.clearCache()
            check((try await reopened.media(id: first.id)).data == gif, "清理搜索缓存不删除一键添加的原图")
            await controller.addToLocal(result("error.gif", title: "下载失败"))?.value
            check(try await store.list().count == 2 && controller.addingLocalID == nil && controller.status.contains("添加到本地失败"), "下载失败不创建条目并允许重试")
            try await store.delete(id: first.id)
            await controller.addToLocal(animated)?.value
            check(try await store.list().count == 2 && controller.status.contains("已添加到本地"), "手动删除后可再次一键添加")

            let backgroundStore = LocalMemeStore(directory: root.appendingPathComponent("SwitchCategory"))
            let background = MemeSearchController(service: service, localStore: backgroundStore, settings: settings)
            let backgroundTask = background.addToLocal(animated)
            background.close(cancelLocalAddition: false)
            await backgroundTask?.value
            check(try await backgroundStore.list().count == 1 && background.localLibraryRevision == 1, "切换到本地分类仍完成已发起的添加并通知刷新")
            let cancelledStore = LocalMemeStore(directory: root.appendingPathComponent("Cancelled"))
            let cancelled = MemeSearchController(service: service, localStore: cancelledStore, settings: settings)
            let pending = cancelled.addToLocal(animated)
            cancelled.close()
            await pending?.value
            check(try await cancelledStore.list().isEmpty && cancelled.addingLocalID == nil, "关闭窗口取消尚未写入的添加")
            settings.setFeatureEnabled(.memes, enabled: false)
            check(controller.addToLocal(animated) == nil, "功能关闭后禁止添加搜索结果")
            settings.setFeatureEnabled(.memes, enabled: true)
            let blocked = root.appendingPathComponent("BlockedLocalDirectory")
            try Data("file blocks directory".utf8).write(to: blocked)
            let failed = MemeSearchController(service: service, localStore: LocalMemeStore(directory: blocked), settings: settings)
            await failed.addToLocal(animated)?.value
            check(failed.localLibraryRevision == 0 && failed.addingLocalID == nil && failed.status.contains("添加到本地失败"), "磁盘写入失败不误报成功")

            let offlineStore = LocalMemeStore(directory: root.appendingPathComponent("OfflineSave"))
            let offline = MemeSearchController(service: service, localStore: offlineStore, settings: settings)
            offline.query = "cached"; offline.search()
            let deadline = Date().addingTimeInterval(5)
            while offline.loading, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard let cachedResult = offline.results.first else { throw AppFailure.message("缓存搜索测试失败：" + offline.error) }
            await service.finishPendingCacheWrites()
            await transport.setOffline()
            await offline.addToLocal(cachedResult)?.value
            guard let offlineEntry = try await offlineStore.list().first else { throw AppFailure.message("离线添加失败：" + offline.status) }
            let offlineMedia = try await offlineStore.media(id: offlineEntry.id)
            check(offlineMedia.data == gif && offline.status.contains("已添加到本地"), "接口断网后仍可从搜索原图缓存一键添加")
        } catch { check(false, "搜索结果添加本地：\(error.localizedDescription)") }
    }
}

private actor SaveLocalTransport {
    let gif: Data
    let png: Data
    private var urls: [URL] = []
    private var offline = false
    init(gif: Data, png: Data) { self.gif = gif; self.png = png }
    func fetch(_ url: URL) throws -> Data {
        urls.append(url)
        if offline { throw URLError(.notConnectedToInternet) }
        if url.host == "memecub.com" {
            return try JSONSerialization.data(withJSONObject: ["data": [["url": "https://images.example/cached.gif",
                "title": "cached", "kind": "gif", "thumb_url": "https://images.example/thumbnail.png"]], "total": 1])
        }
        if url.lastPathComponent == "error.gif" { throw URLError(.notConnectedToInternet) }
        return url.pathExtension == "png" ? png : gif
    }
    func requestedURLs() -> [URL] { urls }
    func setOffline() { offline = true }
}
