import AppKit

// 入口：菜单栏应用，无 Dock 图标（LSUIElement）
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
