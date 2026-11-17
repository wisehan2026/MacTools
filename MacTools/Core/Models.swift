import AppKit
import Carbon

/// 功能入口的统一标识，供菜单、窗口和快捷键共用；rawValue 同时作为持久化键，改名需兼容旧设置。
enum Feature: String, CaseIterable, Identifiable, Codable {
    case launcher, clipboard, screenshot, scrollshot, memes, recording, search, ocr, phrases, storage, settings
    var id: String { rawValue }
    // 总入口与设置始终保留，避免关闭全部工具后无法重新启用。
    var canDisable: Bool { self != .launcher && self != .settings }
    static var configurable: [Self] { allCases.filter(\.canDisable) }
    var title: String {
        switch self {
        case .launcher: "MacTools"
        case .clipboard: "剪贴板历史"
        case .screenshot: "截图与标注"
        case .scrollshot: "滚动长截图"
		case .memes: "表情包搜索"
        case .recording: "屏幕录制"
        case .search: "文件搜索"
        case .ocr: "文字识别"
        case .phrases: "常用短语"
        case .storage: "空间管理"
        case .settings: "设置"
        }
    }
    var icon: String {
        switch self {
        case .launcher: "square.grid.2x2"
        case .clipboard: "clipboard"
        case .screenshot: "crop"
        case .scrollshot: "arrow.down.to.line.compact"
		case .memes: "face.smiling"
        case .recording: "record.circle"
        case .search: "magnifyingglass"
        case .ocr: "text.viewfinder"
        case .phrases: "text.bubble"
        case .storage: "externaldrive"
        case .settings: "slider.horizontal.3"
        }
    }
    var subtitle: String {
        switch self {
        case .launcher: "随时打开，专注手边的事"
        case .clipboard: "文字与图片，按天整理"
        case .screenshot: "精确选区 · 标注 · 悬浮置顶"
        case .scrollshot: "手动滚动，将长内容拼成一张图"
		case .memes: "搜索静图与动图 · 悬停预览 · 双击复制"
        case .recording: "区域、窗口或全屏，声音自由选择"
        case .search: "快速找到本机文件"
        case .ocr: "选取屏幕区域，识别中英文"
        case .phrases: "让常用表达触手可及"
        case .storage: "查看和管理 MacTools 的本地数据"
        case .settings: "按你的习惯使用"
        }
    }
    /// macOS 虚拟键码，不是字符的 Unicode 值；nil 表示默认不分配快捷键。
    var defaultKey: UInt32? {
        switch self {
        case .launcher: 49
        case .clipboard: 9
        case .screenshot: 1
        case .scrollshot: 37
		case .memes: 46
        case .recording: 15
        case .search: 3
        case .ocr: 17
        default: nil
        }
    }
}

/// keyCode 与 Carbon 修饰键位掩码用于注册；label 仅用于界面显示，不能代替真实按键值。
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
    /// 菜单使用系统快捷键列，修饰键来自真实注册值；空格用原生符号展示。
    var menuKeyEquivalent: String {
        if keyCode == 49 { return " " }
        return String(label.drop(while: { "⌃⌥⇧⌘".contains($0) })).lowercased()
    }
    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }
    static func standard(for feature: Feature) -> Shortcut? {
        guard let key = feature.defaultKey else { return nil }
        let names: [Feature: String] = [.launcher: "空格", .clipboard: "V", .screenshot: "S", .scrollshot: "L", .recording: "R", .search: "F", .memes: "M", .ocr: "T"]
        return Shortcut(keyCode: key, modifiers: UInt32(controlKey | optionKey), label: "⌃⌥" + (names[feature] ?? ""))
    }
}

struct ClipboardEntry: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case text, image, meme }
    var id = UUID()
    // 表示最近一次收录时间；重复复制时更新，日期分组和过期判断均以此为准。
    var createdAt: Date
    var kind: Kind
    var text: String?
    // 相对 LocalFiles.clipboard 的路径，图片文件与 JSON 索引分离存储。
    var imagePath: String?
    var fingerprint: String
    var source: String
    var bytes: Int64
    var favorite = false
    // 可选字段兼容旧版 JSON；表情名称用于历史搜索，不混入剪贴板图片内容。
    var memeTitle: String?
    var title: String {
        switch kind {
        case .text: String((text ?? "").prefix(120))
        case .image: "图片"
        case .meme: "表情包 · " + (memeTitle ?? "未命名")
        }
    }
    var icon: String { kind == .meme ? "face.smiling" : (kind == .image ? "photo" : "text.alignleft") }
}

struct Phrase: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var text: String
}

enum FileKind: String, CaseIterable, Identifiable {
    case all = "全部", folder = "文件夹", image = "图片", video = "视频", audio = "音频", document = "文档", code = "代码", other = "其他"
    var id: String { rawValue }
    static func classify(_ url: URL, directory: Bool) -> FileKind {
        if directory { return .folder }
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "svg", "bmp"].contains(ext) { return .image }
        if ["mp4", "mov", "mkv", "avi", "webm", "m4v"].contains(ext) { return .video }
        if ["mp3", "wav", "m4a", "aac", "flac", "aiff", "ogg"].contains(ext) { return .audio }
        if ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "md", "csv"].contains(ext) { return .document }
        if ["swift", "m", "h", "c", "cpp", "dart", "kt", "java", "py", "js", "ts", "tsx", "jsx", "json", "yaml", "html", "css", "sh", "rs", "go"].contains(ext) { return .code }
        return .other
    }
}

/// 可从后台枚举任务返回到主线程的值类型，只携带文件元数据，不跨线程传递界面对象。
struct FileResult: Identifiable, Sendable {
    var id: String { url.path }
    var url: URL
    var directory: Bool
    var bytes: Int64
    var modified: Date?
    var kind: FileKind { FileKind.classify(url, directory: directory) }
}

enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

func formattedBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
