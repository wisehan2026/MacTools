import SwiftUI

struct SearchView: View {
    @StateObject private var controller = FileSearchController()
    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .search)
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("输入文件名", text: $controller.text).textFieldStyle(.plain).font(.title3)
                        .onSubmit { controller.search() }
                    if controller.searching { ProgressView().controlSize(.small) }
                }.padding(13).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Button { controller.chooseDirectory() } label: {
                        Label(controller.directory?.lastPathComponent ?? "指定目录…", systemImage: "folder")
                    }
                    if controller.directory != nil { Button("全局搜索") { controller.directory = nil; controller.search() } }
                    Spacer()
                    Toggle("隐藏文件", isOn: $controller.includeHidden).controlSize(.small)
                    Picker("类型", selection: $controller.kind) { ForEach(FileKind.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 150)
                }
                if let directory = controller.directory { Text(directory.path).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            if controller.visible.isEmpty {
                EmptyState(icon: "doc.text.magnifyingglass", title: controller.text.isEmpty ? "从文件名开始" : "没有匹配的文件", detail: "可按类型筛选，或指定一个目录直接搜索。")
            } else {
                List(controller.visible, selection: $controller.selection) { file in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.url.lastPathComponent).lineLimit(1)
                            Text(file.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(file.directory ? "文件夹" : formattedBytes(file.bytes)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).tag(file.id)
                        .contextMenu {
                            Button("打开") { NSWorkspace.shared.open(file.url) }
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                            Button("复制路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.url.path, forType: .string) }
                        }
                }.listStyle(.inset)
            }
            Divider()
            HStack {
                Text(controller.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("预览") { controller.preview() }.disabled(controller.selected == nil)
                Button("定位") { controller.reveal() }.disabled(controller.selected == nil)
                Button("打开") { controller.open() }.disabled(controller.selected == nil).buttonStyle(.borderedProminent).tint(.teal)
            }.padding(12)
        }.onChange(of: controller.text) { _, _ in controller.search() }
            .onChange(of: controller.includeHidden) { _, _ in controller.search() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
                if (notification.object as? NSWindow)?.identifier?.rawValue == Feature.search.rawValue { controller.close() }
            }
    }
}
