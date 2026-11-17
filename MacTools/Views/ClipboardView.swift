import SwiftUI

struct ClipboardView: View {
    @ObservedObject var store = ClipboardStore.shared
    @State private var query = ""
    @State private var filter = 0
    @State private var selection: UUID?
    @State private var deleting: ClipboardEntry?
    private var filtered: [ClipboardEntry] {
        store.entries.filter {
            (filter == 0 || (filter == 1 && $0.kind == .text) || (filter == 2 && $0.kind == .image) || (filter == 3 && $0.favorite) || (filter == 4 && $0.kind == .meme)) &&
            (query.isEmpty || $0.title.localizedStandardContains(query) || $0.source.localizedStandardContains(query))
        }
    }
    private var days: [String] { Array(Set(filtered.map { LocalFiles.day($0.createdAt) })).sorted(by: >) }
    private var selected: ClipboardEntry? { store.entries.first { $0.id == selection } }
    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .clipboard)
            HStack {
                TextField("搜索文字或来源应用", text: $query).textFieldStyle(.roundedBorder)
                Picker("类型", selection: $filter) {
                    Text("全部").tag(0); Text("文字").tag(1); Text("图片").tag(2); Text("收藏").tag(3); Text("表情包").tag(4)
                }.labelsHidden().frame(width: 120)
                Toggle("暂停记录", isOn: $store.paused).toggleStyle(.switch).controlSize(.small)
            }.padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            HSplitView {
                if filtered.isEmpty {
                    EmptyState(icon: "clipboard", title: "还没有历史记录", detail: "使用 ⌘C 复制文字或图片后，它们会出现在这里。")
                        .frame(minWidth: 300, idealWidth: 350)
                } else {
                    List(selection: $selection) {
                        ForEach(days, id: \.self) { day in
                            Section(day) {
                                ForEach(filtered.filter { LocalFiles.day($0.createdAt) == day }) { entry in
                                    HStack(spacing: 10) {
                                        Image(systemName: entry.icon).foregroundStyle(.teal).frame(width: 22)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(entry.title).lineLimit(2)
                                            Text(entry.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 2)
                                        if entry.favorite { Image(systemName: "star.fill").foregroundStyle(.orange).font(.caption) }
                                    }.padding(.vertical, 5).tag(entry.id)
                                    .contextMenu {
                                        Button("复制") { store.copy(entry) }
                                        Button(entry.favorite ? "取消收藏" : "收藏") { store.toggleFavorite(entry) }
                                        Button("删除", role: .destructive) { deleting = entry }
                                    }
                                }
                            }
                        }
                    }.listStyle(.sidebar).frame(minWidth: 300, idealWidth: 350)
                }
                VStack(spacing: 16) {
                    if let entry = selected {
                        HStack {
                            Text(entry.kind == .text ? "文字预览" : (entry.kind == .meme ? "表情包预览" : "图片预览")).font(.headline)
                            Spacer()
                            Button { store.toggleFavorite(entry) } label: { Image(systemName: entry.favorite ? "star.fill" : "star") }.help("收藏后不会自动过期")
                            Button(role: .destructive) { deleting = entry } label: { Image(systemName: "trash") }
                        }
                        if let text = entry.text {
                            ScrollView { Text(text).frame(maxWidth: .infinity, alignment: .topLeading).textSelection(.enabled).padding(4) }
                        } else if let url = store.imageURL(entry), let image = NSImage(contentsOf: url) {
                            AnimatedImage(image: image).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        Spacer(minLength: 0)
                        Text("\(entry.source) · \(formattedBytes(entry.bytes))").font(.caption).foregroundStyle(.secondary)
                        Button("复制内容  ⌘C") { store.copy(entry) }.buttonStyle(.borderedProminent).tint(.teal).keyboardShortcut("c", modifiers: .command)
                    } else {
                        EmptyState(icon: "rectangle.on.rectangle", title: "选择一条记录", detail: "按 ⌘C 复制，再回到原应用按 ⌘V 粘贴。")
                    }
                }.padding(22).frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text(store.message ?? "仅保存在本机 · 默认保留今天及前两天").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Text("\(store.entries.count) 条").font(.caption.monospacedDigit())
            }.padding(12)
        }.alert("删除此记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) { if let entry = deleting { store.delete(entry) }; deleting = nil }
        } message: { Text("只删除 MacTools 中的历史记录，当前系统剪贴板不受影响。") }
    }
}
