import Foundation
import CryptoKit

struct MemeCacheReference: Codable, Sendable, Equatable {
    let queryKey: String
    let generation: UUID
    let refreshedAt: Date
}

private struct MemeCacheRecord: Codable {
    let reference: MemeCacheReference
    let results: [MemeResult]
    let total: Int
}

/// 由搜索服务 actor 串行访问。索引原子替换，图片按刷新批次隔离，旧下载不能覆盖新结果。
struct MemeSearchCache: Sendable {
    let directory: URL
    private var queries: URL { directory.appendingPathComponent("Queries", isDirectory: true) }
    private var images: URL { directory.appendingPathComponent("Images", isDirectory: true) }

    static func normalizedQuery(_ query: String) -> String {
        query.precomposedStringWithCanonicalMapping.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }

    private static func key(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func valid(_ reference: MemeCacheReference, days: Int, now: Date) -> Bool {
        // 过期边界为最近成功刷新后 N × 24 小时；回退读取不会刷新时间戳。
        now.timeIntervalSince(reference.refreshedAt) < Double(max(1, min(365, days))) * 86400
    }

    private static func queryKey(_ query: String, scope: String?) -> String {
        key((scope.map { $0 + "\u{0}" } ?? "") + normalizedQuery(query))
    }

    func replace(query: String, response: MemeSearchResponse, now: Date = Date(), scope: String? = nil) throws -> MemeCacheReference {
        let key = Self.queryKey(query, scope: scope)
        let file = queries.appendingPathComponent(key + ".json")
        let previous = try? read(file)
        let reference = MemeCacheReference(queryKey: key, generation: UUID(), refreshedAt: now)
        let record = MemeCacheRecord(reference: reference, results: Array(response.results.prefix(50)), total: response.total)
        try LocalFiles.ensure(queries)
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
        if let previous { try? FileManager.default.removeItem(at: imageDirectory(previous.reference)) }
        return reference
    }

    func lookup(query: String, days: Int, now: Date = Date(), scope: String? = nil) throws -> MemeSearchResponse? {
        let file = queries.appendingPathComponent(Self.queryKey(query, scope: scope) + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let record = try read(file)
        guard Self.valid(record.reference, days: days, now: now) else {
            try remove(record, file: file)
            return nil
        }
        return MemeSearchResponse(results: record.results, total: record.total, cacheReference: record.reference, cachedAt: record.reference.refreshedAt)
    }

    func isCurrent(_ reference: MemeCacheReference, days: Int, now: Date = Date()) -> Bool {
        guard Self.valid(reference, days: days, now: now),
              let record = try? read(queries.appendingPathComponent(reference.queryKey + ".json")) else { return false }
        return record.reference == reference
    }

    func media(_ url: URL, reference: MemeCacheReference, days: Int, now: Date = Date()) -> Data? {
        guard isCurrent(reference, days: days, now: now) else { return nil }
        return try? Data(contentsOf: imageFile(url, reference: reference))
    }

    func storeMedia(_ data: Data, url: URL, reference: MemeCacheReference, days: Int, now: Date = Date()) throws {
        // 清理、替换或过期后完成的下载直接丢弃，不能重新创建已删除的缓存。
        guard isCurrent(reference, days: days, now: now) else { return }
        try LocalFiles.ensure(imageDirectory(reference))
        try data.write(to: imageFile(url, reference: reference), options: .atomic)
    }

    func prune(days: Int, now: Date = Date()) throws {
        var live = Set<String>()
        if FileManager.default.fileExists(atPath: queries.path) {
            for file in try FileManager.default.contentsOfDirectory(at: queries, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                if let record = try? read(file), Self.valid(record.reference, days: days, now: now) {
                    live.insert(record.reference.generation.uuidString)
                } else { try FileManager.default.removeItem(at: file) }
            }
        }
        // 同时移除过期图片，以及异常退出、损坏索引留下的孤立图片目录。
        if FileManager.default.fileExists(atPath: images.path) {
            for folder in try FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil) where !live.contains(folder.lastPathComponent) {
                try FileManager.default.removeItem(at: folder)
            }
        }
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func read(_ file: URL) throws -> MemeCacheRecord { try JSONDecoder().decode(MemeCacheRecord.self, from: Data(contentsOf: file)) }
    private func imageDirectory(_ reference: MemeCacheReference) -> URL { images.appendingPathComponent(reference.generation.uuidString, isDirectory: true) }
    private func imageFile(_ url: URL, reference: MemeCacheReference) -> URL { imageDirectory(reference).appendingPathComponent(Self.key(url.absoluteString)) }
    private func remove(_ record: MemeCacheRecord, file: URL) throws {
        try FileManager.default.removeItem(at: file)
        let folder = imageDirectory(record.reference)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
}
