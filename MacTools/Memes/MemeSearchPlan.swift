import Foundation

/// 数量决定缓存分区，排序只影响展示；调整顺序仍可读取同一份有效缓存。
struct MemeSearchPlan: Equatable, Sendable {
    let sources: [MemeSource]
    let limits: [MemeSource: Int]
    var total: Int { limits.values.reduce(0, +) }

    init(sources: Set<MemeSource>, order: [MemeSource] = MemeSource.allCases, counts: [MemeSource: Int]? = nil) {
        var seen = Set<MemeSource>()
        self.sources = (order + MemeSource.allCases).filter { sources.contains($0) && seen.insert($0).inserted }
        let average = MemeSource.limit(for: sources)
        limits = Dictionary(uniqueKeysWithValues: sources.map { ($0, max(1, min(50, counts?[$0] ?? average))) })
    }

    var selectionKey: String {
        MemeSource.ordered(Set(sources)).map { "\($0.rawValue)=\(limits[$0] ?? 0)" }.joined(separator: ",")
    }

    func cacheScope(for source: MemeSource) -> String? {
        let selected = Set(sources)
        if limits.values.allSatisfy({ $0 == MemeSource.limit(for: selected) }) {
            return MemeSource.cacheScope(source: source, selection: selected)
        }
        return "sources-v2|\(selectionKey)|\(source.rawValue)"
    }

    func orderedResults(_ results: [MemeResult]) -> [MemeResult] {
        sources.flatMap { source in results.filter { ($0.source ?? .memecub) == source } }
    }
}
