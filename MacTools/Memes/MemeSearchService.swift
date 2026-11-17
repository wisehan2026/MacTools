import Foundation

struct MemeResult: Identifiable, Sendable, Equatable, Codable {
    var id: String { url.absoluteString }
    let title: String
    var url: URL
    let thumbnail: URL
    let pageURL: URL?
    let animated: Bool
    let attribution: String?
    var source: MemeSource?
    var localID: UUID?
    var sourceTitle: String { localID == nil ? (source ?? .memecub).title : "本地表情" }
}

struct MemeSearchResponse: Sendable {
    let results: [MemeResult]
    let total: Int
    var cacheReference: MemeCacheReference?
    var cachedAt: Date?
    var notice = ""
    var resultReferences: [String: MemeCacheReference] = [:]
}

enum MemeServiceFailure: LocalizedError {
    case quotaExceeded
    var errorDescription: String? { "搜索额度已用完或请求过于频繁，且此关键词没有有效的本地缓存。请稍后或明天再试。" }
}

/// 使用公开 API、静态目录与网页数据，不执行远程脚本。来源说明见 THIRD_PARTY_NOTICES.md。
actor MemeSearchService {
    static let shared = MemeSearchService()
    static let repository = URL(string: "https://github.com/liyupi/memecub")!
    private let session: URLSession
    private let cache = NSCache<NSURL, NSData>()
    private let disk: MemeSearchCache
    private let transport: (@Sendable (URL, Int) async throws -> Data)?
    private var retentionDays = 3
    private var maintenance: Task<Void, Never>?
    private var prefetches: [String: Task<Void, Never>] = [:]
    private var requests: [String: UUID] = [:]
    private var cacheEpoch = UUID()

    init(session: URLSession? = nil, cacheDirectory: URL = LocalFiles.cache.appendingPathComponent("MemeSearch"),
         transport: (@Sendable (URL, Int) async throws -> Data)? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.httpMaximumConnectionsPerHost = 4
        self.session = session ?? URLSession(configuration: config)
        disk = MemeSearchCache(directory: cacheDirectory)
        self.transport = transport
        cache.totalCostLimit = 48 * 1_024 * 1_024
        cache.countLimit = 100
    }

    static func searchURL(query: String) throws -> URL {
        try MemeSourceAdapter.requestURL(source: .memecub, query: query, limit: 50)
    }

    func search(query: String, cacheDays: Int? = nil, sources: Set<MemeSource> = [.memecub]) async throws -> MemeSearchResponse {
        try await search(query: query, cacheDays: cacheDays, plan: MemeSearchPlan(sources: sources))
    }

    func search(query: String, cacheDays: Int? = nil, plan: MemeSearchPlan) async throws -> MemeSearchResponse {
        guard !plan.sources.isEmpty else { throw AppFailure.message("请至少选择一个表情搜索源") }
        if let cacheDays { retentionDays = max(1, min(365, cacheDays)) }
        _ = try Self.searchURL(query: query)
        let key = plan.selectionKey + "|" + MemeSearchCache.normalizedQuery(query)
        let request = UUID(), epoch = cacheEpoch
        requests[key] = request
        defer { if requests[key] == request { requests.removeValue(forKey: key) } }
        try? disk.prune(days: retentionDays)
        let outcomes = await withTaskGroup(of: SourceOutcome.self, returning: [SourceOutcome].self) { group in
            for source in plan.sources {
                group.addTask {
                    do {
                        let response = try await self.searchSource(query: query, source: source, plan: plan, key: key, request: request, epoch: epoch)
                        return SourceOutcome(source: source, result: .success(response))
                    } catch { return SourceOutcome(source: source, result: .failure(error)) }
                }
            }
            var values: [SourceOutcome] = []
            for await value in group { values.append(value) }
            return values
        }
        try Task.checkCancellation()
        guard requests[key] == request else { throw CancellationError() }
        let ordered = plan.sources.compactMap { source in outcomes.first { $0.source == source } }
        var successful: [(MemeSource, MemeSearchResponse)] = []
        var notes: [String] = []
        for outcome in ordered {
            switch outcome.result {
            case .success(let response):
                successful.append((outcome.source, response))
                var note = "\(outcome.source.title)：\(response.results.count) 条 · \(response.notice)"
                if let date = response.cachedAt { note += "（" + date.formatted(date: .numeric, time: .shortened) + "）" }
                notes.append(note)
            case .failure(let error): notes.append("\(outcome.source.title)：\(error.localizedDescription)")
            }
        }
        guard !successful.isEmpty else {
            if ordered.count == 1, case .failure(let error) = ordered[0].result { throw error }
            throw AppFailure.message(notes.joined(separator: "；"))
        }
        if plan.sources.count == 1, let response = successful.first?.1 { return response }
        // 按用户排序依次显示每源结果；重复原图保留排在前面的来源，不突破各源数量。
        var results: [MemeResult] = [], references: [String: MemeCacheReference] = [:]
        var seen = Set<URL>()
        for (_, response) in successful {
            for item in response.results {
                if seen.insert(item.url).inserted {
                    results.append(item)
                    if let reference = response.cacheReference { references[item.id] = reference }
                }
            }
        }
        return MemeSearchResponse(results: results, total: successful.reduce(0) { $0 + $1.1.total }, notice: notes.joined(separator: "；"), resultReferences: references)
    }

    private struct SourceOutcome: Sendable {
        let source: MemeSource
        let result: Result<MemeSearchResponse, Error>
    }

    private func searchSource(query: String, source: MemeSource, plan: MemeSearchPlan, key: String, request: UUID, epoch: UUID) async throws -> MemeSearchResponse {
        let limit = plan.limits[source] ?? 1
        let scope = plan.cacheScope(for: source)
        do {
            let url = try MemeSourceAdapter.requestURL(source: source, query: query, limit: limit)
            let data = try await fetch(url, maximumBytes: (source == .chinesebqb ? 8 : 2) * 1_024 * 1_024)
            try Task.checkCancellation()
            guard requests[key] == request else { throw CancellationError() }
            var response = try MemeSourceAdapter.decode(data, source: source, query: query, limit: limit)
            if epoch == cacheEpoch {
                do {
                    let reference = try disk.replace(query: query, response: response, scope: scope)
                    response.cacheReference = reference
                    response.notice = "已更新本地搜索结果"
                    prefetch(response.results, reference: reference)
                } catch { response.notice = "本次缓存保存失败：\(error.localizedDescription)" }
            }
            return response
        } catch {
            try Task.checkCancellation()
            guard requests[key] == request else { throw CancellationError() }
            // 各来源单独回退，不让其他来源的成功响应给旧缓存续期。
            if epoch == cacheEpoch, let saved = try? disk.lookup(query: query, days: retentionDays, scope: scope) {
                let items = saved.results.prefix(limit).map { item in
                    var result = item; result.source = source; return result
                }
                var response = MemeSearchResponse(results: items, total: saved.total, cacheReference: saved.cacheReference, cachedAt: saved.cachedAt)
                response.notice = error is MemeServiceFailure ? "接口超限，已显示本地缓存" : "联网失败，已显示本地缓存"
                return response
            }
            throw error
        }
    }

    func configureCache(days: Int, startMaintenance: Bool = false) {
        retentionDays = max(1, min(365, days))
        pruneCache()
        if startMaintenance, maintenance == nil {
            maintenance = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await self?.pruneCache()
                }
            }
        }
    }

    private func pruneCache() {
        try? disk.prune(days: retentionDays)
        cache.removeAllObjects()
    }

    func clearCache() throws {
        cacheEpoch = UUID()
        for task in prefetches.values { task.cancel() }
        prefetches.removeAll()
        cache.removeAllObjects()
        try disk.clear()
    }

    /// 停用功能时停止后台下载，保留磁盘缓存及用户的永久本地图库。
    func suspendRequests() {
        cacheEpoch = UUID()
        requests.removeAll()
        for task in prefetches.values { task.cancel() }
        prefetches.removeAll()
    }

    /// 供集成验证等待后台缓存完成，不阻塞正常搜索界面的展示。
    func finishPendingCacheWrites() async {
        let tasks = Array(prefetches.values)
        for task in tasks { await task.value }
    }

    /// 每个来源后台最多四路下载额度内结果的缩略图与原图，不阻塞展示；某张失败可在查看时重试。
    private func prefetch(_ results: [MemeResult], reference: MemeCacheReference) {
        prefetches[reference.queryKey]?.cancel()
        let urls = results.flatMap { [$0.thumbnail, $0.url] }.reduce(into: [URL]()) { if !$0.contains($1) { $0.append($1) } }
        prefetches[reference.queryKey] = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var iterator = urls.makeIterator()
                for _ in 0..<4 {
                    if let url = iterator.next() { group.addTask { _ = try? await self.media(url, reference: reference) } }
                }
                while await group.next() != nil {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let url = iterator.next() { group.addTask { _ = try? await self.media(url, reference: reference) } }
                }
            }
        }
    }

    /// 畸形条目单独跳过；整份响应格式变化则报错，不把服务故障伪装成“没有结果”。
    static func decode(_ data: Data) throws -> MemeSearchResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else { throw AppFailure.message("搜索服务返回了无法识别的数据，请稍后重试") }
        var seen = Set<URL>()
        let results = rows.prefix(50).compactMap { row -> MemeResult? in
            guard let url = secureURL(row["url"]), seen.insert(url).inserted else { return nil }
            let title = (row["title_zh"] as? String) ?? (row["title"] as? String) ?? "表情包"
            return MemeResult(title: title, url: url, thumbnail: secureURL(row["thumb_url"]) ?? url,
                              pageURL: secureURL(row["page_url"]), animated: row["kind"] as? String == "gif" || url.pathExtension.lowercased() == "gif",
                              attribution: row["attribution"] as? String)
        }
        if !rows.isEmpty, results.isEmpty { throw AppFailure.message("搜索结果没有可用的 HTTPS 图片地址") }
        return MemeSearchResponse(results: results, total: json["total"] as? Int ?? results.count)
    }

    private static func secureURL(_ value: Any?) -> URL? {
        guard let text = value as? String, let url = URL(string: text), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    func media(_ url: URL, reference: MemeCacheReference? = nil) async throws -> MemeMedia {
        try Task.checkCancellation()
        if let reference, let data = disk.media(url, reference: reference, days: retentionDays), let media = try? MemeMedia(data: data) { return media }
        // 搜索批次内以磁盘缓存为准；新批次不得复用旧 URL 的内存副本，确保同地址内容也能刷新。
        if reference == nil, let data = cache.object(forKey: url as NSURL) { return try MemeMedia(data: data as Data) }
        let data = try await fetch(url, maximumBytes: MemeMedia.maximumBytes)
        try Task.checkCancellation()
        let media = try MemeMedia(data: data)
        if let reference { try? disk.storeMedia(data, url: url, reference: reference, days: retentionDays) }
        else { cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count) }
        return media
    }

    /// 边下载边限制大小，防止不可信响应耗尽内存；取消任务会同时取消 URLSession 传输。
    private func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        if let transport { return try await transport(url, maximumBytes) }
        var request = URLRequest(url: url)
        request.setValue("MacTools/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { bytes.task.cancel(); throw AppFailure.message("网络响应无效") }
        guard response.url?.scheme == "https", (200...299).contains(response.statusCode) else {
            bytes.task.cancel()
            if response.statusCode == 429 { throw MemeServiceFailure.quotaExceeded }
            throw AppFailure.message("表情包服务暂不可用（HTTP \(response.statusCode)），请稍后重试")
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            bytes.task.cancel(); throw AppFailure.message("返回内容过大，已停止下载")
        }
        var data = Data()
        do {
            for try await byte in bytes {
                if data.count >= maximumBytes { throw AppFailure.message("返回内容过大，已停止下载") }
                data.append(byte)
            }
            try Task.checkCancellation()
        } catch { bytes.task.cancel(); throw error }
        return data
    }
}
