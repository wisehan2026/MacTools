import AppKit
import SwiftUI

/// 原生 field editor 负责输入法、选区和编辑快捷键；编辑期间不被 SwiftUI 的播放器刷新覆盖。
struct EditorInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onEndEditing: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = FocusedTextField()
        field.isEditable = true; field.isSelectable = true
        field.isBordered = true; field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: EditorInput
        init(_ parent: EditorInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func controlTextDidEndEditing(_ notification: Notification) { parent.onEndEditing() }
    }
}

private final class FocusedTextField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        super.mouseDown(with: event)
    }
}

/// 保留“空字符串”“1.”等输入中间态；合法数字及时同步，结束编辑时统一格式化。
struct EditorTimeInput: View {
    let title: String
    @Binding var value: Double
    @State private var draft = ""
    @State private var editing = false
    var body: some View {
        EditorInput(text: Binding(get: { draft }, set: { next in
            editing = true; draft = next
            if let number = Double(next.replacingOccurrences(of: ",", with: ".")), number.isFinite { value = number }
        }), placeholder: title, onEndEditing: {
            editing = false; draft = formatted
        })
        .onAppear { draft = formatted }
        .onChange(of: value) { _, _ in if !editing { draft = formatted } }
        .frame(minWidth: 65, maxWidth: 90, minHeight: 24)
    }
    private var formatted: String { String(format: "%.2f", value) }
}
