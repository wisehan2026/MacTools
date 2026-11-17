import AppKit
import Combine
import ServiceManagement

/// 统一保存可配置项；@Published 驱动界面刷新，didSet 将变更写入当前应用的 UserDefaults 域。
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private let defaults: UserDefaults
    @Published private(set) var disabledFeatures: Set<Feature> {
        didSet { defaults.set(Feature.configurable.filter { disabledFeatures.contains($0) }.map(\.rawValue), forKey: "disabledFeatures") }
    }
    @Published var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    @Published var retentionDays: Int { didSet { defaults.set(max(1, retentionDays), forKey: "retentionDays") } }
    @Published var capacityMB: Int { didSet { defaults.set(max(64, capacityMB), forKey: "capacityMB") } }
    @Published var memeCacheDays: Int { didSet { defaults.set(max(1, min(365, memeCacheDays)), forKey: "memeCacheDays") } }
    @Published private(set) var memeSources: Set<MemeSource> { didSet { defaults.set(MemeSource.ordered(memeSources).map(\.rawValue), forKey: "memeSources") } }
    @Published private(set) var memeSourceOrder: [MemeSource] { didSet { defaults.set(memeSourceOrder.map(\.rawValue), forKey: "memeSourceOrder") } }
    @Published private(set) var memeCustomDistribution: Bool { didSet { defaults.set(memeCustomDistribution, forKey: "memeCustomDistribution") } }
    @Published private(set) var memeSourceCounts: [String: Int] { didSet { defaults.set(memeSourceCounts, forKey: "memeSourceCounts") } }
    @Published var excludedApps: String { didSet { defaults.set(excludedApps, forKey: "excludedApps") } }
    @Published var screenshotDirectory: String { didSet { defaults.set(screenshotDirectory, forKey: "screenshotDirectory") } }
    @Published var recordingDirectory: String { didSet { defaults.set(recordingDirectory, forKey: "recordingDirectory") } }
    // 结构化设置先编码为 JSON Data；键名与 Codable 字段变化时需考虑已有用户数据。
    @Published var shortcuts: [String: Shortcut] { didSet { persist(shortcuts, key: "shortcuts") } }
    @Published var presets: [String] { didSet { persist(presets, key: "sizePresets") } }
    @Published var phrases: [Phrase] { didSet { persist(phrases, key: "phrases") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        disabledFeatures = Set((defaults.stringArray(forKey: "disabledFeatures") ?? []).compactMap(Feature.init(rawValue:)).filter(\.canDisable))
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        retentionDays = defaults.object(forKey: "retentionDays") as? Int ?? 3
        capacityMB = defaults.object(forKey: "capacityMB") as? Int ?? 1024
        memeCacheDays = max(1, min(365, defaults.object(forKey: "memeCacheDays") as? Int ?? 3))
        let savedSources = Set((defaults.stringArray(forKey: "memeSources") ?? []).compactMap(MemeSource.init(rawValue:)))
        memeSources = savedSources.isEmpty ? [.memecub] : savedSources
        let savedOrder = (defaults.stringArray(forKey: "memeSourceOrder") ?? []).compactMap(MemeSource.init(rawValue:))
        var seenSources = Set<MemeSource>()
        memeSourceOrder = (savedOrder + MemeSource.allCases).filter { seenSources.insert($0).inserted }
        memeCustomDistribution = defaults.bool(forKey: "memeCustomDistribution")
        memeSourceCounts = (defaults.dictionary(forKey: "memeSourceCounts") as? [String: Int] ?? [:]).mapValues { max(1, min(50, $0)) }
        excludedApps = defaults.string(forKey: "excludedApps") ?? "com.agilebits.onepassword7\ncom.1password.1password\ncom.apple.Passwords"
        let home = FileManager.default.homeDirectoryForCurrentUser
        screenshotDirectory = defaults.string(forKey: "screenshotDirectory") ?? home.appendingPathComponent("Pictures/MacTools").path
        recordingDirectory = defaults.string(forKey: "recordingDirectory") ?? home.appendingPathComponent("Movies/MacTools").path
        shortcuts = Self.decode(defaults, [String: Shortcut].self, key: "shortcuts") ?? Dictionary(uniqueKeysWithValues: Feature.allCases.compactMap { feature in
            Shortcut.standard(for: feature).map { (feature.rawValue, $0) }
        })
        presets = Self.decode(defaults, [String].self, key: "sizePresets") ?? ["1280 × 720", "1920 × 1080", "1080 × 1080"]
        phrases = Self.decode(defaults, [Phrase].self, key: "phrases") ?? []
        // 只迁移一次；用户之后停用表情快捷键时，重启不能擅自恢复，也不抢占已自定义的组合键。
        if !defaults.bool(forKey: "memeShortcutMigrated") {
            if shortcuts[Feature.memes.rawValue] == nil, let shortcut = Shortcut.standard(for: .memes),
               !shortcuts.values.contains(where: { $0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers }) {
                shortcuts[Feature.memes.rawValue] = shortcut
            }
            persist(shortcuts, key: "shortcuts")
            defaults.set(true, forKey: "memeShortcutMigrated")
        }
    }

    private static func decode<T: Decodable>(_ defaults: UserDefaults, _ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func isEnabled(_ feature: Feature) -> Bool { !feature.canDisable || !disabledFeatures.contains(feature) }
    var enabledFeatures: [Feature] { Feature.allCases.filter(isEnabled) }
    var launcherFeatures: [Feature] { Feature.configurable.filter(isEnabled) }
    var shortcutFeatures: [Feature] { enabledFeatures.filter { $0.defaultKey != nil } }
    func activeShortcut(for feature: Feature) -> Shortcut? { isEnabled(feature) ? shortcuts[feature.rawValue] : nil }
    func setFeatureEnabled(_ feature: Feature, enabled: Bool) {
        guard feature.canDisable else { return }
        if enabled { disabledFeatures.remove(feature) }
        else { disabledFeatures.insert(feature) }
    }

    func setMemeSource(_ source: MemeSource, enabled: Bool) {
        if enabled { memeSources.insert(source) }
        else if memeSources.count > 1 { memeSources.remove(source) }
    }
    func useOnlyMemeSource(_ source: MemeSource) { memeSources = [source] }

    var memeSearchPlan: MemeSearchPlan {
        let counts = Dictionary(uniqueKeysWithValues: memeSources.map { ($0, memeCount(for: $0)) })
        return MemeSearchPlan(sources: memeSources, order: memeSourceOrder, counts: memeCustomDistribution ? counts : nil)
    }
    func memeCount(for source: MemeSource) -> Int { memeSourceCounts[source.rawValue] ?? MemeSource.limit(for: memeSources) }
    func setMemeCount(_ count: Int, for source: MemeSource) { memeSourceCounts[source.rawValue] = max(1, min(50, count)) }
    func setMemeCustomDistribution(_ enabled: Bool) {
        if enabled {
            for source in memeSources where memeSourceCounts[source.rawValue] == nil { setMemeCount(MemeSource.limit(for: memeSources), for: source) }
        }
        memeCustomDistribution = enabled
    }
    func moveMemeSource(_ source: MemeSource, to target: MemeSource) {
        guard source != target, let from = memeSourceOrder.firstIndex(of: source), let to = memeSourceOrder.firstIndex(of: target) else { return }
        var order = memeSourceOrder
        order.remove(at: from); order.insert(source, at: to)
        memeSourceOrder = order
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    // 开机启动以系统注册状态为准，避免本地布尔值与系统设置不同步。
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        // launchAtLogin 是计算属性，没有 @Published，需要主动通知界面重新读取。
        objectWillChange.send()
    }

    func chooseDirectory(recording: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择保存位置"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if recording { recordingDirectory = url.path } else { screenshotDirectory = url.path }
    }
}
