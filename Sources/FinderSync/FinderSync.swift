import FinderSync
import AppKit

/// Finder Sync 扩展：向 Finder 右键菜单注入「新建文件」子菜单。
///
/// 职责仅限：展示菜单 + 发起创建请求。实际写文件由常驻主应用执行（它持有有效的
/// 安全作用域授权书签），彻底避免扩展进程书签跨进程解析失败导致的写权限问题。
/// 若主应用 3.5s 内未消费请求（未运行），扩展退回自行创建。
final class FinderSync: FIFinderSync {

    override init() {
        super.init()
        applyWatchRoot()

        // selector 式监听（DistributedNotificationCenter 的 block 式 API 不投递）
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(watchRootChanged),
            name: .init(Shared.distWatchRootChanged), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(formatsChanged),
            name: .init("com.cgbin.menushot.formatsChanged"), object: nil)
    }

    @objc private func formatsChanged() {
        Shared.invalidateFormatsCache()
    }

    @objc private func watchRootChanged() {
        // 主应用里重新授权了根目录：热刷新监听目录，无需重启扩展
        DispatchQueue.main.async { [weak self] in
            self?.applyWatchRoot()
        }
    }

    /// 解析授权书签 → 设置监听目录 → 自检上报（供设置页诊断显示）
    private func applyWatchRoot() {
        // 未授权时监听目录为空：不注入菜单、不访问任何文件夹（避免反复触发系统授权弹窗）
        if let granted = Shared.resolveWatchRoot() {
            granted.startAccessingSecurityScopedResource()
            FIFinderSyncController.default().directoryURLs = [granted]
            Shared.reportExtensionWatchRoot(granted.path)
        } else {
            FIFinderSyncController.default().directoryURLs = []
            Shared.reportExtensionWatchRoot(nil)
        }
    }

    // MARK: - 菜单

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "MenuShot")

        guard menuKind == .contextualMenuForContainer || menuKind == .contextualMenuForItems else {
            return menu
        }

        let item = NSMenuItem(title: "新建文件", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "新建文件")

        let sub = NSMenu(title: "新建文件")
        for format in Shared.loadFormats() {
            let entry = NSMenuItem(title: format.name, action: #selector(createFileAction(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = format.ext
            // Finder 可能不保留 representedObject：标识符 + 标题做双保险
            entry.identifier = NSUserInterfaceItemIdentifier("ext:" + format.ext)
            entry.image = menuIcon(for: format)
            entry.toolTip = "在当前文件夹创建 .\(format.ext) 文件"
            sub.addItem(entry)
        }
        item.submenu = sub
        menu.addItem(item)
        return menu
    }

    // MARK: - 创建请求

    @objc private func createFileAction(_ sender: NSMenuItem) {
        let formats = Shared.loadFormats()
        // representedObject → 标识符 → 标题，三重解析（Finder 可能只保留标题）
        let ext = sender.representedObject as? String
            ?? sender.identifier.flatMap { id -> String? in
                let raw = id.rawValue
                return raw.hasPrefix("ext:") ? String(raw.dropFirst(4)) : nil
            }
            ?? formats.first(where: { $0.name == sender.title })?.ext

        Shared.appendExtDebug("点击菜单「\(sender.title)」→ ext=\(ext ?? "nil")")
        guard let ext = ext, formats.contains(where: { $0.ext == ext }) else {
            report(title: "新建文件失败", message: "无法解析所选格式（菜单项：\(sender.title)）")
            return
        }

        let controller = FIFinderSyncController.default()
        let dir: URL?
        if let target = controller.targetedURL() {
            dir = NewFileService.directory(forTarget: target)
        } else if let first = controller.selectedItemURLs()?.first {
            dir = NewFileService.directory(forTarget: first)
        } else {
            Shared.appendExtDebug("targetedURL 与 selectedItemURLs 均为空")
            report(title: "无法确定目标文件夹", message: "请在 Finder 窗口或桌面的空白处右击后重试。")
            return
        }
        Shared.appendExtDebug("目标目录 = \(dir!.path)")

        // 首选：请求常驻主应用创建（它持有有效授权）
        let request = Shared.CreateRequest(id: UUID().uuidString, dirPath: dir!.path, ext: ext)
        Shared.enqueueCreateRequest(request)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Shared.distCreateRequest), object: nil,
            userInfo: nil, deliverImmediately: true)
        Shared.appendExtDebug("已发送创建请求 → 主应用")

        // 兜底：3.5s 后请求仍在队列（主应用未消费，如未运行）→ 扩展自行创建
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self = self, Shared.removeCreateRequest(id: request.id) else { return }
            Shared.appendExtDebug("主应用未响应，扩展兜底创建")
            self.createDirectly(dirPath: request.dirPath, ext: ext)
        }
    }

    private func createDirectly(dirPath: String, ext: String) {
        guard let format = Shared.loadFormats().first(where: { $0.ext == ext }) else { return }
        do {
            let url = try NewFileService.create(in: URL(fileURLWithPath: dirPath), format: format)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            report(ok: true, path: url.path, title: "", message: "")
        } catch {
            report(ok: false, path: nil,
                   title: "新建 \(format.name) 失败",
                   message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func report(ok: Bool, path: String?, title: String, message: String) {
        Shared.storeResult(.init(ok: ok, path: path, title: title, message: message))
        let name = ok ? Shared.distCreateOK : Shared.distCreateFail
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func report(title: String, message: String) {
        report(ok: false, path: nil, title: title, message: message)
    }

    private func menuIcon(for format: FileFormat) -> NSImage? {
        switch format.ext.lowercased() {
        case "md": return NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
        case "txt": return NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: nil)
        case "json", "xml", "yaml", "yml": return NSImage(systemSymbolName: "curlybraces", accessibilityDescription: nil)
        case "html", "htm": return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        case "csv": return NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)
        case "swift": return NSImage(systemSymbolName: "swift", accessibilityDescription: nil)
        case "py": return NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
        default: return NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        }
    }
}
