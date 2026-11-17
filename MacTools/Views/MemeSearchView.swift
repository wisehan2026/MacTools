import SwiftUI

struct MemeSearchView: View {
    @StateObject private var controller = MemeSearchController()
    @StateObject private var library = LocalMemeController()
    @ObservedObject private var settings = SettingsStore.shared
    @State private var local = false
    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .memes)
            Picker("表情分类", selection: $local) { Text("搜索").tag(false); Text("本地").tag(true) }
                .pickerStyle(.segmented).frame(width: 220).padding(.bottom, 16)
            if local { LocalMemeView(library: library) }
            else { OnlineMemeSearchView(controller: controller) }
        }.onChange(of: settings.memeSearchPlan) { old, new in
            if old.limits == new.limits { controller.orderChanged() }
            else { controller.sourcesChanged() }
        }
        .onChange(of: controller.localLibraryRevision) { _, _ in Task { await library.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == Feature.memes.rawValue { controller.close() }
        }
    }
}

private struct OnlineMemeSearchView: View {
    @ObservedObject var controller: MemeSearchController
    @ObservedObject private var settings = SettingsStore.shared
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("输入关键词，如：无语、开心、熊猫头", text: $controller.query)
                    .textFieldStyle(.roundedBorder).focused($searchFocused).onSubmit { controller.search() }
                    .accessibilityLabel("表情包关键词")
                Button("搜索") { controller.search() }.buttonStyle(.borderedProminent)
                    .disabled(controller.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Picker("图片类型", selection: $controller.filter) {
                    ForEach(MemeFilter.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 100)
            }.padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            HSplitView {
                results.frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                MemePreviewView(controller: controller).frame(minWidth: 240, idealWidth: 310, maxWidth: 400, maxHeight: .infinity).padding(20)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text(controller.status.isEmpty ? "鼠标悬停查看大图 · 双击复制 · 回到聊天窗口按 ⌘V 粘贴" : controller.status)
                    .font(.callout).textSelection(.enabled)
                if !controller.cacheNotice.isEmpty {
                    Text(controller.cacheNotice).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled).help(controller.cacheNotice)
                }
                HStack {
                    Text("来源：" + settings.memeSearchPlan.sources.map(\.title).joined(separator: "、")).lineLimit(1)
                    Spacer()
                    Button("设置…") { WindowCoordinator.shared.show(.settings) }.help("在设置的「表情包」分类中选择来源与缓存天数")
                }.font(.caption)
            }.padding(14)
        }
        .onAppear { searchFocused = true }
        .onDisappear { controller.close(cancelLocalAddition: false) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == Feature.memes.rawValue { searchFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == Feature.memes.rawValue { controller.close() }
        }
        .onChange(of: controller.filter) { _, _ in controller.clearPreview() }
    }

    @ViewBuilder private var results: some View {
        if controller.loading {
            VStack(spacing: 16) { ProgressView(); Text("正在搜索表情包…").foregroundStyle(.secondary) }
        } else if !controller.error.isEmpty {
            VStack {
                EmptyState(icon: "wifi.exclamationmark", title: "搜索暂时不可用", detail: controller.error)
                Button("重试") { controller.search() }.padding(.bottom, 24)
            }
        } else if controller.visible.isEmpty {
            EmptyState(icon: "face.smiling", title: controller.searched ? "没有匹配的表情包" : "搜一句话，找到合适的表情",
                       detail: controller.searched ? "试试更短的关键词，或将图片类型切换为“全部”。" : "输入关键词后按回车搜索，支持静态图片和 GIF 动图。")
        } else {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 65), spacing: 8), count: 5), spacing: 8) {
                    ForEach(controller.visible) { result in
                        MemeResultCell(result: result, cacheReference: controller.reference(for: result), highlighted: controller.preview?.id == result.id)
                            .contentShape(Rectangle())
                            .onHover { inside in if inside { controller.hover(result) } }
                            .onTapGesture(count: 2) { controller.copy(result) }
                            .contextMenu {
                                Button("复制表情包") { controller.copy(result) }.disabled(controller.copying)
                                Button("添加到本地") { controller.addToLocal(result) }.disabled(controller.addingLocalID != nil)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(result.title + (result.animated ? "，动图" : "，静图"))
                            .accessibilityAction(named: "复制表情包") { controller.copy(result) }
                            .accessibilityAction(named: "添加到本地") { controller.addToLocal(result) }
                    }
                }.padding(12)
            }
        }
    }

}

struct MemePreviewView: View {
    @ObservedObject var controller: MemeSearchController
    @ViewBuilder var body: some View {
        if let result = controller.preview {
            VStack(spacing: 14) {
                HStack {
                    Text("大图预览").font(.headline)
                    Spacer()
                    Text(result.animated ? "动图" : "静图").font(.caption).foregroundStyle(.secondary)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4))
                    if let image = controller.previewImage {
                        AnimatedImage(image: image).padding(8)
                    } else if !controller.previewError.isEmpty {
                        Text(controller.previewError).font(.callout).foregroundStyle(.secondary).padding()
                    } else { ProgressView() }
                }.frame(minHeight: 180, maxHeight: .infinity)
                    .onTapGesture(count: 2) { controller.copy(result) }
                Text(result.title).font(.headline).lineLimit(3).textSelection(.enabled)
                Text(result.sourceTitle).font(.caption).foregroundStyle(.secondary)
                if let credit = result.attribution, !credit.isEmpty {
                    Text(credit).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
                }
                if let page = result.pageURL { Link("查看原始出处", destination: page).font(.caption) }
                Button(controller.copying ? "正在复制…" : "复制表情包") { controller.copy(result) }
                    .buttonStyle(.borderedProminent).disabled(controller.copying)
                if result.localID == nil {
                    Button(controller.addingLocalID == result.id ? "正在添加…" : "添加到本地") { controller.addToLocal(result) }
                        .disabled(controller.addingLocalID != nil).help("保存原图到本地表情，永久保留；可在本地分类修改名称")
                }
            }
        } else {
            EmptyState(icon: "cursorarrow.rays", title: "悬停查看大图", detail: "将鼠标移到左侧表情包上，动图会在这里播放。")
        }
    }
}

struct MemeResultCell: View {
    let result: MemeResult
    let cacheReference: MemeCacheReference?
    let highlighted: Bool
    @StateObject private var loader = MemeImageLoader()
    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image = loader.image { Image(nsImage: image).resizable().scaledToFit() }
                    else if loader.failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
                    else { ProgressView().controlSize(.small) }
                }.frame(maxWidth: .infinity).frame(height: 72)
                if result.animated {
                    Text("动图").font(.system(size: 9, weight: .semibold)).padding(4).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            Text(result.title).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(result.sourceTitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(6).background(highlighted ? Color.teal.opacity(0.1) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(highlighted ? Color.teal : Color.clear, lineWidth: 1))
            .task(id: result.thumbnail.absoluteString + (cacheReference?.generation.uuidString ?? "")) {
                await loader.load(result, reference: cacheReference)
            }
    }
}

/// NSImageView 原生播放 GIF；更新其他界面状态时不重设 image，避免动画不停回到第一帧。
struct AnimatedImage: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
    }
    static func dismantleNSView(_ view: NSImageView, coordinator: ()) { view.animates = false; view.image = nil }
}
