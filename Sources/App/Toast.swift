import AppKit

/// 轻量全局提示气泡：右下角滑入淡出，自动消失。单例复用，不弹模态框。
final class Toast {
    static let shared = Toast()
    private init() {}

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, duration: TimeInterval = 2.0) {
        let target = panel ?? makePanel()
        panel = target
        label?.stringValue = text
        target.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let p = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                p.animator().alphaValue = 0
            }, completionHandler: {
                p.orderOut(nil)
                p.alphaValue = 1
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)

        // 入场：淡入
        let p = target
        p.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating + 10
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hud = HUDEffectView()
        hud.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        self.label = label

        hud.addSubview(label)
        panel.contentView = hud
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: hud.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: hud.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: hud.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: hud.bottomAnchor, constant: -10),
        ])

        if let screen = NSScreen.main {
            let size = hud.fittingSize
            panel.setContentSize(size)
            let frame = NSRect(x: screen.visibleFrame.maxX - size.width - 24,
                               y: screen.visibleFrame.minY + 24,
                               width: size.width,
                               height: size.height)
            panel.setFrame(frame, display: true)
        }
        return panel
    }
}

/// 深色圆角 HUD 背景，编辑器工具条等处复用。
class HUDEffectView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        state = .active
        blendingMode = .behindWindow
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
}
