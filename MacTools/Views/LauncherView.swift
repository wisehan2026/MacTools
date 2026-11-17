import SwiftUI

struct LauncherView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("MacTools").font(.system(size: 28, weight: .semibold))
                    Text("手边的工具，刚刚好。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { WindowCoordinator.shared.show(.settings) } label: { Image(systemName: "slider.horizontal.3").font(.title3) }
                    .buttonStyle(.plain).help("设置")
            }.padding(26)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("查找工具", text: $query).textFieldStyle(.plain)
            }.padding(12).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 24).padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(settings.launcherFeatures.filter { query.isEmpty || $0.title.localizedStandardContains(query) }) { feature in
                        Button { WindowCoordinator.shared.show(feature) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: feature.icon).font(.system(size: 19)).foregroundStyle(.teal).frame(width: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(feature.title).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                                    Text(feature.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let shortcut = settings.shortcuts[feature.rawValue] { KeyBadge(text: shortcut.label) }
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }.padding(.horizontal, 16).padding(.vertical, 12).contentShape(Rectangle())
                        }.buttonStyle(ToolRowStyle())
                    }
                    if settings.launcherFeatures.isEmpty {
                        EmptyState(icon: "slider.horizontal.3", title: "所有工具已关闭", detail: "在设置的“功能开关”中重新启用。")
                    }
                }.padding(.horizontal, 12).padding(.bottom, 12)
            }
            Divider()
            HStack {
                Circle().fill(.teal).frame(width: 6, height: 6)
                Text("本机运行 · 离线保存").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("⌘C 复制  ·  ⌘V 粘贴").font(.caption).foregroundStyle(.tertiary)
            }.padding(16)
        }
    }
}

private struct ToolRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Color.teal.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
    }
}
