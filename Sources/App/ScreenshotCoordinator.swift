import AppKit
import CoreGraphics

/// 截图流程编排：权限检查 → 各显示器快照 → 覆盖层（框选 + 就地编辑）。
final class ScreenshotCoordinator {
    static let shared = ScreenshotCoordinator()
    private init() {}

    private var overlays: [SelectionOverlayController] = []

    var isActive: Bool { !overlays.isEmpty }
    var isIdle: Bool { overlays.isEmpty }

    /// 是否已引导过用户去系统设置（引导后的再次触发说明权限未生效，需要重启应用）
    private static var hasGuidedOnce = false

    func begin(skipPermissionCheck: Bool = false) {
        guard !isActive else { return }

        // 屏幕录制权限：首次使用时由系统弹出授权（申请时机 = 用户第一次截图）
        guard skipPermissionCheck || CGPreflightScreenCaptureAccess() else {
            showScreenPermissionAlert()
            return
        }

        var captured: [(NSScreen, CGImage)] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let image = CGDisplayCreateImage(displayID) else { continue }
            captured.append((screen, image))
        }
        guard !captured.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "截图失败"
            alert.informativeText = "无法捕获屏幕内容，请检查屏幕录制权限是否已开启。"
            alert.runModal()
            return
        }

        // 每个显示器一个覆盖层窗口；frame 可为负坐标（多屏排列时）
        overlays = captured.map { SelectionOverlayController(screen: $0.0, snapshot: $0.1, coordinator: self) }
        overlays.forEach { $0.show() }
    }

    func cancelAll() {
        dismissAll()
    }

    /// 调试回放：跳过权限检查并自动执行 scripted 拖动序列，导出渲染帧用于实际验证
    func beginDebugDragTest() {
        DebugTrace.log("beginDebugDragTest 进入")
        begin(skipPermissionCheck: true)
        DebugTrace.log("覆盖层数量=\(overlays.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            DebugTrace.log("调用 runDebugDragSequence")
            self?.overlays.first?.runDebugDragSequence()
        }
    }

    /// 权限未就绪时的分级引导：第一次指路；之后说明「开启后需重启应用生效」
    private func showScreenPermissionAlert() {
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.alertStyle = .informational

        if ScreenshotCoordinator.hasGuidedOnce {
            alert.messageText = "屏幕录制权限尚未生效"
            alert.informativeText = """
            如果您已在系统设置中打开了 MenuShot 的开关：
            1. 系统会弹出「退出并重新打开」提示 → 点击它即可自动生效；
            2. 没出现提示的话，请完全退出 MenuShot 再重新打开。

            如果开关还没打开：请在列表中打开 /Applications 下 MenuShot 的开关；
            如列表里有重复的 MenuShot 条目，先选中旧条目点「−」移除，只保留一个。
            """
            alert.addButton(withTitle: "重新打开系统设置")
            alert.addButton(withTitle: "退出 MenuShot")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                openScreenRecordingSettings()
            case .alertSecondButtonReturn:
                NSApp.terminate(nil)
            default:
                break
            }
        } else {
            ScreenshotCoordinator.hasGuidedOnce = true
            alert.messageText = "需要「屏幕录制」权限"
            alert.informativeText = "截图功能依赖 macOS 屏幕录制权限。\n请在「系统设置 → 隐私与安全性 → 屏幕录制」中打开 MenuShot 开关。开启后如系统询问，请选择「退出并重新打开」。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                openScreenRecordingSettings()
            }
        }
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func dismissAll() {
        overlays.forEach { $0.dismiss() }
        overlays = []
    }
}
