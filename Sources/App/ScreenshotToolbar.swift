import AppKit

/// 截图编辑工具（none = 指针/选择模式）
enum ShotTool: Equatable {
    case none, rectangle, ellipse, arrow, line, pen, text, mosaic
}

/// 工具条回调
protocol EditorToolbarDelegate: AnyObject {
    func toolbarDidChangeTool(_ tool: ShotTool)
    func toolbarDidRequestStyle(_ sender: NSButton)
    func toolbarDidRequestOCR()
    func toolbarDidRequestPin()
    func toolbarDidRequestUndo()
    func toolbarDidRequestRedo()
    func toolbarDidRequestSave()
    func toolbarDidRequestSaveAs()
    func toolbarDidRequestCancel()
    func toolbarDidRequestConfirm()
}

/// 工具按钮：悬停浅高亮 + 选中强调色胶囊（macOS 原生分段控件质感）
final class ToolbarButton: NSButton {

    private var symbolName: String?

    var isSelected = false {
        didSet { updateBackground() }
    }

    private var hovering = false {
        didSet { updateBackground() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        contentTintColor = .white
        setFrameSize(NSSize(width: 32, height: 30))
        updateBackground()
    }

    /// 高度自适应时同步缩放符号（文字模式缩放字号）
    func applySymbol(size: CGFloat) {
        if displayTitle != nil {
            font = NSFont.systemFont(ofSize: size, weight: .medium)
            return
        }
        guard let name = symbolName else { return }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(config)
    }

    override func layout() {
        super.layout()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func updateBackground() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            if isSelected {
                layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            } else if hovering {
                layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }
}

/// 完整截图工具条（Apple 原生质感）：
/// 指针 | 钉图 | 矩形 椭圆 箭头 直线 | 画笔 文本 马赛克 颜色 | OCR | 撤销 重做 | 保存 另存 | 取消 确认
final class EditorToolbarView: NSView {

    weak var delegate: EditorToolbarDelegate?

    private(set) var currentTool: ShotTool = .none
    private var toolButtons: [ShotTool: ToolbarButton] = [:]
    private var undoButton: ToolbarButton?
    private var redoButton: ToolbarButton?
    private let colorButton = ToolbarButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 深色实底 + 细描边 + 柔和投影（对照参考图的悬浮条质感）
        layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.97).cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 12
        layer?.shadowOffset = NSSize(width: 0, height: -5)
        buildButtons()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildButtons() {
        var items: [NSView] = []

        func add(_ symbol: String, _ tip: String, tint: NSColor = .white,
                 tool: ShotTool? = nil, action: Selector? = nil) -> ToolbarButton {
            let button = ToolbarButton(frame: .zero)
            button.toolTip = tip
            button.setSymbol(symbol)
            button.contentTintColor = tint
            if let tool = tool {
                toolButtons[tool] = button
                button.target = self
                button.action = #selector(toolClicked(_:))
            } else if let action = action {
                button.target = self
                button.action = action
            }
            items.append(button)
            return button
        }

        func separator() {
            let box = NSBox()
            box.boxType = .separator
            box.isTransparent = false
            items.append(box)
        }

        add("arrow.up.left", "选择 / 移动标注", tool: .none)
        separator()
        add("pin.fill", "钉图", action: #selector(pinClicked))
        separator()
        add("rectangle", "矩形", tool: .rectangle)
        add("oval", "椭圆", tool: .ellipse)
        add("arrow.up.right", "箭头", tool: .arrow)
        add("line.diagonal", "直线", tool: .line)
        separator()
        add("pencil.tip", "画笔", tool: .pen)
        add("textformat", "文本（双击已绘文本可再编辑）", tool: .text)
        add("checkerboard.rectangle", "马赛克", tool: .mosaic)

        colorButton.toolTip = "颜色 / 粗细（选中标注时直接改它的样式）"
        colorButton.setSymbol("paintpalette.fill", size: 13)
        colorButton.target = self
        colorButton.action = #selector(styleClicked)
        items.append(colorButton)

        separator()
        add("text.viewfinder", "提取文本 (OCR)", action: #selector(ocrClicked))
        separator()
        undoButton = add("arrow.uturn.backward", "撤销 (⌘Z)", action: #selector(undoClicked))
        redoButton = add("arrow.uturn.forward", "重做 (⇧⌘Z)", action: #selector(redoClicked))
        separator()
        add("square.and.arrow.down", "保存 (⌘S)", action: #selector(saveClicked))
        add("square.and.arrow.down.on.square", "另存为… (⇧⌘S)", action: #selector(saveAsClicked))
        separator()
        add("xmark", "取消 (Esc)", tint: .systemRed, action: #selector(cancelClicked))
        add("checkmark", "完成并复制 (Enter)", tint: .systemGreen, action: #selector(confirmClicked))

        // 手工确定性布局：固定尺寸逐个排布（不依赖 fittingSize 估算，宽度精确）
        let inset: CGFloat = 9
        let gap: CGFloat = 3
        let height: CGFloat = 44
        var x = inset
        for item in items {
            if let box = item as? NSBox {
                item.frame = NSRect(x: x, y: (height - 20) / 2, width: 1, height: 20)
                x += 1 + gap
            } else {
                item.frame = NSRect(x: x, y: (height - 30) / 2, width: 32, height: 30)
                x += 32 + gap
            }
            addSubview(item)
        }
        x += inset - gap
        setFrameSize(NSSize(width: x, height: height))
        computedSize = frame.size
        refreshHistory(canUndo: false, canRedo: false)
    }

    private var computedSize: NSSize = .zero
    var idealSize: NSSize { computedSize }

    /// 等比缩放整条工具条（宽高都随选区变化，永不超出选区）
    func applyScale(_ scale: CGFloat) {
        let s = max(0.3, min(1, scale))
        guard abs(s - (computedSize.width / 638.0)) > 0.01 || frame.size.height != 44 * s else { return }
        let inset = 9 * s
        let gap = 3 * s
        let height = 44 * s
        var x = inset
        for view in subviews {
            if let box = view as? NSBox {
                let bh = 20 * s
                view.frame = NSRect(x: x, y: (height - bh) / 2, width: 1, height: bh)
                x += 1 + gap
            } else if let button = view as? ToolbarButton {
                let bw = 32 * s
                let bh = 30 * s
                button.frame = NSRect(x: x, y: (height - bh) / 2, width: bw, height: bh)
                button.applySymbol(size: 14 * s)
                x += bw + gap
            }
        }
        x += inset - gap
        setFrameSize(NSSize(width: x, height: height))
        computedSize = frame.size
    }

    // MARK: 状态刷新

    func setTool(_ tool: ShotTool) {
        currentTool = tool
        for (t, button) in toolButtons {
            button.isSelected = (t == tool)
        }
    }

    func setColor(_ color: NSColor) {
        // 色板按钮：用当前颜色的小圆点呈现（图标 + 底色微染）
        colorButton.layer?.backgroundColor = color.withAlphaComponent(0.35).cgColor
        colorButton.contentTintColor = color
    }

    func refreshHistory(canUndo: Bool, canRedo: Bool) {
        undoButton?.isEnabled = canUndo
        redoButton?.isEnabled = canRedo
        undoButton?.contentTintColor = canUndo ? .white : NSColor.white.withAlphaComponent(0.3)
        redoButton?.contentTintColor = canRedo ? .white : NSColor.white.withAlphaComponent(0.3)
    }

    // MARK: 事件转发

    @objc private func toolClicked(_ sender: NSButton) {
        let tool = toolButtons.first { $0.value === sender }?.key ?? .none
        delegate?.toolbarDidChangeTool(tool)
    }

    @objc private func styleClicked() { delegate?.toolbarDidRequestStyle(colorButton) }
    @objc private func ocrClicked() { delegate?.toolbarDidRequestOCR() }
    @objc private func pinClicked() { delegate?.toolbarDidRequestPin() }
    @objc private func undoClicked() { delegate?.toolbarDidRequestUndo() }
    @objc private func redoClicked() { delegate?.toolbarDidRequestRedo() }
    @objc private func saveClicked() { delegate?.toolbarDidRequestSave() }
    @objc private func saveAsClicked() { delegate?.toolbarDidRequestSaveAs() }
    @objc private func cancelClicked() { delegate?.toolbarDidRequestCancel() }
    @objc private func confirmClicked() { delegate?.toolbarDidRequestConfirm() }
}

// MARK: - 颜色 / 粗细弹层

final class StylePickerView: NSView {
    private let onApply: (NSColor, CGFloat) -> Void
    private let widthSlider: NSSlider
    private var currentColor: NSColor

    init(color: NSColor, width: CGFloat, onApply: @escaping (NSColor, CGFloat) -> Void) {
        self.onApply = onApply
        self.currentColor = color
        widthSlider = NSSlider(value: Double(width), minValue: 1, maxValue: 12, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 208, height: 92))
        widthSlider.frame = NSRect(x: 52, y: 14, width: 140, height: 24)

        let colors: [NSColor] = [.black, .white, .systemRed, .systemOrange, .systemYellow, .systemGreen,
                                 .systemTeal, .systemBlue, .systemIndigo, .systemPurple, .systemBrown, .systemGray]
        var x: CGFloat = 16
        for c in colors {
            let swatch = ColorSwatchButton(color: c) { [weak self] in
                guard let self = self else { return }
                self.currentColor = c
                self.onApply(c, self.widthSlider.doubleValue)
            }
            swatch.frame = NSRect(x: x, y: 52, width: 14, height: 14)
            addSubview(swatch)
            x += 15
        }

        let label = NSTextField(labelWithString: "粗细")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 16, y: 18, width: 34, height: 16)
        addSubview(label)
        addSubview(widthSlider)

        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func widthChanged() {
        onApply(currentColor, widthSlider.doubleValue)
    }
}

final class ColorSwatchButton: NSButton {
    private let apply: () -> Void

    init(color: NSColor, apply: @escaping () -> Void) {
        self.apply = apply
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func clicked() { apply() }
}

// MARK: - OCR 结果窗

final class OCRResultWindow: NSPanel {
    private weak var resultTextView: NSTextView?

    init(text: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                   styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "提取的文本"
        level = .floating + 5
        isReleasedWhenClosed = false

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 240))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.font = .systemFont(ofSize: 13)
        textView.string = text
        textView.isSelectable = true
        scrollView.documentView = textView
        resultTextView = textView

        let copy = NSButton(title: "复制全部", target: self, action: #selector(copyAll))
        copy.bezelStyle = .rounded
        copy.frame = NSRect(x: 260, y: 6, width: 100, height: 28)
        copy.autoresizingMask = [.minXMargin, .minYMargin]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 300))
        container.addSubview(scrollView)
        container.addSubview(copy)
        contentView = container
    }

    func center(in frame: NSRect) {
        setFrameOrigin(NSPoint(x: frame.midX - frame.width / 2,
                               y: frame.midY - frame.height / 2))
    }

    @objc private func copyAll() {
        guard let textView = resultTextView else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(textView.string, forType: .string)
        Toast.shared.show("已复制")
    }

    override var canBecomeKey: Bool { true }
}
