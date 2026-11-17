import SwiftUI

struct LocalMemeView: View {
    @ObservedObject var library: LocalMemeController
    @StateObject private var browser = MemeSearchController()
    @State private var deleting: MemeResult?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("按自定义名称查找本地表情", text: $library.query).textFieldStyle(.roundedBorder)
                Picker("图片类型", selection: $library.filter) {
                    ForEach(MemeFilter.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 100)
                Button("添加表情…") { library.beginImport() }.buttonStyle(.borderedProminent)
            }.padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            HSplitView {
                results.frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                VStack {
                    MemePreviewView(controller: browser)
                    if let item = browser.preview {
                        HStack {
                            Button("编辑名称或图片…") { library.beginEdit(item) }
                            Button("删除…", role: .destructive) { deleting = item }
                        }
                    }
                }.frame(minWidth: 240, idealWidth: 310, maxWidth: 400, maxHeight: .infinity).padding(20)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("本地 \(library.results.count) 张 · 当前显示 \(library.visible.count) 张 · 悬停预览，双击复制").font(.callout)
                Text("仅保存在本机，不上传、不自动清理；可右键编辑或删除。支持静图和动图，单张最多 16 MB。")
                    .font(.caption).foregroundStyle(.secondary)
                if !library.message.isEmpty { Text(library.message).font(.caption).textSelection(.enabled) }
                if !browser.status.isEmpty { Text(browser.status).font(.caption).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
        .task { await library.refresh() }
        .onDisappear { browser.close() }
        .onChange(of: library.query) { _, _ in browser.clearPreview() }
        .onChange(of: library.filter) { _, _ in browser.clearPreview() }
        .onChange(of: library.results) { _, _ in browser.close() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == Feature.memes.rawValue { browser.close() }
        }
        .sheet(isPresented: $library.editing, onDismiss: { library.resetEditor() }) { LocalMemeEditorView(library: library) }
        .alert("删除本地表情？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let item = deleting { browser.close(); library.delete(item) }
                deleting = nil
            }
        } message: { Text("将删除“\(deleting?.title ?? "")”的本地副本；导入的原文件和已复制到剪贴板历史的记录不受影响。") }
    }

    @ViewBuilder private var results: some View {
        if library.loading { ProgressView() }
        else if library.visible.isEmpty {
            EmptyState(icon: "photo.on.rectangle.angled", title: library.results.isEmpty ? "添加自己的表情包" : "没有匹配的本地表情",
                       detail: library.results.isEmpty ? "点击“添加表情”，选择静图或动图并设置名称。" : "试试其他名称，或切换为“全部”图片类型。")
        } else {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 65), spacing: 8), count: 5), spacing: 8) {
                    ForEach(library.visible) { item in
                        MemeResultCell(result: item, cacheReference: nil, highlighted: browser.preview?.id == item.id)
                            .contentShape(Rectangle()).onHover { if $0 { browser.hover(item) } }
                            .onTapGesture(count: 2) { browser.copy(item) }
                            .contextMenu {
                                Button("复制表情包") { browser.copy(item) }.disabled(browser.copying)
                                Button("编辑名称或图片…") { library.beginEdit(item) }
                                Button("删除…", role: .destructive) { deleting = item }
                            }
                            .accessibilityElement(children: .ignore).accessibilityLabel(item.title + (item.animated ? "，动图" : "，静图"))
                            .accessibilityAction(named: "复制表情包") { browser.copy(item) }
                    }
                }.padding(12)
            }
        }
    }
}

private struct LocalMemeEditorView: View {
    @ObservedObject var library: LocalMemeController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(library.isNew ? "添加本地表情" : "编辑本地表情").font(.title2)
            TextField("自定义名称（1～100 字）", text: $library.draftName).textFieldStyle(.roundedBorder)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let image = library.draftImage { AnimatedImage(image: image).padding(10) }
                else { Text("选择一张静图或动图").foregroundStyle(.secondary) }
                if library.working { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) }
            }.frame(height: 230)
            HStack {
                Button(library.draftImage == nil ? "选择图片…" : "更换图片…") { library.chooseImage() }.disabled(library.working)
                Text("原图仅复制到本机，保留动图帧。单张最多 16 MB。").font(.caption).foregroundStyle(.secondary)
            }
            if !library.editorError.isEmpty { Text(library.editorError).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { library.editing = false }.keyboardShortcut(.cancelAction).disabled(library.working)
                Button("保存") { library.save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!library.canSave)
            }
        }.padding(24).frame(width: 440).interactiveDismissDisabled(library.working)
    }
}
