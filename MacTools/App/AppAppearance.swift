import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    /// 应用级覆盖同时作用于 SwiftUI、原生窗口及弹窗；nil 恢复随系统自动变化。
    @MainActor func apply() { NSApplication.shared.appearance = nativeAppearance }
}
