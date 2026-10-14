import AppKit

/// 钉图窗口：无边框悬浮面板，可拖动；关闭方式 = 右上 ✕ 徽章（常显）/ 双击 / 右键。
final class PinWindowController: NSPanel {
    init(image: NSImage, pixelSize: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: image.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        let view = PinContentView(frame: NSRect(origin: .zero, size: image.size), image: image)
        contentView = view
    }

    func popIn(at frame: NSRect) {
        setFrame(frame, display: true)
        alphaValue = 0
        orderFrontRegardless()
        contentView?.layer?.transform = CATransform3DMakeScale(0.92, 0.92, 1)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
        if let layer = contentView?.layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.22)
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    static func pin(image: CGImage, scale: CGFloat, near frame: NSRect) {
        let pixelSize = NSSize(width: image.width, height: image.height)
        var pts = NSSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        // 过大时缩到可视区 80%
        if let screen = NSScreen.main {
            let maxW = screen.visibleFrame.width * 0.8
            let maxH = screen.visibleFrame.height * 0.8
            if pts.width > maxW || pts.height > maxH {
                let factor = min(maxW / pts.width, maxH / pts.height)
                pts = NSSize(width: pts.width * factor, height: pts.height * factor)
            }
        }
        let controller = PinWindowController(image: NSImage(cgImage: image, size: pts), pixelSize: pixelSize)
        var origin = frame.origin
        origin.x = min(max(origin.x, NSScreen.main?.visibleFrame.minX ?? 0),
                       (NSScreen.main?.visibleFrame.maxX ?? origin.x + pts.width) - pts.width)
        origin.y = max(origin.y - 40, (NSScreen.main?.visibleFrame.minY ?? 0))
        let target = NSRect(origin: origin, size: pts)
        controller.popIn(at: target)
        PinManager.shared.add(controller)
    }
}

/// 管理所有钉图窗口（保活，避免被释放）
final class PinManager {
    static let shared = PinManager()
    private init() {}
    private var pins: [PinWindowController] = []
    func add(_ pin: PinWindowController) { pins.append(pin) }
    func remove(_ pin: PinWindowController) { pins.removeAll { $0 === pin } }
    func closeAll() { pins.forEach { $0.close() }; pins.removeAll() }

    /// 调试：把最后一个钉图窗口按真实绘制路径（draw(_:)）导出 PNG，用于验证方向与关闭按钮
    func debugDumpLastView(_ name: String) {
        guard let pin = pins.last, let view = pin.contentView else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: max(1, Int(size.width * scale)),
                                   pixelsHigh: max(1, Int(size.height * scale)),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("menushot_dumps", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? png.write(to: base.appendingPathComponent("\(name).png"))
        DebugTrace.log("dump[\(name)] pin view \(Int(size.width))x\(Int(size.height))")
    }
}

final class PinContentView: NSView {
    private let cgImage: CGImage?
    private let closeButton: NSButton

    init(frame: NSRect, image: NSImage) {
        self.cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let button = NSButton()
        button.isBordered = false
        button.wantsLayer = true
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭钉图")?
            .withSymbolConfiguration(config)
        button.contentTintColor = .white
        button.toolTip = "关闭钉图（双击图片或右键也可关闭）"
        // 深色圆底徽章 + 细白描边：浅色/深色截图上都清晰可辨；悬停变红提示可点
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        button.layer?.cornerRadius = 12
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.65).cgColor
        button.frame = NSRect(x: frame.width - 30, y: 6, width: 24, height: 24)
        self.closeButton = button
        super.init(frame: frame)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        button.target = self
        button.action = #selector(closePin)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // flipped 视图必须显式翻转绘制位图：NSImage.draw(in:) 在这里会把整张图上下颠倒（已实测确认）
        guard let ctx = NSGraphicsContext.current else { return }
        if let cg = cgImage {
            FlippedImageDrawing.draw(cg, in: bounds, ctx: ctx.cgContext)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["zone"] as? String == "close" {
            closeButton.layer?.backgroundColor = NSColor.systemRed.cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["zone"] as? String == "close" {
            closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { closePin(); return }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) { closePin() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: ["zone": "view"]))
        addTrackingArea(NSTrackingArea(rect: closeButton.frame,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: ["zone": "close"]))
    }

    @objc private func closePin() {
        guard let panel = window as? PinWindowController else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.close()
            PinManager.shared.remove(panel)
        })
    }

    override var isFlipped: Bool { true }
}
