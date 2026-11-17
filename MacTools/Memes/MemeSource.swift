import Foundation

/// 来源 ID 用于设置和缓存分区，展示名称可调整，持久化标识保持稳定。
enum MemeSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case memecub, xiao, ruseo, chinesebqb, pdan
    var id: String { rawValue }
    var title: String {
        switch self {
        case .memecub: "memecub"
        case .xiao: "慕名表情"
        case .ruseo: "澄曜搜狗表情"
        case .chinesebqb: "ChineseBQB"
        case .pdan: "皮蛋表情包"
        }
    }
    var detail: String {
        switch self {
        case .memecub: "中文与英文 · 匿名每日 20 次"
        case .xiao: "中文表情 API · 无需密钥"
        case .ruseo: "搜狗表情聚合 API · 无需密钥"
        case .chinesebqb: "开源表情库 · 按名称与分类检索"
        case .pdan: "公开网页搜索 · 热梗与 GIF"
        }
    }
    var website: URL {
        let address: String
        switch self {
        case .memecub: address = "https://memecub.com"
        case .xiao: address = "https://xiaoapi.cn/detail/10"
        case .ruseo: address = "https://api.ruseo.cn/api-doc/sogou_bqb"
        case .chinesebqb: address = "https://github.com/zhaoolee/ChineseBQB"
        case .pdan: address = "https://pdan.com.cn"
        }
        return URL(string: address)!
    }
    static func ordered(_ sources: Set<Self>) -> [Self] { allCases.filter { sources.contains($0) } }
    static func limit(for sources: Set<Self>) -> Int { sources.isEmpty ? 0 : 50 / sources.count }
    static func selectionKey(_ sources: Set<Self>) -> String { ordered(sources).map(\.rawValue).joined(separator: ",") }
    static func cacheScope(source: Self, selection: Set<Self>) -> String? {
        // 仅 memecub 时沿用旧版缓存，其他组合按来源集合及每源额度独立存放。
        if selection == [.memecub] { return nil }
        return "sources-v1|\(selectionKey(selection))|\(limit(for: selection))|\(source.rawValue)"
    }
}

/// 只解析公开的 JSON/HTML，不加载脚本、外部实体或远程可执行代码。
enum MemeSourceAdapter {
    static func requestURL(source: MemeSource, query: String, limit: Int) throws -> URL {
        let text = MemeSearchCache.normalizedQuery(query)
        guard !text.isEmpty, text.count <= 100 else { throw AppFailure.message("请输入 1～100 个字的关键词") }
        let address: String
        let parameters: [(String, String)]
        switch source {
        case .memecub:
            address = "https://memecub.com/api/v1/search"; parameters = [("q", text), ("limit", "\(limit)")]
        case .xiao:
            address = "https://xiaoapi.cn/v1/meme.php"; parameters = [("msg", text), ("num", "\(limit)"), ("page", "1")]
        case .ruseo:
            address = "https://api.ruseo.cn/api/sogou_bqb"; parameters = [("words", text), ("page", "1")]
        case .chinesebqb:
            address = "https://zhaoolee.com/ChineseBQB/catalog/search.json"; parameters = []
        case .pdan:
            address = "https://pdan.com.cn/"; parameters = [("s", text)]
        }
        var components = URLComponents(string: address)!
        if !parameters.isEmpty { components.queryItems = parameters.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = components.url else { throw AppFailure.message("无法创建搜索请求") }
        return url
    }

    static func decode(_ data: Data, source: MemeSource, query: String, limit: Int) throws -> MemeSearchResponse {
        if source == .memecub {
            let parsed = try MemeSearchService.decode(data)
            return MemeSearchResponse(results: parsed.results.prefix(limit).map { item in
                var result = item; result.source = source; return result
            }, total: parsed.total)
        }
        var results: [MemeResult] = []
        if source == .chinesebqb {
            results = try parseCatalog(data, query: query)
        } else if source == .pdan {
            results = try parseHTML(data, source: source, query: query)
        } else {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid(source) }
            if source == .xiao {
                guard root["code"] as? Int == 200, let rows = root["data"] as? [[String: Any]] else { throw invalid(source) }
                results = rows.compactMap { makeResult($0["img_url"] as? String, title: query, source: source) }
                if !rows.isEmpty, results.isEmpty { throw invalid(source) }
            } else {
                guard root["code"] as? Int == 0, let payload = root["data"] as? [String: Any],
                      payload["code"] as? Int == 200, let rows = payload["res"] as? [String] else { throw invalid(source) }
                results = rows.compactMap { makeResult($0, title: query, source: source) }
                if !rows.isEmpty, results.isEmpty { throw invalid(source) }
            }
        }
        var seen = Set<URL>()
        let unique = results.filter { seen.insert($0.url).inserted }
        return MemeSearchResponse(results: Array(unique.prefix(limit)), total: unique.count)
    }

