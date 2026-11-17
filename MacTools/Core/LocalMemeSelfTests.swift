import AppKit
import ImageIO

/// 在隔离目录与命名剪贴板中验证永久图库，不访问用户文件或实际剪贴板。
@MainActor
enum LocalMemeSelfTests {
    static func run() async {
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ title: String) {
            if condition { passed += 1; print("PASS \(title)") }
            else { failed += 1; print("FAIL \(title)") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-LocalMemeTest-" + UUID().uuidString)
        let suite = "MacTools.LocalMemeTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard(name: NSPasteboard.Name(suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite); board.releaseGlobally() }
        do {
            try LocalFiles.ensure(root)
            let directory = root.appendingPathComponent("LocalMemes")
            let store = LocalMemeStore(directory: directory)
            let gif = try MemeSelfTests.animatedFixture()
            let sourceURL = root.appendingPathComponent("original.gif")
            try gif.write(to: sourceURL)
            let imported = try LocalMemeStore.readImport(sourceURL)
            let entry = try await store.save(name: "  开心猫  ", media: imported)
            check(entry.name == "开心猫" && entry.animated, "导入命名并识别动态图")
            try FileManager.default.removeItem(at: sourceURL)
            let original = try await store.media(id: entry.id)
            check(original.data == gif && original.frameCount == 2, "原文件删除后本地副本仍保留全部 GIF 帧")
            let thumbnail = try await store.media(id: entry.id, thumbnail: true)
            check(thumbnail.frameCount == 1 && thumbnail.typeIdentifier == "public.png", "列表使用独立静态缩略图")
            let reopened = LocalMemeStore(directory: directory)
            let records = try await reopened.list()
            let reopenedMedia = try await reopened.media(id: entry.id)
            check(records.count == 1 && reopenedMedia.data == gif, "重启后索引和原图完整恢复")
            let renamed = try await store.save(id: entry.id, name: "../新的名称")
            check(renamed.filename == entry.filename && renamed.name == "../新的名称", "重命名仅更新展示名称不改变文件路径")
            let current = try await store.results()[0]
            check(current.sourceTitle == "本地表情" && current.localID == entry.id && current.url.isFileURL, "本地与在线来源明确分流")
            let network = MemeSearchService(cacheDirectory: root.appendingPathComponent("cache"), transport: { _, _ in throw URLError(.notConnectedToInternet) })
            let loaded = try await MemeMediaLoader.load(current, service: network, local: store)
            check(loaded.data == gif, "断网时加载本地表情无需网络")
            let controller = LocalMemeController(store: store)
            await controller.refresh()
            controller.query = "新的 名称"
            check(controller.visible.count == 1, "本地按自定义名称匹配多个关键词")
            controller.filter = .still
            check(controller.visible.isEmpty, "本地静图筛选排除动图")
            controller.filter = .animated
            check(controller.visible.count == 1, "本地动图筛选保留匹配结果")
            let cache = MemeSearchCache(directory: root.appendingPathComponent("cache"))
            _ = try cache.replace(query: "test", response: MemeSearchResponse(results: [], total: 0))
            try cache.prune(days: 3, now: Date().addingTimeInterval(365 * 86400))
            try await network.clearCache()
            let afterCleanup = try await store.media(id: entry.id)
            check(afterCleanup.data == gif, "过期清理和清空搜索缓存不删除永久图库")
            let settings = SettingsStore(defaults: defaults)
            let clipboard = ClipboardStore(directory: root.appendingPathComponent("Clipboard"), board: board, settings: settings)
            _ = try clipboard.copyMeme(loaded, title: renamed.name, source: current.sourceTitle)
            check(clipboard.entries.first?.kind == .meme && board.data(forType: NSPasteboard.PasteboardType("com.compuserve.gif")) == gif,
                  "本地双击复制链路保留 GIF 并归类表情包历史")
            guard let cgSource = CGImageSourceCreateWithData(gif as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(cgSource, 0, nil) else {
                throw AppFailure.message("测试图片无法解码")
            }
            let still = try MemeMedia(data: LocalFiles.png(cg))
            let replaced = try await store.save(id: entry.id, name: "静态猫", media: still)
            let replacedMedia = try await store.media(id: entry.id)
            check(replaced.id == entry.id && !replaced.animated && replacedMedia.data == still.data, "更换图片保留条目 ID 并更新静动类型")
            check(!FileManager.default.fileExists(atPath: current.url.path), "替换成功后删除旧原图")
            let count = try await store.list().count
            for name in ["  ", String(repeating: "字", count: 101)] {
                do { _ = try await store.save(name: name, media: still); check(false, "拒绝无效名称") }
                catch { check(true, "拒绝空名称或超过 100 字的名称") }
            }
            let invalidFile = root.appendingPathComponent("invalid.gif")
            try Data("not an image".utf8).write(to: invalidFile)
            do { _ = try LocalMemeStore.readImport(invalidFile); check(false, "校验导入图片") }
            catch { check(true, "伪图片无法导入") }
            check(try await store.list().count == count, "导入失败不创建虚假条目")
            let manifest = directory.appendingPathComponent("library.json")
            let manifestData = try Data(contentsOf: manifest)
            try FileManager.default.removeItem(at: manifest)
            try LocalFiles.ensure(manifest)
            let imageDirectory = directory.appendingPathComponent("Images")
            let beforeFiles = try FileManager.default.contentsOfDirectory(atPath: imageDirectory.path)
            do { _ = try await store.save(id: entry.id, name: "失败替换", media: imported); check(false, "保存失败回滚") }
            catch { check(true, "索引写入失败时报告错误") }
            let afterFiles = try FileManager.default.contentsOfDirectory(atPath: imageDirectory.path)
            let afterFailedSave = try await store.media(id: entry.id)
            check(Set(beforeFiles) == Set(afterFiles) && afterFailedSave.data == still.data, "写入失败回滚新文件并保留原条目")
            do { try await store.delete(id: entry.id); check(false, "删除失败回滚") }
            catch { check(true, "索引无法提交时不删除本地图像") }
            try FileManager.default.removeItem(at: manifest)
            try manifestData.write(to: manifest)
            try await store.delete(id: entry.id)
            check(try await store.list().isEmpty, "手动删除条目")
            check(try FileManager.default.contentsOfDirectory(atPath: imageDirectory.path).isEmpty, "手动删除同时移除本地原图与缩略图")
            let savedHistory = clipboard.entries.first.flatMap { clipboard.imageURL($0) }
            check(savedHistory.flatMap { try? Data(contentsOf: $0) } == gif, "删除本地表情不影响已复制的历史记录")
            let freshStore = LocalMemeStore(directory: directory)
            check(try await freshStore.list().isEmpty, "删除结果重启后仍生效")
            try Data("broken index".utf8).write(to: manifest)
            do { _ = try await LocalMemeStore(directory: directory).save(name: "不可覆盖", media: still); check(false, "保护损坏索引") }
            catch { check(true, "索引损坏时拒绝覆盖原文件") }
        } catch { check(false, "本地图库集成：\(error.localizedDescription)") }
        await MemeSaveLocalSelfTests.run(root: root, check: check)
        print("LOCAL MEME RESULT \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
