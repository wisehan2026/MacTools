import AppKit
import Combine
import Quartz

/// 全局模式查询 Spotlight 索引，指定目录模式直接枚举文件；界面只绑定查询状态和结果。
/// Quick Look 的旧式代理协议通过 @preconcurrency 接入，状态仍统一在主线程读写。
@MainActor
final class FileSearchController: NSObject, ObservableObject, @preconcurrency QLPreviewPanelDataSource {
    @Published var text = ""
    @Published var kind: FileKind = .all
    @Published var directory: URL?
    @Published var includeHidden = false
    @Published var results: [FileResult] = []
    @Published var searching = false
    @Published var message = "全局搜索使用 Spotlight 索引；指定目录会直接扫描。"
    @Published var selection: String?
    private var query: NSMetadataQuery?
    private var searchTask: Task<Void, Never>?
    // 每轮查询使用独立标记，防止旧异步任务稍后返回并覆盖用户最新输入的结果。
    private var generation = UUID()
    private var previewURL: URL?

    // 类型筛选作用于已获取的结果，切换分类无需重新扫描目录。
    var visible: [FileResult] { results.filter { kind == .all || $0.kind == kind } }
    var selected: FileResult? { results.first { $0.id == selection } }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "搜索此目录"
        if panel.runModal() == .OK { directory = panel.url; search() }
    }

    /// 输入或范围改变时取消上一轮工作，再为当前关键词启动对应的搜索方式。
    func search() {
        guard SettingsStore.shared.isEnabled(.search) else { close(); return }
        searchTask?.cancel()
        query?.stop(); query = nil
        NotificationCenter.default.removeObserver(self)
        generation = UUID()
        let token = generation
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { results = []; searching = false; return }
        searching = true; message = "正在搜索…"
        if let directory {
            let hidden = includeHidden
            searchTask = Task {
                // 对目录扫描做短暂防抖，连续输入时不为每个字符立即遍历文件系统。
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                // 将关键词和范围作为本轮快照传入后台，只返回结果，不从后台修改 @Published。
                let worker = Task.detached(priority: .userInitiated) { () -> ([FileResult], Int) in
                    var found: [FileResult] = []
                    var errors = 0
                    let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
                    let options: FileManager.DirectoryEnumerationOptions = hidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
                    let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: options) { _, _ in errors += 1; return true }
                    while !Task.isCancelled, let url = enumerator?.nextObject() as? URL {
                        guard url.lastPathComponent.localizedStandardContains(keyword) else { continue }
                        let values = try? url.resourceValues(forKeys: Set(keys))
                        found.append(FileResult(url: url, directory: values?.isDirectory ?? false, bytes: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate))
                        // 限制返回规模，避免宽泛关键词让列表和内存持续增长。
                        if found.count >= 10_000 { break }
                    }
                    return (found, errors)
                }
                // detached 任务不会自动继承父任务取消，需要显式把取消信号转发给枚举循环。
                let (found, errors) = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, generation == token else { return }
                results = found.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
                searching = false
                message = "找到 \(found.count) 项" + (found.count >= 10_000 ? "，请缩小搜索范围" : "") + (errors > 0 ? "；\(errors) 处位置不可访问" : "")
            }
        } else {
            // 全局模式只依赖系统索引，不遍历整个磁盘；未索引或无权限的位置可能没有结果。
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryLocalComputerScope]
            query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, keyword)
            query.notificationBatchingInterval = 0.3
            NotificationCenter.default.addObserver(self, selector: #selector(updated(_:)), name: .NSMetadataQueryDidFinishGathering, object: query)
            NotificationCenter.default.addObserver(self, selector: #selector(updated(_:)), name: .NSMetadataQueryDidUpdate, object: query)
            self.query = query
            if !query.start() { searching = false; message = "Spotlight 索引不可用，请选择指定目录搜索" }
        }
    }

    /// 功能停用或窗口关闭时停止索引监听、磁盘枚举与预览，保留当前搜索条件。
    func close() {
        generation = UUID()
        searchTask?.cancel(); searchTask = nil
        query?.stop(); query = nil
        NotificationCenter.default.removeObserver(self)
        searching = false
        if previewURL != nil { QLPreviewPanel.shared()?.orderOut(nil); previewURL = nil }
    }

    @objc private func updated(_ notification: Notification) {
        guard let query, notification.object as AnyObject? === query else { return }
        // 读取本次结果时暂缓实时更新，避免遍历期间结果集合发生变化；结束后继续监听更新。
        query.disableUpdates()
        defer { query.enableUpdates() }
        results = query.results.prefix(10_000).compactMap { result in
            guard let item = result as? NSMetadataItem, let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
            let url = URL(fileURLWithPath: path)
            if !includeHidden && url.pathComponents.contains(where: { $0.hasPrefix(".") }) { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return FileResult(url: url, directory: values?.isDirectory ?? false, bytes: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate)
        }.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        searching = false
        message = "找到 \(results.count) 项 · 全局结果限于 Spotlight 已索引且有权访问的文件"
    }

    func open() { if let selected { NSWorkspace.shared.open(selected.url) } }
    func reveal() { if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected.url]) } }
    /// 固定本次预览 URL，避免用户随后改变列表选择时，预览数据源悄悄指向另一文件。
    func preview() {
        guard let selected else { return }
        previewURL = selected.url
        let panel = QLPreviewPanel.shared()
        panel?.dataSource = self; panel?.reloadData(); panel?.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewURL as NSURL? }
}
