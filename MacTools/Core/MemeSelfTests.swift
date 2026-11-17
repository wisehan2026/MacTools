import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 使用独立目录、偏好域和命名剪贴板，不接触真实历史或用户当前复制内容。
@MainActor
enum MemeSelfTests {
    static func run(check: (Bool, String) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-MemeTest-" + UUID().uuidString)
        let suite = "MacTools.MemeTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard.withUniqueName()
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
            board.releaseGlobally()
        }
        do {
            // 旧版用户已有快捷键字典时补齐新键；用户主动停用后不能被再次迁移恢复。
            defaults.set(try JSONEncoder().encode([Feature.clipboard.rawValue: Shortcut.standard(for: .clipboard)!]), forKey: "shortcuts")
            let settings = SettingsStore(defaults: defaults)
            check(settings.memeCacheDays == 3, "表情搜索缓存默认保留三天")
            settings.memeCacheDays = 7
            check(SettingsStore(defaults: defaults).memeCacheDays == 7, "表情缓存天数修改后持久化")
            check(settings.shortcuts["memes"] == Shortcut.standard(for: .memes), "已有配置迁移表情搜索快捷键")
            settings.shortcuts.removeValue(forKey: "memes")
            check(SettingsStore(defaults: defaults).shortcuts["memes"] == nil, "重启保留用户停用的表情快捷键")
            defaults.removeObject(forKey: "memeShortcutMigrated")
            settings.shortcuts["search"] = Shortcut.standard(for: .memes)
            check(SettingsStore(defaults: defaults).shortcuts["memes"] == nil, "新快捷键不抢占用户自定义组合键")

            let url = try MemeSearchService.searchURL(query: " 无语 & 开心 ")
            check(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "无语 & 开心", "中文和特殊字符搜索编码")
            let response = Data("""
            {"data":[
              {"title":"静图","url":"https://example.com/a.png","thumb_url":"file:///tmp/x","kind":"meme"},
              {"title":"动图","url":"https://example.com/b.gif","kind":"gif"},
              {"url":"https://example.com/b.gif"}, {"url":"file:///tmp/secret"}, {"title":"损坏条目"}
            ],"total":5}
            """.utf8)
            let decoded = try MemeSearchService.decode(response)
            check(decoded.results.count == 2 && decoded.results[1].animated, "解析静图与动图、去重并过滤无效地址")
            check(decoded.results[0].thumbnail == decoded.results[0].url, "不安全缩略图回退原图")
            do { _ = try MemeSearchService.decode(Data("{\"error\":\"failed\"}".utf8)); check(false, "拒绝错误结构") }
            catch { check(true, "拒绝错误结构，不伪装成空结果") }
            do { _ = try MemeMedia(data: Data("<html>not an image</html>".utf8)); check(false, "拒绝伪图片") }
            catch { check(true, "拒绝伪图片") }

            let gif = try animatedFixture()
            let media = try MemeMedia(data: gif)
            check(media.frameCount == 2 && media.fileExtension == "gif", "识别双帧 GIF 原始格式")
            let frames = CGImageSourceCreateWithData(gif as CFData, nil)!
            let first = CGImageSourceCreateImageAtIndex(frames, 0, nil)!
            let second = CGImageSourceCreateImageAtIndex(frames, 1, nil)!
            check(try LocalFiles.png(first) != LocalFiles.png(second), "GIF 测试素材包含两个不同画面")
            let store = ClipboardStore(directory: folder, board: board, settings: settings)
            store.paused = true
            _ = try store.copyMeme(media, title: "开心测试")
            check(store.entries.count == 1 && store.entries.first?.kind == .meme, "暂停监听时主动复制仍保存表情分类")
            check(board.data(forType: NSPasteboard.PasteboardType(UTType.gif.identifier)) == gif, "复制保留 GIF 原始字节及两帧")
            check(board.data(forType: .png) != nil, "动图同时提供静图兼容表示")
            let entry = store.entries[0]
            let savedURL = store.imageURL(entry)!
            check(try Data(contentsOf: savedURL) == gif, "本地历史按 GIF 原格式落盘")
            store.toggleFavorite(entry)
            _ = try store.copyMeme(media, title: "开心测试更新")
            store.paused = false
            store.poll()
            check(store.entries.count == 1 && store.entries[0].id == entry.id && store.entries[0].favorite, "双击重复去重、保留收藏、不被轮询重复收录")
            let reloaded = ClipboardStore(directory: folder, board: board, settings: settings)
            check(reloaded.entries[0].kind == .meme && reloaded.entries[0].memeTitle == "开心测试更新", "重启后恢复表情分类和搜索标题")
            board.clearContents()
            reloaded.copy(reloaded.entries[0])
            check(board.data(forType: NSPasteboard.PasteboardType(UTType.gif.identifier)) == gif, "历史重复制保留 GIF 所有帧")
            board.clearContents(); board.setData(gif, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
            reloaded.poll()
            check(reloaded.entries.count == 1 && reloaded.entries[0].kind == .meme, "外部重复复制不会丢失表情分类")

            let old = ClipboardEntry(createdAt: Date(), kind: .text, text: "旧记录", fingerprint: "legacy", source: "test", bytes: 9)
            let legacyData = try JSONEncoder().encode(old)
            check(try JSONDecoder().decode(ClipboardEntry.self, from: legacyData).memeTitle == nil, "无新增字段的旧历史兼容读取")
            reloaded.clearUnpinned()
            check(reloaded.entries.count == 1 && FileManager.default.fileExists(atPath: savedURL.path), "清理普通记录保留收藏表情原图")
            reloaded.delete(reloaded.entries[0])
            check(reloaded.entries.isEmpty && !FileManager.default.fileExists(atPath: savedURL.path), "删除表情同时清理原图")
            let png = try media.pasteboardItem().data(forType: .png)!
            _ = try reloaded.copyMeme(MemeMedia(data: png), title: "静态测试")
            check(reloaded.entries.first?.kind == .meme && board.data(forType: .png) == png, "静态 PNG 同样复制原图并归类表情包")
            reloaded.clearUnpinned()

            // 容量不足仍可复制，但不虚报成功保存；持久化失败同样保持已存在的索引。
            settings.capacityMB = 0
            let limited = try reloaded.copyMeme(media, title: "容量测试")
            check(reloaded.entries.isEmpty && limited.contains("容量不足") && board.data(forType: NSPasteboard.PasteboardType(UTType.gif.identifier)) == gif,
                  "容量不足时保留复制能力并明确提示未记录")
            settings.capacityMB = 64
            try FileManager.default.removeItem(at: folder.appendingPathComponent("history.json"))
            try LocalFiles.ensure(folder.appendingPathComponent("history.json"))
            let failure = try reloaded.copyMeme(media, title: "写入失败测试")
            check(reloaded.entries.isEmpty && failure.contains("历史保存失败"), "索引写入失败不产生虚假历史记录")
        } catch { check(false, "表情包回归测试：\(error.localizedDescription)") }
    }

