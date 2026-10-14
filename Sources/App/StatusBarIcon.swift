import AppKit

/// 自绘菜单栏图标：四角取景框 + 中心圆点，线条比 SF Symbol 更粗、更醒目。
/// template 模式自动适配菜单栏明暗模式。
enum StatusBarIcon {

    static func image() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let thickness: CGFloat = 2.0
            let inset: CGFloat = 1.6
            let arm: CGFloat = 4.5
            let path = NSBezierPath()
            path.lineWidth = thickness
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            func corner(_ x: CGFloat, _ y: CGFloat, _ sx: CGFloat, _ sy: CGFloat) {
                path.move(to: NSPoint(x: x + sx * arm, y: y))
                path.line(to: NSPoint(x: x, y: y))
                path.line(to: NSPoint(x: x, y: y + sy * arm))
            }
            let w = rect.width, h = rect.height
            corner(inset, inset, 1, 1)          // 左下
            corner(w - inset, inset, -1, 1)     // 右下
            corner(inset, h - inset, 1, -1)     // 左上
            corner(w - inset, h - inset, -1, -1)// 右上
            path.stroke()

            let r: CGFloat = 2.4
            NSBezierPath(ovalIn: NSRect(x: w / 2 - r, y: h / 2 - r, width: r * 2, height: r * 2)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
