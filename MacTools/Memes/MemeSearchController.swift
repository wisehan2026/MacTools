import AppKit
import Combine

enum MemeFilter: String, CaseIterable, Identifiable {
    case all = "全部", still = "静图", animated = "动图"
    var id: String { rawValue }
}

/// 搜索、预览和复制各有独立任务；新查询不会被旧请求覆盖，快速悬停不会下载每张原图。
@MainActor
final class MemeSearchController: ObservableObject {
    @Published var query = ""
    @Published var filter = MemeFilter.all
    @Published private(set) var results: [MemeResult] = []
    @Published private(set) var loading = false
    @Published private(set) var searched = false
    @Published private(set) var error = ""
    @Published private(set) var status = ""
    @Published private(set) var cacheNotice = ""
    @Published private(set) var cacheReference: MemeCacheReference?
    @Published private(set) var resultReferences: [String: MemeCacheReference] = [:]
    @Published private(set) var preview: MemeResult?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewError = ""
    @Published private(set) var copying = false
    @Published private(set) var addingLocalID: String?
    @Published private(set) var localLibraryRevision = 0
    private var searchTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var copyTask: Task<Void, Never>?
    private var localAddTask: Task<Void, Never>?
    private var generation = UUID()
    private var copyGeneration = UUID()
    private var localAddGeneration = UUID()
    private let service: MemeSearchService
    private let localStore: LocalMemeStore
    private let settings: SettingsStore
    var visible: [MemeResult] {
        results.filter { filter == .all || ($0.animated ? filter == .animated : filter == .still) }
    }

    init(service: MemeSearchService = .shared, localStore: LocalMemeStore = .shared, settings: SettingsStore = .shared) {
        self.service = service; self.localStore = localStore; self.settings = settings
    }

    func search() {
        guard settings.isEnabled(.memes) else { close(); return }
        searchTask?.cancel()
        let token = UUID()
        generation = token
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []; error = ""; status = ""; cacheNotice = ""; cacheReference = nil; searched = false; loading = false
        clearPreview()
        resultReferences = [:]
        guard !text.isEmpty else { return }
        loading = true
        searchTask = Task {
            do {
                let response = try await service.search(query: text, cacheDays: settings.memeCacheDays, plan: settings.memeSearchPlan)
                guard !Task.isCancelled, generation == token else { return }
                results = settings.memeSearchPlan.orderedResults(response.results)
                cacheReference = response.cacheReference
                resultReferences = response.resultReferences
                cacheNotice = response.notice
                if let date = response.cachedAt { cacheNotice += " · 更新于 " + date.formatted(date: .abbreviated, time: .shortened) }
                searched = true
                status = "找到 \(results.count) 张 · 悬停预览，双击复制"
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                self.error = error.localizedDescription
            }
            if generation == token { loading = false }
        }
    }

    func hover(_ result: MemeResult) {
        guard settings.isEnabled(.memes) else { return }
        guard preview?.id != result.id else { return }
        previewTask?.cancel()
        preview = result; previewImage = nil; previewError = ""
        let reference = reference(for: result)
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let media = try await MemeMediaLoader.load(result, reference: reference, service: service, local: localStore)
                guard !Task.isCancelled, preview?.id == result.id else { return }
                guard let image = NSImage(data: media.data) else { throw AppFailure.message("无法显示此图片") }
                previewImage = image
            } catch {
                guard !Task.isCancelled, preview?.id == result.id else { return }
                previewError = error.localizedDescription
            }
        }
    }

    func clearPreview() {
        previewTask?.cancel(); preview = nil; previewImage = nil; previewError = ""
    }

    func copy(_ result: MemeResult) {
        guard settings.isEnabled(.memes) else { return }
        guard !copying else { return }
        let token = UUID()
        copyGeneration = token
        copying = true; status = result.localID == nil ? "正在下载并复制…" : "正在复制…"
        let reference = reference(for: result)
        copyTask = Task {
            do {
                let media = try await MemeMediaLoader.load(result, reference: reference, service: service, local: localStore)
                try Task.checkCancellation()
                guard copyGeneration == token else { return }
                status = try ClipboardStore.shared.copyMeme(media, title: result.title, source: result.sourceTitle)
            } catch {
                if !Task.isCancelled, copyGeneration == token { status = "复制失败：\(error.localizedDescription)" }
            }
            if copyGeneration == token { copying = false }
        }
    }

    /// 单次点击保存搜索原图，不经过剪贴板；切换查询或分类不丢弃已经发起的收藏。
    @discardableResult
    func addToLocal(_ result: MemeResult) -> Task<Void, Never>? {
        guard settings.isEnabled(.memes), result.localID == nil, addingLocalID == nil else { return nil }
        let token = UUID()
        localAddGeneration = token
        addingLocalID = result.id; status = "正在添加到本地…"
        let reference = reference(for: result)
        let task = Task {
            defer { if localAddGeneration == token { addingLocalID = nil } }
            do {
                let media = try await MemeMediaLoader.load(result, reference: reference, service: service, local: localStore)
                try Task.checkCancellation()
                guard localAddGeneration == token, settings.isEnabled(.memes) else { return }
                let added = try await localStore.addSearchResult(name: result.title, media: media)
                guard !Task.isCancelled, localAddGeneration == token else { return }
                localLibraryRevision += 1
                status = added.inserted ? "已添加到本地，可在“本地”分类查看和编辑" : "本地已存在“\(added.entry.name)”，无需重复添加"
            } catch {
                if !Task.isCancelled, localAddGeneration == token { status = "添加到本地失败：\(error.localizedDescription)" }
            }
        }
        localAddTask = task
        return task
    }

    /// 功能窗口被保留供再次唤起；关闭时仍需显式停止请求和动画，防止后台意外改写剪贴板。
    func close(cancelLocalAddition: Bool = true) {
        generation = UUID()
        copyGeneration = UUID()
        searchTask?.cancel(); copyTask?.cancel(); clearPreview()
        loading = false; copying = false
        if cancelLocalAddition {
            localAddGeneration = UUID(); localAddTask?.cancel(); localAddTask = nil; addingLocalID = nil
        }
    }

    func reference(for result: MemeResult) -> MemeCacheReference? { resultReferences[result.id] ?? cacheReference }

    func orderChanged() { results = settings.memeSearchPlan.orderedResults(results) }

    func sourcesChanged() {
        searchTask?.cancel(); generation = UUID(); loading = false
        results = []; resultReferences = [:]; cacheReference = nil; searched = false; error = ""; cacheNotice = ""
        clearPreview()
        status = "搜索来源已更改，按回车重新搜索"
    }
}