    private static func parseCatalog(_ data: Data, query: String) throws -> [MemeResult] {
        let source = MemeSource.chinesebqb
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.isEmpty || rows.contains(where: { $0["src"] is String && $0["label"] is String }) else { throw invalid(source) }
        let base = URL(string: "https://zhaoolee.com/ChineseBQB/")!
        let words = MemeSearchCache.normalizedQuery(query).split(whereSeparator: \.isWhitespace).map(String.init)
        // 公开目录只包含名称与分类；在本机匹配关键词，再按所选来源数截取结果写入现有缓存。
        return rows.compactMap { row in
            let searchable = ["label", "name", "categoryTitle", "folder"].compactMap { row[$0] as? String }.joined(separator: " ")
            guard words.allSatisfy({ searchable.localizedCaseInsensitiveContains($0) }), let path = row["src"] as? String,
                  let url = secureURL(URL(string: path, relativeTo: base)?.absoluteURL.absoluteString) else { return nil }
            let thumb = (row["thumb"] as? String).flatMap { secureURL(URL(string: $0, relativeTo: base)?.absoluteURL.absoluteString) } ?? url
            let page = (row["categoryUrl"] as? String).flatMap { secureURL(URL(string: $0, relativeTo: base)?.absoluteURL.absoluteString) } ?? source.website
            return MemeResult(title: row["label"] as? String ?? query, url: url, thumbnail: thumb, pageURL: page,
                              animated: row["animated"] as? Bool ?? (url.pathExtension.lowercased() == "gif"), attribution: nil, source: source)
        }
    }

    private static func parseHTML(_ data: Data, source: MemeSource, query: String) throws -> [MemeResult] {
        let document = try XMLDocument(data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        let container = "//*[@id='postlist']"
        guard !(try document.nodes(forXPath: container)).isEmpty else { throw invalid(source) }
        let path = container + "//a[contains(@class,'imageLink')]"
        return try document.nodes(forXPath: path).compactMap { node in
            guard let anchor = node as? XMLElement,
                  let img = try anchor.nodes(forXPath: ".//img").first as? XMLElement else { return nil }
            let rawURL = img.attribute(forName: "src")?.stringValue
            let title = img.attribute(forName: "alt")?.stringValue ?? query
            guard var result = makeResult(rawURL, title: title, source: source, page: anchor.attribute(forName: "href")?.stringValue) else { return nil }
            // 皮蛋列表的缩略参数会缩小 GIF，原图预览与复制使用同站已验证的无缩略参数地址。
            if source == .pdan, result.url.host == "pinoss.com", var parts = URLComponents(url: result.url, resolvingAgainstBaseURL: false),
               parts.percentEncodedQuery?.hasPrefix("imageMogr2/") == true {
                parts.query = nil
                if let original = parts.url { result.url = original }
            }
            return result
        }
    }

    private static func makeResult(_ address: String?, title: String, source: MemeSource, page: String? = nil) -> MemeResult? {
        guard let url = secureURL(address) else { return nil }
        return MemeResult(title: title.trimmingCharacters(in: .whitespacesAndNewlines), url: url, thumbnail: url,
                          pageURL: secureURL(page) ?? source.website, animated: url.pathExtension.lowercased() == "gif", attribution: nil, source: source)
    }
    private static func secureURL(_ address: String?) -> URL? {
        guard let address, let url = URL(string: address.hasPrefix("//") ? "https:" + address : address),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    private static func invalid(_ source: MemeSource) -> AppFailure { .message("\(source.title)暂不可用或返回格式变化") }
}
