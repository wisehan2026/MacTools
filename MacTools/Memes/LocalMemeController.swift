import AppKit
import Combine
import UniformTypeIdentifiers

/// 本地图库的导入、编辑和检索状态；文件访问统一通过 LocalMemeStore。
@MainActor
final class LocalMemeController: ObservableObject {
    @Published var query = ""
    @Published var filter = MemeFilter.all
    @Published private(set) var results: [MemeResult] = []
    @Published private(set) var message = ""
    @Published private(set) var loading = false
    @Published var editing = false
    @Published var draftName = ""
    @Published private(set) var draftImage: NSImage?
    @Published private(set) var editorError = ""
    @Published private(set) var working = false
    private var draftID: UUID?
    private var draftMedia: MemeMedia?
    private var editorGeneration = UUID()
    private let store: LocalMemeStore
    var visible: [MemeResult] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return results.filter { item in
            words.allSatisfy { item.title.localizedCaseInsensitiveContains($0) }
                && (filter == .all || (item.animated ? filter == .animated : filter == .still))
        }
    }
    var isNew: Bool { draftID == nil }
    var canSave: Bool { !working && !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftName.count <= 100 && (draftID != nil || draftMedia != nil) }

    init(store: LocalMemeStore = .shared) { self.store = store }

    func refresh() async {
        loading = true
        defer { loading = false }
        do { results = try await store.results() }
        catch { message = "读取本地表情失败：\(error.localizedDescription)" }
    }

    func beginImport() {
        resetEditor()
        editing = true
        chooseImage()
    }

    func beginEdit(_ result: MemeResult) {
        guard let id = result.localID else { return }
        resetEditor()
        draftID = id; draftName = result.title; editing = true; working = true
        let token = editorGeneration
        Task {
            defer { if token == editorGeneration { working = false } }
            do {
                let media = try await store.media(id: id)
                guard token == editorGeneration else { return }
                draftImage = NSImage(data: media.data)
            } catch { if token == editorGeneration { editorError = error.localizedDescription } }
        }
    }

    func chooseImage() {
        guard !working else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "选择表情"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true; editorError = ""
        let token = editorGeneration
        Task {
            defer { if token == editorGeneration { working = false } }
            do {
                let media = try await Task.detached(priority: .userInitiated) { try LocalMemeStore.readImport(url) }.value
                guard token == editorGeneration else { return }
                draftMedia = media; draftImage = NSImage(data: media.data)
                if draftName.isEmpty { draftName = String(url.deletingPathExtension().lastPathComponent.prefix(100)) }
            } catch { if token == editorGeneration { editorError = error.localizedDescription } }
        }
    }

    func save() {
        guard canSave else { return }
        working = true; editorError = ""
        let id = draftID, name = draftName, media = draftMedia
        Task {
            defer { working = false }
            do {
                try await store.save(id: id, name: name, media: media)
                await refresh()
                message = id == nil ? "已添加到本地表情，永久保留" : "本地表情已更新"
                editing = false
            } catch { editorError = error.localizedDescription }
        }
    }

    func delete(_ result: MemeResult) {
        guard let id = result.localID else { return }
        Task {
            do { try await store.delete(id: id); message = "本地表情已删除" }
            catch { message = "删除失败：\(error.localizedDescription)" }
            await refresh()
        }
    }

    func resetEditor() {
        editorGeneration = UUID(); draftID = nil; draftMedia = nil; draftImage = nil; draftName = ""; editorError = ""; working = false
    }
}
