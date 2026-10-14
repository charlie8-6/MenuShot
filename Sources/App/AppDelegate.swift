import AppKit
import FinderSync
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var screenshotHotKeyID: UInt32?
    private var menuPopupHotKeyID: UInt32?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("MenuShot: [诊断] 应用启动完成，注册扩展事件监听")
        DebugTrace.log("应用启动完成 pid=\(ProcessInfo.processInfo.processIdentifier) args=\(ProcessInfo.processInfo.arguments)")
        // 清理上次回放验证导出的帧（避免占用容器空间）
        if !ProcessInfo.processInfo.arguments.contains("-debugDragTest") {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("menushot_dumps", isDirectory: true))
        }
        setupStatusItem()
        applyHotKey()
        listenForExtensionEvents()

        NotificationCenter.default.addObserver(forName: .init("com.cgbin.menushot.hotKeyChanged"),
                                               object: nil, queue: .main) { [weak self] _ in
            self?.applyHotKey()
        }

        // 首次启动：打开设置窗口引导授权（Finder 扩展 + 根目录授权说明）
        if !AppSettings.shared.isLaunchedBefore {
            AppSettings.shared.isLaunchedBefore = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openSettings(initialTab: .about)
            }
        }

        // 调试回放：启动参数自触发（多次尝试，避免首次容器访问阻塞导致漏触发）
        if ProcessInfo.processInfo.arguments.contains("-debugDragTest") {
            for delay in [1.5, 4.0, 8.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard ScreenshotCoordinator.shared.isIdle else { return }
                    DebugTrace.log("launch-arg 触发回放 (\(delay)s)")
                    ScreenshotCoordinator.shared.beginDebugDragTest()
                }
            }
        }

        // 启动反馈：帮助用户定位菜单栏图标
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Toast.shared.show("MenuShot 已启动：点击菜单栏右上角的取景框图标使用")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {}

    /// 菜单栏应用没有主窗口：用户双击 App（或重复启动）时打开设置窗口作为反馈
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(initialTab: .general)
        return false
    }

    // MARK: - 状态栏菜单

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        if let button = item.button {
            button.image = StatusBarIcon.image()
            button.toolTip = "MenuShot（截图 · 新建文件 · 设置）"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let shot = NSMenuItem(title: "截图", action: #selector(startScreenshot), keyEquivalent: "")
        shot.target = self
        shot.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        menu.addItem(shot)

        let newFile = NSMenuItem(title: "新建文件", action: nil, keyEquivalent: "")
        newFile.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        newFile.submenu = NSMenu()
        menu.addItem(newFile)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettingsMenu), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 MenuShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        statusMenu = menu
        // 自检上报：供设置页显示「状态栏图标」状态
        Shared.sharedDefaults?.set(item.button != nil, forKey: "statusItemOK")
    }

    /// 菜单每次打开时重建「新建文件」子菜单（跟随设置中的格式列表）
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let newFile = menu.items.first(where: { $0.title == "新建文件" }) else { return }
        let sub = NSMenu()
        for format in AppSettings.shared.formats {
            let item = NSMenuItem(title: format.name, action: #selector(createFileInChosenFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = format
            item.image = Self.icon(for: format)
            sub.addItem(item)
        }
        newFile.submenu = sub
    }

    static func icon(for format: FileFormat) -> NSImage? {
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

    // MARK: - 动作

    @objc private func startScreenshot() {
        ScreenshotCoordinator.shared.begin()
    }

    @objc private func createFileInChosenFolder(_ sender: NSMenuItem) {
        guard let format = sender.representedObject as? FileFormat else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "在这里新建"
        panel.message = "选择「\(format.name).\(format.ext)」的保存位置"
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        var needsStop = false
        if dir.startAccessingSecurityScopedResource() { needsStop = true }
        defer { if needsStop { dir.stopAccessingSecurityScopedResource() } }

        do {
            let url = try NewFileService.create(in: dir, format: format)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            Toast.shared.show("已创建 \(url.lastPathComponent)")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openSettingsMenu() {
        openSettings(initialTab: .general)
    }

    func openSettings(initialTab: SettingsWindowController.Tab) {
        SettingsWindowController.shared.show(tab: initialTab)
    }

    // MARK: - 快捷键

    private func applyHotKey() {
        let s = AppSettings.shared
        // 截图快捷键（可在设置中录制）
        if let old = screenshotHotKeyID { HotKeyCenter.shared.unregister(id: old); screenshotHotKeyID = nil }
        if s.hotKeyEnabled {
            screenshotHotKeyID = HotKeyCenter.shared.register(keyCode: s.hotKeyCode,
                                                              carbonModifiers: s.hotKeyCarbonMods) { [weak self] in
                DispatchQueue.main.async { self?.startScreenshot() }
            }
        }
        // 主菜单呼出快捷键（托盘图标被系统隐藏时的保底入口）
        if let old = menuPopupHotKeyID { HotKeyCenter.shared.unregister(id: old); menuPopupHotKeyID = nil }
        menuPopupHotKeyID = HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_M),
                                                         carbonModifiers: UInt32(optionKey) | UInt32(cmdKey)) { [weak self] in
            DispatchQueue.main.async { self?.popupMenuAtCursor() }
        }
    }

    /// 在鼠标位置弹出主菜单（与托盘菜单内容一致）
    @objc private func popupMenuAtCursor() {
        guard let menu = statusMenu else { return }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: mouse, in: nil)
    }

    // MARK: - Finder 扩展协作：创建请求 + 结果展示
    //
    // 负载（请求/结果）经 App Group defaults 传递；分布式通知仅作信号。
    // 注意：DistributedNotificationCenter 必须使用 selector 式监听（block 式 API 不投递）。

    private func listenForExtensionEvents() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(onCreateRequest),
                           name: .init(Shared.distCreateRequest), object: nil)
        center.addObserver(self, selector: #selector(onCreateOK),
                           name: .init(Shared.distCreateOK), object: nil)
        center.addObserver(self, selector: #selector(onCreateFail),
                           name: .init(Shared.distCreateFail), object: nil)
        // 调试回放触发器（真实处理链路验证）
        center.addObserver(self, selector: #selector(debugDragTest),
                           name: .init("com.cgbin.menushot.debug.dragTest"), object: nil)
    }

    @objc private func debugDragTest() {
        DebugTrace.log("收到回放触发通知")
        ScreenshotCoordinator.shared.beginDebugDragTest()
    }

    @objc private func onCreateRequest() {
        NSLog("MenuShot: [诊断] 收到创建请求信号")
        handleCreateRequests()
    }

    @objc private func onCreateOK() {
        guard let result = Shared.loadResult(), result.ok,
              result.source != "app", let path = result.path else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        Toast.shared.show("已创建 \(url.lastPathComponent)")
    }

    @objc private func onCreateFail() {
        guard let result = Shared.loadResult(), !result.ok, result.source != "app" else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = result.title
        alert.informativeText = result.message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 消费扩展的创建请求：用主应用的安全作用域授权写文件
    private func handleCreateRequests() {
        let requests = Shared.takePendingRequests()
        Shared.appendExtDebug("app: 收到 \(requests.count) 个请求, 书签=\(RootAuthorizer.isAuthorized ? "OK" : "无")")
        guard !requests.isEmpty else { return }

        var grantedRoot: URL?
        if let root = Shared.resolveWatchRoot() {
            if root.startAccessingSecurityScopedResource() {
                grantedRoot = root
            } else {
                Shared.appendExtDebug("app: 书签作用域激活失败")
            }
        }
        defer {
            grantedRoot?.stopAccessingSecurityScopedResource()
        }

        let formats = AppSettings.shared.formats.isEmpty ? Shared.loadFormats() : AppSettings.shared.formats
        for request in requests {
            let format = formats.first { $0.ext == request.ext }
                ?? FileFormat(name: request.ext.uppercased(), ext: request.ext, template: "")
            process(request: request, dir: URL(fileURLWithPath: request.dirPath), format: format)
        }
    }

    /// 处理单个创建请求；权限类失败时提供「就地授权 + 自动重试」闭环
    private func process(request: Shared.CreateRequest, dir: URL, format: FileFormat) {
        do {
            try createAndAnnounce(dir: dir, format: format)
            return
        } catch {
            // 我们自己的错误枚举转 NSError 后 code=0，需按类型判断是否可恢复
            let ns = error as NSError
            let isPermission: Bool
            if let nf = error as? NewFileService.NewFileError, case .readOnly = nf {
                isPermission = true
            } else {
                isPermission = ns.domain == NSCocoaErrorDomain
                    && (ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError)
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Shared.appendExtDebug("app: 创建失败 domain=\(ns.domain) code=\(ns.code) dir=\(dir.path)")

            // 跨 App 数据：不可恢复，明确告知即可（避免反复触发系统授权弹窗）
            if let nf = error as? NewFileService.NewFileError, case .otherAppData = nf {
                showAlert(title: "无法在其他 App 的数据文件夹中新建", message: message)
                storeFailure(format: format, message: message)
                return
            }

            if isPermission {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "该文件夹需要授权后才能新建文件"
                alert.informativeText = "点击「授权此文件夹并重试」，在弹出的面板中确认即可（已定位到个人主目录，授权一次长期有效，桌面/文稿/下载及全部子目录可用）。"
                alert.addButton(withTitle: "授权此文件夹并重试")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn {
                    // 默认定位到个人主目录：一次授权覆盖桌面/文稿/下载及全部子目录
                    let home = URL(fileURLWithPath: "/Users/\(NSUserName())")
                    let target = dir.standardizedFileURL.path.hasPrefix(home.path) ? dir : home
                    switch RootAuthorizer.authorize(defaultDirectory: target) {
                    case .success(let chosen):
                        // 关键：用「刚授权的 URL」激活安全作用域再重试（裸路径激活无效）
                        let covered = dir.standardizedFileURL.path.hasPrefix(chosen.standardizedFileURL.path)
                        guard covered else {
                            let text = "您授权的「\(chosen.lastPathComponent)」不是目标文件夹的上级目录，请重试并选择目标文件夹本身或其上级（建议个人主目录）。"
                            Shared.appendExtDebug("app: 授权目录未覆盖目标 chosen=\(chosen.path)")
                            showAlert(title: "授权目录不匹配", message: text)
                            storeFailure(format: format, message: text)
                            return
                        }
                        var needsStop = chosen.startAccessingSecurityScopedResource()
                        defer { if needsStop { chosen.stopAccessingSecurityScopedResource() } }
                        do {
                            try createAndAnnounce(dir: dir, format: format)
                            return
                        } catch {
                            let m = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                            Shared.appendExtDebug("app: 授权后重试仍失败 \(m)")
                            showAlert(title: "创建仍失败", message: "授权已生效，但创建仍然失败：\n\(m)")
                            storeFailure(format: format, message: m)
                            return
                        }
                    case .failure(let error):
                        guard (error as NSError).code != RootAuthorizer.cancelledCode else { break }
                        NSAlert(error: error).runModal()
                    }
                }
                storeFailure(format: format, message: message)
                return
            }

            showAlert(title: "新建 \(format.name) 失败", message: message)
            storeFailure(format: format, message: message)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func createAndAnnounce(dir: URL, format: FileFormat) throws {
        let url = try NewFileService.create(in: dir, format: format)
        Shared.storeResult(.init(ok: true, path: url.path, title: "", message: "", source: "app"))
        DistributedNotificationCenter.default().postNotificationName(
            .init(Shared.distCreateOK), object: nil, userInfo: nil, deliverImmediately: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        Toast.shared.show("已创建 \(url.lastPathComponent)")
    }

    private func storeFailure(format: FileFormat, message: String) {
        Shared.storeResult(.init(ok: false, path: nil,
                                 title: "新建 \(format.name) 失败",
                                 message: message,
                                 source: "app"))
        DistributedNotificationCenter.default().postNotificationName(
            .init(Shared.distCreateFail), object: nil, userInfo: nil, deliverImmediately: true)
    }

    // MARK: - 默认值

    private func registerDefaultsOnce() {
        if Shared.sharedDefaults?.data(forKey: Shared.keyFormats) == nil {
            Shared.storeFormats(FileFormat.defaults)
        }
    }
}
