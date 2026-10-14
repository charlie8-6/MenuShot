import AppKit

/// 「新建文件」根目录授权：面板选择 → 安全作用域书签 → 探针验证 → 通知扩展热刷新。
/// 供设置页与「创建失败就地恢复」共用。
enum RootAuthorizer {

    static let cancelledCode = 100

    /// 弹出授权面板（默认定位到 defaultDirectory），成功返回授权的目录。
    /// 失败返回错误；用户取消返回 cancelledCode 错误（调用方可静默处理）。
    static func authorize(defaultDirectory url: URL?) -> Result<URL, Error> {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = "授权此目录"
        panel.message = "选择可在其中右键新建文件的目录（建议个人主目录，一次覆盖桌面、文稿、下载及全部子目录）"
        if let url = url {
            panel.directoryURL = url
        }
        guard panel.runModal() == .OK, let chosen = panel.url else {
            return .failure(NSError(domain: "MenuShot", code: cancelledCode,
                                    userInfo: [NSLocalizedDescriptionKey: "已取消授权"]))
        }

        // 其他 App 的沙盒数据不可作为授权根目录（macOS 禁止跨 App 写入，授权也会被反复拦截）
        if NewFileService.isOtherAppData(chosen) {
            return .failure(NSError(domain: "MenuShot", code: 101,
                                    userInfo: [NSLocalizedDescriptionKey: NewFileService.NewFileError.otherAppData.localizedDescription]))
        }

        do {
            let data = try chosen.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
            Shared.sharedDefaults?.set(data, forKey: Shared.keyWatchRootBookmark)
            Shared.appendExtDebug("app: 书签已保存 root=\(chosen.path)")
        } catch {
            Shared.appendExtDebug("app: 书签创建失败 \(error.localizedDescription)")
            return .failure(error)
        }

        // 探针验证：真实写一个临时文件，确认沙盒写权限生效
        var needsStop = chosen.startAccessingSecurityScopedResource()
        defer { if needsStop { chosen.stopAccessingSecurityScopedResource() } }
        do {
            let probe = chosen.appendingPathComponent(".menushot-probe-\(Int(Date().timeIntervalSince1970))")
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
        } catch {
            Shared.appendExtDebug("app: 探针写入失败 \(error.localizedDescription)")
            return .failure(error)
        }

        // 通知扩展热刷新监听目录
        DistributedNotificationCenter.default().postNotificationName(
            .init(Shared.distWatchRootChanged), object: nil, userInfo: nil, deliverImmediately: true)
        Shared.appendExtDebug("app: 授权完成并验证可写 ✓")
        return .success(chosen)
    }

    /// 当前是否已完成授权（书签存在且可解析）
    static var isAuthorized: Bool { Shared.resolveWatchRoot() != nil }
}
