import Foundation

/// 主应用与 Finder Sync 扩展共享的常量与配置读写。
/// 数据通过 App Group 容器传递；扩展无需依赖主应用运行即可读取格式列表。
enum Shared {
    static let appGroupID = "group.com.cgbin.menushot"

    static let keyFormats = "fileFormats"
    static let keyWatchRootBookmark = "watchRootBookmark"

    /// 扩展 → 主应用 的分布式通知（仅作信号，负载走 App Group defaults，避免沙盒 userInfo 限制）
    static let distCreateRequest = "com.cgbin.menushot.createRequest"
    static let distCreateOK = "com.cgbin.menushot.fileCreated"
    static let distCreateFail = "com.cgbin.menushot.fileCreateFailed"
    /// 主应用 → 扩展：根目录授权已变更，请重新加载
    static let distWatchRootChanged = "com.cgbin.menushot.watchRootChanged"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// 扩展当前实际监听的根目录（自检上报，供设置页展示诊断）
    static let keyExtensionWatchRoot = "extensionWatchRootPath"

    static func reportExtensionWatchRoot(_ path: String?) {
        sharedDefaults?.set(path, forKey: keyExtensionWatchRoot)
        appendExtDebug("ext init, watch root = \(path ?? "nil(未授权书签)")")
    }

    static func extensionWatchRootPath() -> String? {
        sharedDefaults?.string(forKey: keyExtensionWatchRoot)
    }

    /// 扩展侧调试日志（保留最近 6 条，供设置页诊断）
    static let keyExtDebugLog = "extDebugLog"

    static func appendExtDebug(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let entry = "[\(formatter.string(from: Date()))] \(line)"
        var log = sharedDefaults?.stringArray(forKey: keyExtDebugLog) ?? []
        log.append(entry)
        if log.count > 6 { log.removeFirst(log.count - 6) }
        sharedDefaults?.set(log, forKey: keyExtDebugLog)
    }

    static func extDebugLog() -> [String] {
        sharedDefaults?.stringArray(forKey: keyExtDebugLog) ?? []
    }

    /// 进程内缓存：扩展每次弹出菜单都读一次会反复触发容器访问授权
    private static var cachedFormats: [FileFormat]?

    static func loadFormats() -> [FileFormat] {
        if let cached = cachedFormats { return cached }
        guard let data = sharedDefaults?.data(forKey: keyFormats),
              let list = try? JSONDecoder().decode([FileFormat].self, from: data),
              !list.isEmpty else {
            cachedFormats = FileFormat.defaults
            return cachedFormats!
        }
        cachedFormats = list
        return list
    }

    static func invalidateFormatsCache() {
        cachedFormats = nil
    }

    static func storeFormats(_ formats: [FileFormat]) {
        guard let data = try? JSONEncoder().encode(formats) else { return }
        sharedDefaults?.set(data, forKey: keyFormats)
    }

    /// 解析主应用保存的「新建文件」根目录书签（Powerbox 安全作用域书签）。
    /// 书签指向其他 App 数据时作废返回 nil（跨 App 写入会被系统反复拦截）。
    static func resolveWatchRoot() -> URL? {
        guard let data = sharedDefaults?.data(forKey: keyWatchRootBookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            appendExtDebug("app: 书签解析失败")
            return nil
        }
        if NewFileService.isOtherAppData(url) {
            appendExtDebug("app: 书签指向其他 App 数据，已忽略：\(url.path)")
            return nil
        }
        return url
    }

    // MARK: - 创建请求队列（扩展 → 主应用，经 App Group 传递，避开分布式通知 userInfo 的沙盒限制）

    static let keyPendingRequests = "newFilePendingRequests"
    static let keyLastResult = "newFileLastResult"

    struct CreateRequest: Codable {
        var id: String
        var dirPath: String
        var ext: String
    }

    struct CreateResult: Codable {
        var ok: Bool
        var path: String?
        var title: String
        var message: String
        /// "app" = 主应用处理（自己负责展示）；nil/"extension" = 扩展兜底处理，需主应用展示
        var source: String?
    }

    static func enqueueCreateRequest(_ request: CreateRequest) {
        var list = pendingRequests()
        list.append(request)
        if let data = try? JSONEncoder().encode(list) {
            sharedDefaults?.set(data, forKey: keyPendingRequests)
        }
    }

    static func pendingRequests() -> [CreateRequest] {
        guard let data = sharedDefaults?.data(forKey: keyPendingRequests),
              let list = try? JSONDecoder().decode([CreateRequest].self, from: data) else { return [] }
        return list
    }

    /// 主应用取走全部请求；若某请求 3.5s 后仍在队列（主应用离线），扩展会自行兜底创建
    static func takePendingRequests() -> [CreateRequest] {
        let list = pendingRequests()
        sharedDefaults?.removeObject(forKey: keyPendingRequests)
        return list
    }

    @discardableResult
    static func removeCreateRequest(id: String) -> Bool {
        var list = pendingRequests()
        let before = list.count
        list.removeAll { $0.id == id }
        guard list.count != before else { return false }
        if let data = try? JSONEncoder().encode(list) {
            sharedDefaults?.set(data, forKey: keyPendingRequests)
        }
        return true
    }

    static func storeResult(_ result: CreateResult) {
        if let data = try? JSONEncoder().encode(result) {
            sharedDefaults?.set(data, forKey: keyLastResult)
        }
    }

