import Foundation
import Combine
import ServiceManagement
import Carbon.HIToolbox

/// 应用设置：UserDefaults 持久化；格式列表同步写入 App Group 供 Finder 扩展读取。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    private enum Key {
        static let hotKeyEnabled = "hotKeyEnabled"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyMods = "hotKeyMods"     // Carbon 修饰键位
        static let autoSave = "autoSaveOnConfirm"
        static let saveAsJPEG = "saveAsJPEG"
        static let defaultSaveBookmark = "defaultSaveBookmark"
        static let defaultSavePath = "defaultSavePathDisplay"
        static let launchedBefore = "launchedBefore"
    }

    @Published var hotKeyEnabled: Bool {
        didSet { d.set(hotKeyEnabled, forKey: Key.hotKeyEnabled); NotificationCenter.default.postHotKeyChanged() }
    }
    @Published var hotKeyCode: UInt32 {
        didSet { d.set(Int(hotKeyCode), forKey: Key.hotKeyCode); NotificationCenter.default.postHotKeyChanged() }
    }
    @Published var hotKeyCarbonMods: UInt32 {
        didSet { d.set(Int(hotKeyCarbonMods), forKey: Key.hotKeyMods); NotificationCenter.default.postHotKeyChanged() }
    }
    @Published var autoSaveOnConfirm: Bool {
        didSet { d.set(autoSaveOnConfirm, forKey: Key.autoSave) }
    }
    @Published var saveAsJPEG: Bool {
        didSet { d.set(saveAsJPEG, forKey: Key.saveAsJPEG) }
    }
    @Published var formats: [FileFormat] {
        didSet {
            // 应用自身容器（无 TCC）；共享容器同步放后台队列（TCC 弹窗不阻塞主线程）
            d.set(try? JSONEncoder().encode(formats), forKey: "formats_local")
            if let data = try? JSONEncoder().encode(formats) {
                DispatchQueue.global(qos: .utility).async {
                    Shared.sharedDefaults?.set(data, forKey: Shared.keyFormats)
                }
            }
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.cgbin.menushot.formatsChanged"), object: nil,
                userInfo: nil, deliverImmediately: true)
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }
    @Published var defaultSaveBookmark: Data? {
        didSet { d.set(defaultSaveBookmark, forKey: Key.defaultSaveBookmark) }
    }
    @Published var defaultSavePathDisplay: String {
        didSet { d.set(defaultSavePathDisplay, forKey: Key.defaultSavePath) }
    }

    var isLaunchedBefore: Bool {
        get { d.bool(forKey: Key.launchedBefore) }
        set { d.set(newValue, forKey: Key.launchedBefore) }
    }

    private init() {
        d.register(defaults: [
            Key.hotKeyEnabled: true,
            Key.hotKeyCode: Int(kVK_ANSI_A),          // 默认 ⌥⌘A
            Key.hotKeyMods: Int(UInt32(optionKey) | UInt32(cmdKey)),
            Key.autoSave: true,
            Key.saveAsJPEG: false,
        ])
        hotKeyEnabled = d.bool(forKey: Key.hotKeyEnabled)
        hotKeyCode = UInt32(d.integer(forKey: Key.hotKeyCode))
        hotKeyCarbonMods = UInt32(d.integer(forKey: Key.hotKeyMods))
        autoSaveOnConfirm = d.bool(forKey: Key.autoSave)
        saveAsJPEG = d.bool(forKey: Key.saveAsJPEG)
        if let data = d.data(forKey: "formats_local"),
           let list = try? JSONDecoder().decode([FileFormat].self, from: data), !list.isEmpty {
            formats = list
        } else {
            formats = FileFormat.defaults
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        defaultSaveBookmark = d.data(forKey: Key.defaultSaveBookmark)
        defaultSavePathDisplay = d.string(forKey: Key.defaultSavePath)
            ?? (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("MenuShot").path ?? "")
    }

    var hotKeyDisplay: String {
        HotKeyCenter.displayString(keyCode: hotKeyCode, carbonModifiers: hotKeyCarbonMods)
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("MenuShot: launchAtLogin failed: \(error.localizedDescription)")
        }
    }

    /// 解析默认保存目录（安全作用域书签），失败时回退到 ~/Pictures/MenuShot。
    func resolveDefaultSaveDir(startAccess: Bool) -> (url: URL, needsStop: Bool)? {
        var url: URL?
        var needsStop = false
        if let data = defaultSaveBookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                       relativeTo: nil, bookmarkDataIsStale: &stale) {
                url = resolved
            }
        }
        if url == nil {
            // 回退： Pictures 权限由沙盒 entitlement 直接授予
            if let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
                url = pictures.appendingPathComponent("MenuShot")
            }
        }
        guard let target = url else { return nil }
        if startAccess {
            needsStop = target.startAccessingSecurityScopedResource()
        }
        return (target, needsStop)
    }
}

extension NotificationCenter {
    func postHotKeyChanged() {
        post(name: .init("com.cgbin.menushot.hotKeyChanged"), object: nil)
    }
}
