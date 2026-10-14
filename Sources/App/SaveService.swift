import AppKit
import UniformTypeIdentifiers

/// 截图保存：默认目录（安全作用域书签 / Pictures 回退）与另存为面板。
enum SaveService {

    static func defaultFileName(jpeg: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "截图 \(formatter.string(from: Date())).\(jpeg ? "jpg" : "png")"
    }

    /// 保存到默认目录；返回保存位置或错误。
    static func saveToDefaultDirectory(rep: NSBitmapImageRep, jpeg: Bool) -> Result<URL, Error> {
        let settings = AppSettings.shared
        guard let resolved = settings.resolveDefaultSaveDir(startAccess: true) else {
            return .failure(NSError(domain: "MenuShot", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "无法确定默认保存目录"]))
        }
        let dir = resolved.url
        defer { if resolved.needsStop { dir.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(defaultFileName(jpeg: jpeg))
            guard let data = rep.representation(using: jpeg ? .jpeg : .png,
                                                properties: jpeg ? [.compressionFactor: 0.92] : [:]) else {
                return .failure(NSError(domain: "MenuShot", code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "图片编码失败"]))
            }
            try data.write(to: url)
            return .success(url)
        } catch {
            return .failure(error)
        }
    }

    /// 另存为：NSSavePanel（沙盒下由 Powerbox 授权，无需额外权限）。返回是否完成了保存。
    @discardableResult
    static func saveAs(rep: NSBitmapImageRep) -> Bool {
        let panel = NSSavePanel()
        panel.title = "另存截图"
        panel.nameFieldStringValue = defaultFileName(jpeg: AppSettings.shared.saveAsJPEG)
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        let ext = url.pathExtension.lowercased()
        let type: NSBitmapImageRep.FileType = (ext == "jpg" || ext == "jpeg") ? .jpeg : .png
        do {
            guard let data = rep.representation(using: type,
                                                properties: type == .jpeg ? [.compressionFactor: 0.92] : [:]) else {
                throw NSError(domain: "MenuShot", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "图片编码失败"])
            }
            try data.write(to: url)
            Toast.shared.show("已保存：\(url.lastPathComponent)")
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }
}
