import SwiftUI

struct StorageView: View {
    @ObservedObject private var library = MediaLibrary.shared
    @State private var confirmation = false
    @State private var deleting: MediaItem?
    private var mediaBytes: Int64 { library.items.reduce(0) { $0 + $1.bytes } }
    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .storage)
            HStack(spacing: 36) {
                metric("剪贴板", bytes: library.clipboardBytes)
                metric("截图", bytes: library.items.filter { $0.kind == .screenshot }.reduce(0) { $0 + $1.bytes })
                metric("录像", bytes: library.items.filter { $0.kind == .recording }.reduce(0) { $0 + $1.bytes })
                metric("临时缓存", bytes: library.cacheBytes)
                Spacer()
            }.padding(.horizontal, 24).padding(.bottom, 22)
            HStack {
                Button("清理非收藏历史…") { confirmation = true }
                Button("清理临时缓存") { Task { await library.clearCache() } }
                Spacer()
                Button { Task { await library.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }.padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            if library.items.isEmpty {
                EmptyState(icon: "externaldrive", title: "还没有导出文件", detail: "保存的截图和录像会显示在这里，并持续保留，直到你手动清理。")
            } else {
                List(library.items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.kind == .screenshot ? "photo" : "film").foregroundStyle(.teal).frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.url.lastPathComponent).lineLimit(1)
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formattedBytes(item.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button("查看") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Button { deleting = item } label: { Image(systemName: "trash") }.help("移至废纸篓")
                    }.padding(.vertical, 6)
                }.listStyle(.inset)
            }
            Divider()
            HStack {
                Text(library.message.isEmpty ? "仅管理 MacTools 生成的内容；导出文件不会自动过期。" : library.message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("共 \(formattedBytes(library.clipboardBytes + mediaBytes + library.cacheBytes))").font(.caption.monospacedDigit())
            }.padding(14)
        }.task { await library.refresh() }
            .alert("清理所有非收藏历史？", isPresented: $confirmation) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) { ClipboardStore.shared.clearUnpinned(); Task { await library.refresh() } }
            } message: { Text("这会删除对应的文字与图片历史，收藏会保留。此操作无法撤销。") }
            .alert("移至废纸篓？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("移至废纸篓", role: .destructive) { if let item = deleting { library.trash(item) }; deleting = nil }
            } message: { Text(deleting?.url.lastPathComponent ?? "") }
    }
    private func metric(_ title: String, bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).foregroundStyle(.secondary).font(.callout); Text(formattedBytes(bytes)).font(.title2.weight(.semibold)) }
    }
}
