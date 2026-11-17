import AppKit

/// 模拟五个真实适配协议，验证均分额度、独立缓存、失败回退和来源设置，不消耗远程接口额度。
@MainActor
enum MemeSourceSelfTests {
    static func run() async {
        var passed = 0, failed = 0
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1; print("PASS \(name)") }
            else { failed += 1; print("FAIL \(name)") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-SourceTest-" + UUID().uuidString)
        let suite = "MacTools.SourceTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        do {
            let settings = SettingsStore(defaults: defaults)
            check(settings.memeSources == [.memecub], "旧配置保留原单源选择")
            for source in MemeSource.allCases { settings.setMemeSource(source, enabled: true) }
            let all = Set(MemeSource.allCases)
            check(SettingsStore(defaults: defaults).memeSources == all, "多选来源持久化")
            settings.useOnlyMemeSource(.pdan)
            settings.setMemeSource(.pdan, enabled: false)
            check(settings.memeSources == [.pdan], "一键单选且不能取消最后一个来源")
            let three: Set<MemeSource> = [.memecub, .xiao, .chinesebqb]
            check(MemeSource.limit(for: three) == 16 && MemeSource.limit(for: all) == 10 && MemeSource.limit(for: [.xiao]) == 50, "三源每源 16、五源每源 10、单源 50")
            let transport = MultiMemeTransport(image: try MemeSelfTests.animatedFixture())
            let service = MemeSearchService(cacheDirectory: directory, transport: { url, _ in try await transport.fetch(url) })
            let full = try await service.search(query: "测试", sources: all)
            await service.finishPendingCacheWrites()
            check(full.results.count == 50 && MemeSource.allCases.allSatisfy { source in full.results.filter { $0.source == source }.count == 10 }, "五源搜索均分至每源前 10 条")
            check(full.results.compactMap(\.source) == MemeSource.allCases.flatMap { Array(repeating: $0, count: 10) }, "按来源顺序依次显示整组结果")
            check(full.resultReferences.count == 50, "每条结果关联自身来源的图片缓存")
            let oldReferences = full.resultReferences
            await transport.fail(all)
            let offline = try await service.search(query: "测试", sources: all)
            check(offline.results.count == 50 && offline.resultReferences == oldReferences, "五源全部超限时读取各自缓存且不续期")
            for source in MemeSource.allCases {
                let item = offline.results.last { $0.source == source }!
                let media = try await service.media(item.url, reference: offline.resultReferences[item.id])
                check(media.frameCount == 2, "\(source.title)的末条动图可离线读取")
            }
            do { _ = try await service.search(query: "测试", sources: three); check(false, "组合缓存隔离") }
            catch { check(true, "切换三源后不错误读取五源缓存") }
            await transport.fail([])
            let smaller = try await service.search(query: "测试", sources: three)
            await service.finishPendingCacheWrites()
            check(smaller.results.count == 48 && three.allSatisfy { source in smaller.results.filter { $0.source == source }.count == 16 }, "三源模式每源 16 条总计 48 条")
            let xiao = smaller.results.first { $0.source == .xiao }!
            let memecub = smaller.results.first { $0.source == .memecub }!
            await transport.fail([.xiao])
            let partial = try await service.search(query: "测试", sources: three)
            await service.finishPendingCacheWrites()
            check(partial.results.count == 48 && partial.notice.contains("慕名表情") && partial.notice.contains("接口超限"), "单源超限保留其他新结果并说明来源状态")
            check(partial.resultReferences[xiao.id] == smaller.resultReferences[xiao.id]
                  && partial.resultReferences[memecub.id] != smaller.resultReferences[memecub.id], "成功来源刷新不延长失败来源的旧缓存")
            let freshPartial = try await service.search(query: "未缓存", sources: all)
            check(freshPartial.results.count == 40 && !freshPartial.results.contains { $0.source == .xiao }, "无缓存的失败来源不影响其他四源，也不超额补齐")
            await transport.fail([])
            let single = try await service.search(query: "测试", sources: [.memecub])
            await service.finishPendingCacheWrites()
            check(single.results.count == 50 && single.cacheReference != nil, "从多源切回单源恢复前 50 条")
            await transport.useDuplicates()
            let duplicates = try await service.search(query: "重复", sources: all)
            check(duplicates.results.count == 46 && Set(duplicates.results.map(\.url)).count == 46, "跨源重复图片去重，不突破每源额度")
            for source in MemeSource.allCases {
                do { _ = try MemeSourceAdapter.decode(Data("{}".utf8), source: source, query: "测试", limit: 10); check(false, "拒绝失效源") }
                catch { check(true, "\(source.title)异常结构不会伪装为空结果") }
            }
            let unsafe = Data("{\"code\":200,\"data\":[{\"img_url\":\"file:///tmp/private\"}]}".utf8)
            do { _ = try MemeSourceAdapter.decode(unsafe, source: .xiao, query: "测试", limit: 10); check(false, "拒绝不安全地址") }
            catch { check(true, "新增接口拒绝非 HTTPS 图片") }
            let catalog = try JSONSerialization.data(withJSONObject: [
                ["label": "开心猫", "src": "media/cat.gif", "thumb": "thumbs/cat.webp", "categoryTitle": "猫咪", "animated": true],
                ["label": "开心狗", "src": "media/dog.jpg", "categoryTitle": "狗狗", "animated": false]
            ])
            let cats = try MemeSourceAdapter.decode(catalog, source: .chinesebqb, query: "开心 猫咪", limit: 10)
            check(cats.results.count == 1 && cats.results.first?.animated == true
                  && cats.results.first?.url.absoluteString == "https://zhaoolee.com/ChineseBQB/media/cat.gif"
                  && cats.results.first?.thumbnail.pathExtension == "webp", "开源目录按名称及分类匹配，并保留 GIF 原图与独立缩略图")
            let noMatch = try MemeSourceAdapter.decode(catalog, source: .chinesebqb, query: "不存在", limit: 10)
            check(noMatch.results.isEmpty, "目录无匹配时正常返回空结果")
            await transport.disableDuplicates()
            settings.moveMemeSource(.pdan, to: .memecub)
            check(settings.memeSourceOrder.first == .pdan && SettingsStore(defaults: defaults).memeSourceOrder == settings.memeSourceOrder, "拖动排序保存且重启保留")
            settings.setMemeCustomDistribution(true)
            settings.setMemeCount(30, for: .pdan)
            settings.setMemeSource(.xiao, enabled: true)
            settings.setMemeCount(7, for: .xiao)
            let custom = settings.memeSearchPlan
            check(custom.sources == [.pdan, .xiao] && custom.total == 37, "自定义分配按保存的顺序与各源数量生成计划")
            check(SettingsStore(defaults: defaults).memeSearchPlan == custom, "自定义数量和模式跨启动持久化")
            let allocated = try await service.search(query: "测试", plan: custom)
            await service.finishPendingCacheWrites()
            check(allocated.results.count == 37 && allocated.results.prefix(30).allSatisfy { $0.source == .pdan }
                  && allocated.results.suffix(7).allSatisfy { $0.source == .xiao }, "自定义数量决定请求截取与显示顺序")
            await transport.fail(all)
            let reversed = MemeSearchPlan(sources: Set(custom.sources), order: custom.sources.reversed(), counts: custom.limits)
            let reordered = try await service.search(query: "测试", plan: reversed)
            check(reordered.results.prefix(7).allSatisfy { $0.source == .xiao }
                  && reordered.resultReferences == allocated.resultReferences, "仅排序后离线复用原缓存且不续期")
            let changed = MemeSearchPlan(sources: Set(custom.sources), counts: [.pdan: 20, .xiao: 7])
            do { _ = try await service.search(query: "测试", plan: changed); check(false, "数量缓存隔离") }
            catch { check(true, "改变分配数量不会误用其他额度缓存") }
            await transport.fail([])
            let large = MemeSearchPlan(sources: [.xiao, .pdan], counts: [.xiao: 40, .pdan: 30])
            let expanded = try await service.search(query: "测试", plan: large)
            check(expanded.results.count == 70, "自定义总数可超过默认 50 条")
            settings.setMemeCount(500, for: .xiao)
            settings.setMemeCount(-1, for: .pdan)
            check(settings.memeCount(for: .xiao) == 50 && settings.memeCount(for: .pdan) == 1, "每源数量限制在接口支持的 1～50 条")
            settings.setMemeCustomDistribution(false)
            check(settings.memeSearchPlan.total == 50 && settings.memeSearchPlan.limits[.pdan] == 25, "关闭自定义恢复最大 50 平均分")
            await service.finishPendingCacheWrites()
            try await service.clearCache()
        } catch { check(false, "多源集成：\(error.localizedDescription)") }
        print("MEME SOURCES RESULT \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    /// 真实端到端检查每个来源的检索和原图解码；缓存落入临时目录，不影响用户搜索记录。
    static func live() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-SourcesLive-" + UUID().uuidString)
        let service = MemeSearchService(cacheDirectory: directory)
        var failed = 0
        let requested = CommandLine.arguments.compactMap(MemeSource.init(rawValue:))
        let sources = requested.isEmpty ? MemeSource.allCases : requested
        for source in sources {
            do {
                let url = try MemeSourceAdapter.requestURL(source: source, query: "无语", limit: 10)
                let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20))
                guard let response = response as? HTTPURLResponse else { throw AppFailure.message("HTTP 响应失败") }
                guard response.statusCode == 200 else { throw AppFailure.message("HTTP \(response.statusCode)") }
                let parsed = try MemeSourceAdapter.decode(data, source: source, query: "无语", limit: 10)
                guard let first = parsed.results.first else { throw AppFailure.message("没有可用结果") }
                let media = try await service.media(first.url)
                guard NSImage(data: media.data) != nil else { throw AppFailure.message("图片无法解码") }
                print("PASS \(source.title)：\(parsed.results.count) 条，首图 \(media.fileExtension) / \(media.frameCount) 帧")
            } catch { failed += 1; print("FAIL \(source.title)：\(error.localizedDescription)") }
        }
        try? await service.clearCache()
        print("MEME SOURCES LIVE RESULT \(sources.count - failed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

private actor MultiMemeTransport {
    let image: Data
    var failures: Set<MemeSource> = []
    var duplicates = false
    init(image: Data) { self.image = image }
    func fail(_ sources: Set<MemeSource>) { failures = sources }
    func useDuplicates() { duplicates = true }
    func disableDuplicates() { duplicates = false }
    func fetch(_ url: URL) throws -> Data {
        let source = MemeSource.allCases.first { (try? MemeSourceAdapter.requestURL(source: $0, query: "测试", limit: 10))?.host == url.host }
        guard let source else {
            if failures.count == 5 { throw URLError(.notConnectedToInternet) }
            return image
        }
        if failures.contains(source) { throw MemeServiceFailure.quotaExceeded }
        let urls = (0..<60).map { "https://images.example/\(duplicates && $0 == 0 ? "shared" : source.rawValue)/\($0).gif" }
        switch source {
        case .memecub:
            return try JSONSerialization.data(withJSONObject: ["data": urls.map { ["title": "测试", "url": $0, "kind": "gif"] }, "total": 60])
        case .xiao:
            return try JSONSerialization.data(withJSONObject: ["code": 200, "data": urls.map { ["img_url": $0] }])
        case .ruseo:
            return try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["code": 200, "res": urls]])
        case .chinesebqb:
            return try JSONSerialization.data(withJSONObject: urls.map { ["label": "测试 未缓存 重复", "src": $0, "animated": true] as [String: Any] })
        case .pdan:
            let rows = urls.map { "<a class='imageLink'><img src='\($0)' alt='测试'></a>" }.joined()
            return Data("<html><body><div id='postlist'>\(rows)</div></body></html>".utf8)
        }
    }
}