    static func loadResult() -> CreateResult? {
        guard let data = sharedDefaults?.data(forKey: keyLastResult) else { return nil }
        return try? JSONDecoder().decode(CreateResult.self, from: data)
    }
}

/// 一个可新建的文件类型：显示名、扩展名、初始模板内容。
struct FileFormat: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var ext: String
    var template: String

    static let defaults: [FileFormat] = [
        FileFormat(name: "Markdown", ext: "md", template: "# 未命名\n\n"),
        FileFormat(name: "纯文本", ext: "txt", template: ""),
        FileFormat(name: "JSON", ext: "json", template: "{\n    \n}\n"),
        FileFormat(name: "YAML", ext: "yaml", template: "---\n"),
        FileFormat(name: "XML", ext: "xml",
                   template: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root>\n    \n</root>\n"),
        FileFormat(name: "HTML", ext: "html",
                   template: """
                   <!DOCTYPE html>
                   <html lang="zh-CN">
                   <head>
                       <meta charset="UTF-8">
                       <title>未命名</title>
                   </head>
                   <body>

                   </body>
                   </html>
                   """),
        FileFormat(name: "CSV", ext: "csv", template: "名称,数量\n,"),
        FileFormat(name: "Swift", ext: "swift", template: "import Foundation\n\n"),
        FileFormat(name: "Python", ext: "py",
                   template: "#!/usr/bin/env python3\n\n\ndef main():\n    pass\n\n\nif __name__ == \"__main__\":\n    main()\n"),
    ]
}

/// 新建文件核心逻辑：目标目录校验、重名避让、模板写入。
/// 主应用（状态栏菜单）与 Finder 扩展共用。
enum NewFileService {

    enum NewFileError: LocalizedError {
        case notDirectory
        case otherAppData
        case readOnly(String)

        var errorDescription: String? {
            switch self {
            case .notDirectory:
                return "目标位置不是有效文件夹"
            case .otherAppData:
                return "该文件夹属于其他 App 的专属数据（如 QQ、微信等的沙盒文件夹）。macOS 出于隐私保护不允许跨 App 写入，无法在这里新建文件。\n请在普通文件夹（桌面、文稿、下载、您的项目目录等）中使用。"
            case .readOnly(let reason):
                return "该文件夹无法写入（\(reason)）。可在弹出的提示中点击「授权此文件夹并重试」完成授权。"
            }
        }
    }

    /// 在 dir 中生成不重名的文件 URL：未命名.md / 未命名 2.md …
    static func uniqueURL(in dir: URL, ext: String) -> URL {
        let base = "未命名"
        var index = 1
        var url = dir.appendingPathComponent("\(base).\(ext)")
        let fm = FileManager.default
        while fm.fileExists(atPath: url.path) {
            index += 1
            url = dir.appendingPathComponent("\(base) \(index).\(ext)")
        }
        return url
    }

    /// 右键目标可能是文件本身，此时应落到其所在文件夹。
    static func directory(forTarget target: URL) -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
            return target
        }
        return target.deletingLastPathComponent()
    }

    /// 创建文件；失败抛出可读错误。
    @discardableResult
    static func create(in dir: URL, format: FileFormat) throws -> URL {
        // 其他 App 的沙盒数据：必须在任何文件系统访问（stat 也会触发系统弹窗）之前拦截
        if isOtherAppData(dir) {
            Shared.appendExtDebug("app: 目标是其他 App 数据，拒绝 dir=\(dir.path)")
            throw NewFileError.otherAppData
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw NewFileError.notDirectory
        }
        let url = uniqueURL(in: dir, ext: format.ext)
        do {
            try format.template.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // 只读目录 / 无权限 / 磁盘只读等，统一转成用户可读提示
            let ns = error as NSError
            let reason: String
            if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError {
                if isProtectedHomeSubdir(dir), Shared.resolveWatchRoot() == nil {
                    reason = "「桌面 / 文稿」受 macOS 保护：请打开 MenuShot 设置 → 新建文件 →「选择根目录…」授权个人主目录（一次授权，桌面、文稿及全部子目录可用）"
                } else {
                    reason = "没有写入权限"
                }
            } else if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
                reason = "磁盘空间不足"
            } else {
                reason = ns.localizedDescription
            }
            throw NewFileError.readOnly(reason)
        }
        return url
    }

    /// 桌面 / 文稿：Apple 沙盒无直接 entitlement，必须经根目录授权（安全作用域）覆盖
    static func isProtectedHomeSubdir(_ dir: URL) -> Bool {
        let home = "/Users/\(NSUserName())"
        let path = dir.standardizedFileURL.path
        return path.hasPrefix(home + "/Desktop") || path.hasPrefix(home + "/Documents")
    }

    /// 其他 App 的沙盒数据（QQ/微信等的容器、iCloud 应用数据）：跨 App 写入会被 macOS 反复拦截
    static func isOtherAppData(_ dir: URL) -> Bool {
        let path = dir.standardizedFileURL.path
        guard path.contains("/Library/Containers/")
            || path.contains("/Library/Group Containers/")
            || path.contains("/Library/Mobile Documents/") else { return false }
        // 自己的容器/群组容器放行
        if path.contains("com.cgbin.menushot") { return false }
        return true
    }
}