    static func animatedFixture() throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, 2, nil) else {
            throw AppFailure.message("无法创建 GIF 测试数据")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<2 {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let pixels = rep.bitmapData!
            for y in 0..<16 {
                for x in 0..<16 {
                    let offset = y * rep.bytesPerRow + x * 4
                    pixels[offset] = frame == 0 ? 255 : 0
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = frame == 1 ? 255 : 0
                    pixels[offset + 3] = 255
                }
            }
            CGImageDestinationAddImage(destination, rep.cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw AppFailure.message("无法编码 GIF 测试数据") }
        return output as Data
    }

    /// 显式命令才调用真实服务；验证搜索、缩略图、原图和原生动图解码，不写系统通用剪贴板。
    static func live() async {
        do {
            let response = try await MemeSearchService.shared.search(query: "无语")
            guard let gif = response.results.first(where: \.animated), let still = response.results.first(where: { !$0.animated }) else {
                throw AppFailure.message("此次搜索未同时返回动图和静图")
            }
            for result in [gif, still] {
                let media = try await MemeSearchService.shared.media(result.url)
                let thumbnail = try await MemeSearchService.shared.media(result.thumbnail)
                guard NSImage(data: media.data) != nil, NSImage(data: thumbnail.data) != nil else { throw AppFailure.message("原生图片解码失败") }
                if result.animated, media.frameCount < 2 { throw AppFailure.message("动图只有一帧") }
                print("PASS 联网搜索与原生解码：\(result.title)，\(media.fileExtension)，\(media.frameCount) 帧")
            }
            print("PASS 实际 API 返回 \(response.results.count) 条可用结果")
            exit(0)
        } catch { print("FAIL 联网验证：\(error.localizedDescription)"); exit(1) }
    }
}
