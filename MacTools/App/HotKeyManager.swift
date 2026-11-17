import AppKit
import Carbon
import Combine

/// 用 Carbon 注册跨应用快捷键，用 AppKit 处理应用内按键，并将命中结果转换为功能入口。
@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()
    @Published var failures: [String] = []
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    // Carbon 回调只携带数字 ID，借助此映射找回需要打开的功能。
    private var actions: [UInt32: Feature] = [:]
    private var localMonitor: Any?
    private(set) var recordingShortcut = false
    var onFeature: ((Feature) -> Void)?

    /// 按当前设置重新注册；先释放旧引用，防止应用自身占用组合键而导致冲突。
    func register() {
        for reference in references { UnregisterEventHotKey(reference) }
        references = []; actions = [:]; failures = []
        guard !recordingShortcut else { return }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            // 注册与监听使用同一个分发目标，保证应用位于后台时也能收到热键事件。
            let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                // 签名标识本应用的事件，避免把其他 Carbon 事件误当作功能快捷键。
                guard result == noErr, id.signature == 0x4D544C53 else { return OSStatus(eventNotHandledErr) }
                // C 回调通过非持有指针恢复实例；shared 单例保证其生命周期覆盖事件监听。
                let manager = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
                // 此处理器由主线程 AppKit 事件循环调用；assumeIsolated 声明该前提，并不切换线程。
                MainActor.assumeIsolated {
                    if let feature = manager.actions[id.id], SettingsStore.shared.isEnabled(feature) { manager.onFeature?(feature) }
                }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            if status != noErr { failures.append("快捷键事件监听失败（\(status)）"); return }
        }
        if localMonitor == nil {
            // 应用内事件单独处理；不会监听或吞掉系统的复制、粘贴操作。
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, !self.recordingShortcut, !event.isARepeat else { return false }
                    var modifiers: UInt32 = 0
                    if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
                    if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
                    if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
                    if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
                    for feature in SettingsStore.shared.shortcutFeatures {
                        if let shortcut = SettingsStore.shared.activeShortcut(for: feature),
                           shortcut.keyCode == event.keyCode, shortcut.modifiers == modifiers {
                            self.onFeature?(feature)
                            return true
                        }
                    }
                    return false
                }
                // 只消费已匹配的功能快捷键，其余按键继续交给当前输入框或窗口。
                return handled ? nil : event
            }
        }
        for (index, feature) in Feature.allCases.enumerated() {
            guard let shortcut = SettingsStore.shared.activeShortcut(for: feature) else { continue }
            let id = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x4D544C53, id: id), GetEventDispatcherTarget(), 0, &reference)
            if status == noErr, let reference { references.append(reference); actions[id] = feature }
            else { failures.append("\(feature.title)：\(shortcut.label) 注册失败，请修改组合键（\(status)）") }
        }
    }

    /// 编辑快捷键时临时取消注册，否则用户输入已有组合键会打开功能窗口而非完成录入。
    func beginRecordingShortcut() {
        recordingShortcut = true
        for reference in references { UnregisterEventHotKey(reference) }
        references = []
    }

    func endRecordingShortcut() { recordingShortcut = false; register() }

    /// 先检查系统常用组合与应用内重复，再持久化并注册；系统级占用由注册结果反馈。
    func set(_ shortcut: Shortcut, for feature: Feature) -> String? {
        let commandOnly = shortcut.modifiers == UInt32(cmdKey)
        if commandOnly && [UInt32(8), UInt32(9), UInt32(7), UInt32(0), UInt32(6)].contains(shortcut.keyCode) {
            return "请保留系统的复制、粘贴、剪切、全选和撤销快捷键"
        }
        if shortcut.modifiers & UInt32(cmdKey | controlKey | optionKey) == 0 { return "请至少包含 Command、Control 或 Option" }
        if SettingsStore.shared.shortcuts.contains(where: { $0.key != feature.rawValue && $0.value.keyCode == shortcut.keyCode && $0.value.modifiers == shortcut.modifiers }) {
            return "此组合键已分配给其他功能"
        }
        SettingsStore.shared.shortcuts[feature.rawValue] = shortcut
        register()
        return failures.first
    }
}
