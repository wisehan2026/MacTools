import SwiftUI

struct PhrasesView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var selected: UUID?
    @State private var title = ""
    @State private var text = ""
    @State private var query = ""
    @State private var message = ""
    @State private var deleting = false
    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .phrases)
            Divider()
            HSplitView {
                VStack {
                    TextField("搜索短语", text: $query).textFieldStyle(.roundedBorder).padding(12)
                    List(settings.phrases.filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.text.localizedStandardContains(query) }, selection: $selected) { phrase in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(phrase.title).fontWeight(.medium)
                            Text(phrase.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.vertical, 5).tag(phrase.id)
                    }.listStyle(.sidebar)
                    Button("新建短语") { selected = nil; title = ""; text = "" }.padding(12)
                }.frame(minWidth: 220, idealWidth: 260)
                VStack(alignment: .leading, spacing: 16) {
                    TextField("短语名称", text: $title).textFieldStyle(.roundedBorder)
                    TextEditor(text: $text).font(.body).frame(minHeight: 180)
                    HStack {
                        Button("保存") { save() }.keyboardShortcut("s", modifiers: .command).disabled(title.isEmpty || text.isEmpty)
                        Button("删除", role: .destructive) { deleting = true }.disabled(selected == nil)
                        Spacer()
                        Button("复制") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); message = "已复制，按 ⌘V 粘贴"
                        }.buttonStyle(.borderedProminent).tint(.teal).disabled(text.isEmpty)
                    }
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }.padding(22).frame(minWidth: 340)
            }
        }.onChange(of: selected) { _, value in
            if let phrase = settings.phrases.first(where: { $0.id == value }) { title = phrase.title; text = phrase.text }
        }.alert("删除此短语？", isPresented: $deleting) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { settings.phrases.removeAll { $0.id == selected }; selected = nil; title = ""; text = "" }
        }
    }
    private func save() {
        if let index = settings.phrases.firstIndex(where: { $0.id == selected }) { settings.phrases[index].title = title; settings.phrases[index].text = text }
        else { let phrase = Phrase(title: title, text: text); settings.phrases.append(phrase); selected = phrase.id }
        message = "已保存"
    }
}
