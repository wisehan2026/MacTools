import SwiftUI

/// 设置行只绑定配置与拖放手势；排序和数量校验统一交由 SettingsStore。
struct MemeSourceSettingsRow: View {
    let source: MemeSource
    @ObservedObject private var settings = SettingsStore.shared
    @State private var targeted = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).padding(6)
                .accessibilityLabel("拖动排序：" + source.title)
                .draggable("meme-source:" + source.rawValue)
                .contextMenu {
                    Button("上移") { move(-1) }.disabled(settings.memeSourceOrder.first == source)
                    Button("下移") { move(1) }.disabled(settings.memeSourceOrder.last == source)
                }
            Toggle(isOn: Binding(get: { settings.memeSources.contains(source) }, set: { settings.setMemeSource(source, enabled: $0) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.title)
                    Text(source.detail).font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(settings.memeSources == [source])
            Spacer(minLength: 4)
            if settings.memeCustomDistribution {
                TextField("数量", value: Binding(get: { settings.memeCount(for: source) }, set: { settings.setMemeCount($0, for: source) }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 48).disabled(!settings.memeSources.contains(source)).accessibilityLabel(source.title + "数量")
                Text("条").font(.caption)
            } else {
                Text(settings.memeSources.contains(source) ? "\(settings.memeSearchPlan.limits[source] ?? 0) 条" : "未选")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("仅用此源") { settings.useOnlyMemeSource(source) }.disabled(settings.memeSources == [source])
            Link("说明", destination: source.website)
        }.padding(.vertical, 5).background(targeted ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .dropDestination(for: String.self) { items, _ in
                guard let token = items.first, token.hasPrefix("meme-source:"),
                      let dragged = MemeSource(rawValue: String(token.dropFirst("meme-source:".count))) else { return false }
                settings.moveMemeSource(dragged, to: source)
                return true
            } isTargeted: { targeted = $0 }
    }
    private func move(_ delta: Int) {
        guard let index = settings.memeSourceOrder.firstIndex(of: source), settings.memeSourceOrder.indices.contains(index + delta) else { return }
        settings.moveMemeSource(source, to: settings.memeSourceOrder[index + delta])
    }
}
