import AppKit

// 生成 MenuShot 应用图标：蓝紫渐变圆角矩形 + 取景框符号
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(roundedRect: rect, xRadius: 180, yRadius: 180)
path.addClip()
let gradient = NSGradient(starting: NSColor(red: 0.16, green: 0.47, blue: 0.96, alpha: 1),
                          ending: NSColor(red: 0.32, green: 0.24, blue: 0.86, alpha: 1))!
gradient.draw(in: path, angle: -70)

if let symbol = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 430, weight: .medium)) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (CGFloat(size) - s.width) / 2,
                           y: (CGFloat(size) - s.height) / 2,
                           width: s.width, height: s.height),
                from: .zero, operation: .sourceOver, fraction: 1)
}
image.unlockFocus()

let fm = FileManager.default
let iconset = "icon.iconset"
try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for scale in [1, 2] {
    for base in [16, 32, 128, 256, 512] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: base, height: base)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: base, height: base))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { continue }
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png.write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
    }
}
print("iconset done")
