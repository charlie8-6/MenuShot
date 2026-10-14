import AppKit

/// 单个显示器的截图覆盖层窗口：全屏冻结快照 + 框选 + 就地编辑。
/// 架构：统一命中测试（hitTest）+ 手势状态机（GesturePhase）——
/// 事件处理只做分发，行为集中在各阶段的处理函数中。
final class SelectionOverlayController: NSPanel {

    private let targetScreen: NSScreen
    private let snapshot: CGImage
    private weak var coordinator: ScreenshotCoordinator?
    private var overlayView: OverlayView?

    init(screen: NSScreen, snapshot: CGImage, coordinator: ScreenshotCoordinator) {
        self.targetScreen = screen
        self.snapshot = snapshot
        self.coordinator = coordinator
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isReleasedWhenClosed = false
        self.acceptsMouseMovedEvents = true

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size),
                               snapshot: snapshot,
                               scale: screen.backingScaleFactor,
                               controller: self)
        self.overlayView = view
        contentView = view
    }

    func show() {
        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    func cancelAll() {
        coordinator?.cancelAll()
    }

    func finishEditing() {
        coordinator?.cancelAll()
    }

    func globalFrame(for selectionInView: NSRect) -> NSRect {
        NSRect(x: targetScreen.frame.minX + selectionInView.minX,
               y: targetScreen.frame.maxY - selectionInView.maxY,
               width: selectionInView.width,
               height: selectionInView.height)
    }

    var backingScale: CGFloat { targetScreen.backingScaleFactor }

    func runDebugDragSequence() {
        overlayView?.debugRunDragSequence()
    }

    override var canBecomeKey: Bool { true }
}

/// 文件版诊断日志（应用容器 tmp/menushot_dumps/log.txt，外部可读）
enum DebugTrace {
    static func log(_ line: String) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("menushot_dumps", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let entry = "[\(formatter.string(from: Date()))] \(line)\n"
        let path = base.appendingPathComponent("log.txt").path
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(entry.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? entry.write(to: base.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - 命中目标与手势阶段

/// 统一命中测试结果（按优先级判定一次，事件处理只做分发）
private enum HitTarget {
    case annotationHandle(index: Int, handleIndex: Int, targetIndex: Int)
    case selectionEdge(handle: SelectionHandle)
    case annotationBody(index: Int)
    case selectionBody
    case blank
}

/// 手势阶段状态机
private enum GesturePhase {
    case idle
    case creatingSelection(start: NSPoint)
    case movingSelection(start: NSPoint, original: NSRect)
    case resizingSelection(start: NSPoint, original: NSRect, handle: SelectionHandle)
    case movingAnnotation(index: Int, start: NSPoint, original: Annotation, pushedUndo: Bool)
    case resizingAnnotation(index: Int, handleIndex: Int, targetIndex: Int,
                            original: Annotation, pushedUndo: Bool)
    case draggingToolbar(start: NSPoint, origin: NSPoint)
}

private enum SelectionHandle: CaseIterable, Equatable {
    case nw, n, ne, e, se, s, sw, w
}

// MARK: - 交互与编辑视图

final class OverlayView: NSView, EditorToolbarDelegate, NSTextFieldDelegate {

    private let snapshot: CGImage
    private let scale: CGFloat
    private weak var controller: SelectionOverlayController?

    // 选区
    private var selection: NSRect? {
        didSet {
            mosaicCache = nil
            layoutToolbar()
            needsDisplay = true
        }
    }
    private var isSelecting = false

    // 工具与样式
    private var tool: ShotTool = .none
    private var strokeColor: NSColor = .systemRed
    private var strokeWidth: CGFloat = 3

    // 标注（坐标 = 覆盖层视图坐标，左上原点；与选区同一坐标系，保存/导出时再换算为裁剪本地坐标）
    private var annotations: [Annotation] = []
    private var pending: Annotation?
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var selected: Int?

    // 手势阶段
    private var phase: GesturePhase = .idle

    // 悬停光标反馈
    private var hoverEdge: SelectionHandle? {
        didSet { if hoverEdge != oldValue { needsDisplay = true } }
    }
    private var hoverPoint: NSPoint?

    // 文本编辑
    private var activeTextField: NSTextField?
    private var textInsertPoint: NSPoint = .zero
    private var textEditIndex: Int?

    // 马赛克
    private var mosaicCache: (size: NSSize, image: CGImage?)?

    private let toolbar = EditorToolbarView(frame: .zero)
    private var styleUndoPushed = false

    private static let minSelection: CGFloat = 12
    private static let edgeHit: CGFloat = 16
    private static let cornerHit: CGFloat = 18

    init(frame: NSRect, snapshot: CGImage, scale: CGFloat, controller: SelectionOverlayController) {
        self.snapshot = snapshot
        self.scale = scale
        self.controller = controller
        super.init(frame: frame)
        wantsLayer = true
        toolbar.delegate = self
        toolbar.isHidden = true
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: - 统一命中测试

    private func hitTestTarget(at p: NSPoint) -> HitTarget {
        guard let sel = selection else { return .blank }
        let s = sel.integral
        let inside = s.contains(p)

        // 1) 已选中标注的手柄（视觉最上层）
        if let sIdx = selected, sIdx < annotations.count,
           let hi = hitAnnotationHandle(sIdx, at: p) {
            let hp = annotationHandlePoints(annotations[sIdx])[hi]
            let ti = nearestPointIndex(hp, points: annotations[sIdx].points)
            return .annotationHandle(index: sIdx, handleIndex: hi, targetIndex: ti)
        }
        // 2) 选区边框带（整边 + 四角，含外侧容差）
        if let handle = hitSelectionHandle(p, in: s) {
            return .selectionEdge(handle: handle)
        }
        // 3) 标注本体
        if inside, let index = hitAnnotation(at: p) {
            return .annotationBody(index: index)
        }
        // 4) 选区内部
        if inside { return .selectionBody }
        return .blank
    }

    // MARK: - 事件路由

    override func mouseDown(with event: NSEvent) {
        commitPendingText()
        handleMouseDown(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouseDrag(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseUp(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount)
    }

    override func mouseMoved(with event: NSEvent) {
        handleMouseMoved(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoverEdge = nil
        hoverPoint = nil
        needsDisplay = true
    }

    private func handleMouseDown(at p: NSPoint, clickCount: Int) {


        // 工具条空白区域：拖动工具条（按钮自身消费点击）
        if !toolbar.isHidden && toolbar.frame.contains(p) {
            phase = .draggingToolbar(start: p, origin: toolbar.frame.origin)
            return
        }

        let target = hitTestTarget(at: p)
        switch target {
        case .annotationHandle(let index, let handleIndex, let targetIndex):
            selected = index
            phase = .resizingAnnotation(index: index, handleIndex: handleIndex, targetIndex: targetIndex,
                                        original: annotations[index], pushedUndo: false)

        case .selectionEdge(let handle):
            selected = nil
            isSelecting = true
            phase = .resizingSelection(start: p, original: selection!, handle: handle)
            Self.cursor(for: handle)?.push()

        case .annotationBody(let index):
            selected = index
            let annotation = annotations[index]
            if clickCount == 2, annotation.kind == .text {
                beginTextEdit(existing: index)
                return
            }
            phase = .movingAnnotation(index: index, start: p, original: annotation,
                                      pushedUndo: false)

        case .selectionBody:
            selected = nil
            if tool != .none {
                beginAnnotation(at: p)
                return
            }
            if clickCount == 2 { confirmCopy(); return }
            // 选区内已有内容：不支持拖动选区（只能通过边框调整裁剪范围）
            if !annotations.isEmpty { return }
            isSelecting = true
            phase = .movingSelection(start: p, original: selection!)
            NSCursor.closedHand.push()

        case .blank:
            clearEditing()
            selection = NSRect(origin: p, size: .zero)
            phase = .creatingSelection(start: p)
            isSelecting = true
        }
    }

    private func handleMouseDrag(at p: NSPoint) {
        // 进行中的形状绘制（pending 优先）
        if var annotation = pending {
            guard let sel = selection else { return }
            let local = clampToSelection(p, in: sel)
            if annotation.kind == .pen || annotation.kind == .mosaic {
                annotation.points.append(local)
            } else {
                annotation.points[1] = local
            }
            pending = annotation
            needsDisplay = true
            return
        }

        switch phase {
        case .idle:
            break

        case .creatingSelection(let start):
            selection = normalized(rect(start, p))

        case .movingSelection(let start, let original):
            var dx = p.x - start.x, dy = p.y - start.y
            dx = max(-original.minX, min(dx, bounds.width - original.maxX))
            dy = max(-original.minY, min(dy, bounds.height - original.maxY))
            selection = NSRect(x: original.minX + dx, y: original.minY + dy,
                               width: original.width, height: original.height)
            // 标注为绝对坐标：随选区移动（内容跟随；本阶段仅在选区内无内容时才会进入）
            if dx != 0 || dy != 0 {
                for i in annotations.indices {
                    annotations[i] = annotations[i].translated(x: dx, y: dy)
                }
            }

        case .resizingSelection(let start, let original, let handle):
            hoverPoint = p
            applySelectionResize(start: start, original: original, handle: handle, at: p)

        case .movingAnnotation(let index, let start, let original, var pushedUndo):
            guard index < annotations.count, let sel = selection else { break }
            var delta = NSPoint(x: p.x - start.x, y: p.y - start.y)
            let b = original.bounds()
            let nb = b.offsetBy(dx: delta.x, dy: delta.y)
            if nb.minX < sel.minX { delta.x -= (nb.minX - sel.minX) }
            if nb.minY < sel.minY { delta.y -= (nb.minY - sel.minY) }
            if nb.maxX > sel.maxX { delta.x -= (nb.maxX - sel.maxX) }
            if nb.maxY > sel.maxY { delta.y -= (nb.maxY - sel.maxY) }
            if !pushedUndo, abs(delta.x) > 0.5 || abs(delta.y) > 0.5 {
                pushUndo()
                pushedUndo = true
            }
            annotations[index] = original.translated(x: delta.x, y: delta.y)
            phase = .movingAnnotation(index: index, start: start, original: original, pushedUndo: pushedUndo)
            needsDisplay = true

        case .resizingAnnotation(let index, let handleIndex, let targetIndex,
                                 let original, var pushedUndo):
            guard index < annotations.count, let sel = selection else { break }
            let local = clampToSelection(p, in: sel)
            var updated = original
            let ob = original.bounds()
            switch original.kind {
            case .rectangle, .ellipse:
                // 几何锚定：边中点只动对应的边（与存储顺序无关）；角手柄 = 对角固定 + 鼠标为动点
                switch handleIndex {
                case 0: // 上中
                    let topIdx = updated.points[0].y < updated.points[1].y ? 0 : 1
                    updated.points[topIdx].y = local.y
                case 1: // 下中
                    let bottomIdx = updated.points[0].y < updated.points[1].y ? 1 : 0
                    updated.points[bottomIdx].y = local.y
                case 2: // 左中
                    let leftIdx = updated.points[0].x < updated.points[1].x ? 0 : 1
                    updated.points[leftIdx].x = local.x
                case 3: // 右中
                    let rightIdx = updated.points[0].x < updated.points[1].x ? 1 : 0
                    updated.points[rightIdx].x = local.x
                case 4: // 左上 → 对角（右下）固定
                    updated.points = [NSPoint(x: ob.maxX, y: ob.maxY), local]
                case 5: // 右上 → 对角（左下）固定
                    updated.points = [NSPoint(x: ob.minX, y: ob.maxY), local]
                case 6: // 左下 → 对角（右上）固定
                    updated.points = [NSPoint(x: ob.maxX, y: ob.minY), local]
                default: // 右下 → 对角（左上）固定
                    updated.points = [NSPoint(x: ob.minX, y: ob.minY), local]
                }
            case .line, .arrow:
                guard handleIndex == 0 || handleIndex == 1 else { break }
                updated.points[handleIndex] = local
            default:
                break
            }
            if !pushedUndo {
                pushUndo()
                pushedUndo = true
            }
            annotations[index] = updated
            phase = .resizingAnnotation(index: index, handleIndex: handleIndex, targetIndex: targetIndex,
                                        original: original, pushedUndo: pushedUndo)
            needsDisplay = true

        case .draggingToolbar(let start, let toolbarOrigin):
            let size = toolbar.frame.size
            var x = toolbarOrigin.x + (p.x - start.x)
            var y = toolbarOrigin.y + (p.y - start.y)
            x = max(4, min(x, bounds.width - size.width - 4))
            y = max(4, min(y, bounds.height - size.height - 4))
            toolbar.frame.origin = NSPoint(x: x, y: y)
        }
    }

    private func handleMouseUp(at p: NSPoint, clickCount: Int) {
        NSCursor.crosshair.set()
        defer {
            phase = .idle
            isSelecting = false
            clampAnnotationsToSelection()
            layoutToolbar()
        }

        if let annotation = pending {
            pending = nil
            needsDisplay = true
            commit(annotation: annotation)
            return
        }

        switch phase {
        case .creatingSelection:
            if var sel = selection {
                sel = sel.integral
                if sel.width < Self.minSelection || sel.height < Self.minSelection {
                    selection = nil
                } else {
                    selection = sel
                    refreshHistory()
                }
            }
        default:
            break
        }
    }

    private func handleMouseMoved(at p: NSPoint) {
        guard let sel = selection, sel.width > 0 else {
            hoverEdge = nil
            hoverPoint = nil
            return
        }
        hoverEdge = hitSelectionHandle(p, in: sel.integral)
        hoverPoint = p
        if let hover = hoverEdge {
            Self.cursor(for: hover)?.set()
        } else {
            NSCursor.crosshair.set()
        }
        needsDisplay = true
    }

    // MARK: - 选区调整（翻转 + 标注等比缩放）

    private func applySelectionResize(start: NSPoint, original: NSRect, handle: SelectionHandle, at p: NSPoint) {
        let dx = p.x - start.x, dy = p.y - start.y
        var newLeft = original.minX, newRight = original.maxX
        var newTop = original.minY, newBottom = original.maxY
        switch handle {
        case .n: newTop = original.minY + dy
        case .s: newBottom = original.maxY + dy
        case .w: newLeft = original.minX + dx
        case .e: newRight = original.maxX + dx
        case .nw: newTop = original.minY + dy; newLeft = original.minX + dx
        case .ne: newTop = original.minY + dy; newRight = original.maxX + dx
        case .se: newBottom = original.maxY + dy; newRight = original.maxX + dx
        case .sw: newBottom = original.maxY + dy; newLeft = original.minX + dx
        }

        // 内容位置固定不动：边框向内调整触碰内容边界即停，向外不受限制
        if !annotations.isEmpty {
            var cb = annotations[0].bounds()
            for a in annotations.dropFirst() { cb = cb.union(a.bounds()) }
            newLeft = min(newLeft, cb.minX)      // 左边框不越过内容左缘
            newRight = max(newRight, cb.maxX)    // 右边框不越过内容右缘
            newTop = min(newTop, cb.minY)        // 顶边框不越过内容顶缘
            newBottom = max(newBottom, cb.maxY)  // 底边框不越过内容底缘
        }

        selection = normalized(NSRect(x: min(newLeft, newRight), y: min(newTop, newBottom),
                                      width: abs(newRight - newLeft),
                                      height: abs(newBottom - newTop)))
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        let cg = ctx.cgContext

        cg.interpolationQuality = .medium
        FlippedImageDrawing.draw(snapshot, in: bounds, ctx: cg)

        NSColor.black.withAlphaComponent(0.32).setFill()
        if let sel = selection {
            let s = sel.integral
            var outside: [NSRect] = []
            outside.append(NSRect(x: 0, y: 0, width: bounds.width, height: s.minY))
            outside.append(NSRect(x: 0, y: s.maxY, width: bounds.width, height: bounds.height - s.maxY))
            outside.append(NSRect(x: 0, y: s.minY, width: s.minX, height: s.height))
            outside.append(NSRect(x: s.maxX, y: s.minY, width: bounds.width - s.maxX, height: s.height))
            for r in outside where r.width > 0 && r.height > 0 { cg.fill(r) }
        } else {
            cg.fill(bounds)
        }

        guard let sel = selection, sel.width > 0, sel.height > 0 else { return }
        let s = sel.integral
        let mosaicImage = mosaicSource(for: s)

        let renderContext = RenderContext(pixelatedImage: mosaicImage, pixelatedRect: s)
        for (index, annotation) in annotations.enumerated() {
            if index == textEditIndex { continue }
            AnnotationRenderer.draw(annotation, in: ctx, context: renderContext)
        }
        if let pending = pending {
            AnnotationRenderer.draw(pending, in: ctx, context: renderContext)
        }

        // 选中态：细边框（矩形/椭圆/文本/画笔/马赛克）+ 手柄；单线类仅端点手柄
        if let selectedIndex = selected, selectedIndex < annotations.count {
            let a = annotations[selectedIndex]
            let accent = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            switch a.kind {
            case .rectangle, .ellipse, .text, .pen, .mosaic:
                cg.setStrokeColor(accent)
                cg.setLineWidth(1)
                cg.stroke(a.bounds().insetBy(dx: -4, dy: -4))
            case .line, .arrow:
                break
            }
            for h in annotationHandlePoints(a) {
                let r = NSRect(x: h.x - 4, y: h.y - 4, width: 8, height: 8)
                cg.setFillColor(NSColor.white.cgColor)
                cg.fillEllipse(in: r)
                cg.setStrokeColor(accent)
                cg.setLineWidth(1.2)
                cg.strokeEllipse(in: r)
            }
        }

        cg.setStrokeColor(NSColor.controlAccentColor.cgColor)
        cg.setLineWidth(1.6)
        cg.stroke(s.insetBy(dx: 0.8, dy: 0.8))

        for point in Self.handlePoints(of: s) {
            let r = NSRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
            cg.setFillColor(NSColor.white.cgColor)
            cg.fillEllipse(in: r)
            cg.setStrokeColor(NSColor.controlAccentColor.cgColor)
            cg.setLineWidth(1.4)
            cg.strokeEllipse(in: r)
        }

        if !isSelecting {
            let pill = sizePill(selRect: s)
            NSColor(calibratedRed: 0.15, green: 0.45, blue: 0.95, alpha: 1).setFill()
            NSBezierPath(roundedRect: pill.rect,
                         xRadius: min(14, pill.rect.height / 2),
                         yRadius: min(14, pill.rect.height / 2)).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: pill.fontSize, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let ts = (pill.text as NSString).size(withAttributes: attrs)
            (pill.text as NSString).draw(at: NSPoint(x: pill.rect.midX - ts.width / 2,
                                                     y: pill.rect.midY - ts.height / 2), withAttributes: attrs)
        }
    }

    /// 尺寸标记：自动选址（工具条在下方 → 标记在上方，反之在下方；均出屏 → 收进选区内部），
    /// 宽高随选区自适应（选区较小时缩小字号，必要时省略号）；初始框选拖动中隐藏。
    private func sizePill(selRect s: NSRect) -> (rect: NSRect, fontSize: CGFloat, text: String) {
        let gap: CGFloat = 10
        let text = "\(Int(s.width)) × \(Int(s.height))"
        let naturalW: CGFloat = 92
        let naturalH: CGFloat = 26

        // 自适应尺寸：横向/纵向不超过选区（不足时缩小并缩小字号，必要时省略号）
        var pillW = naturalW
        var pillH = naturalH
        var fontSize: CGFloat = 11
        var display = text

        let maxW = max(28, s.width - gap * 2)
        let maxH = max(14, min(naturalH, s.height - gap * 2))
        pillW = min(naturalW, maxW)
        pillH = min(naturalH, maxH)
        fontSize = max(8, min(11, pillH - 8))
        var attrs = [NSAttributedString.Key.font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)]
        var ts = (text as NSString).size(withAttributes: attrs)
        var t = text
        while ts.width > pillW - 10 && fontSize > 8 {
            fontSize -= 1
            attrs[.font] = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
            ts = (t as NSString).size(withAttributes: attrs)
        }
        if ts.width > pillW - 10 {
            while t.count > 1 && ((t + "…") as NSString).size(withAttributes: attrs).width > pillW - 10 {
                t.removeLast()
            }
            t += "…"
            ts = (t as NSString).size(withAttributes: attrs)
        }
        display = t
        pillW = min(pillW, max(24, ts.width + 10))

        // 自动选址：工具条在下方 → 标记在上方；工具条在上方 → 标记在下方；
        // 上方会覆盖菜单栏区域时 → 改下方；两侧都放不下 → 选区内居中
        let toolbarAbove = !toolbar.isHidden && toolbar.frame.maxY <= s.minY + 2
        let toolbarBelow = !toolbar.isHidden && toolbar.frame.minY >= s.maxY - 2
        let aboveY = s.minY - pillH - gap
        let belowY = s.maxY + gap
        let aboveOK = aboveY >= 26 && !toolbarAbove
        let belowOK = belowY + pillH <= bounds.height - 4 && !toolbarBelow
        var origin: NSPoint
        if aboveOK {
            origin = NSPoint(x: s.midX - pillW / 2, y: aboveY)
        } else if belowY + pillH <= bounds.height - 4 && !toolbarBelow {
            origin = NSPoint(x: s.midX - pillW / 2, y: belowY)
        } else {
            origin = NSPoint(x: s.midX - pillW / 2, y: s.midY - pillH / 2)
        }
        // 屏幕边界收拢：首选侧出屏 → 换另一侧
        if origin.y < 4 { origin = NSPoint(x: s.midX - pillW / 2, y: s.maxY + gap) }
        if origin.y + pillH > bounds.height - 4 { origin = NSPoint(x: s.midX - pillW / 2, y: s.minY - pillH - gap) }
        origin.x = max(4, min(origin.x, bounds.width - pillW - 4))
        origin.y = max(4, min(origin.y, bounds.height - pillH - 4))
        return (NSRect(origin: origin, size: NSSize(width: pillW, height: pillH)), fontSize, display)
    }

    private func mosaicSource(for sel: NSRect) -> CGImage? {
        if let cached = mosaicCache, abs(cached.size.width - sel.width) < 0.5,
           abs(cached.size.height - sel.height) < 0.5 {
            return cached.image
        }
        let pxRect = NSRect(x: floor(sel.minX * scale), y: floor(sel.minY * scale),
                            width: ceil(sel.width * scale), height: ceil(sel.height * scale)).integral
        let cropped = snapshot.cropping(to: pxRect)
        let image = cropped.flatMap { MosaicEngine.pixelate($0) }
        mosaicCache = (NSSize(width: sel.width, height: sel.height), image)
        return image
    }

    private static func handlePoints(of rect: NSRect) -> [NSPoint] {
        let midX = rect.midX, midY = rect.midY
        return [
            NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: midX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.maxX, y: midY),
            NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: midX, y: rect.maxY), NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.minX, y: midY),
        ]
    }

    private static func cursor(for handle: SelectionHandle) -> NSCursor? {
        switch handle {
        case .n, .s: return .resizeUpDown
        case .e, .w: return .resizeLeftRight
        case .nw, .se, .ne, .sw: return .crosshair
        }
    }

    // MARK: - 命中测试

    private func hitSelectionHandle(_ p: NSPoint, in sel: NSRect) -> SelectionHandle? {
        let corner = Self.cornerHit
        let edge = Self.edgeHit
        if abs(p.x - sel.minX) <= corner && abs(p.y - sel.minY) <= corner { return .nw }
        if abs(p.x - sel.maxX) <= corner && abs(p.y - sel.minY) <= corner { return .ne }
        if abs(p.x - sel.maxX) <= corner && abs(p.y - sel.maxY) <= corner { return .se }
        if abs(p.x - sel.minX) <= corner && abs(p.y - sel.maxY) <= corner { return .sw }
        let withinWidth = p.x >= sel.minX + corner && p.x <= sel.maxX - corner
        let withinHeight = p.y >= sel.minY + corner && p.y <= sel.maxY - corner
        if abs(p.y - sel.minY) <= edge && withinWidth { return .n }
        if abs(p.y - sel.maxY) <= edge && withinWidth { return .s }
        if abs(p.x - sel.minX) <= edge && withinHeight { return .w }
        if abs(p.x - sel.maxX) <= edge && withinHeight { return .e }
        return nil
    }

    private func hitAnnotation(at local: NSPoint) -> Int? {
        if let s = selected, s < annotations.count, annotationHit(annotations[s], at: local) {
            return s
        }
        for i in annotations.indices.reversed() where i != selected {
            if annotationHit(annotations[i], at: local) { return i }
        }
        return nil
    }

    /// 命中判定：只能选中图形的实际内容（Excalidraw 式）
    private func annotationHit(_ a: Annotation, at p: NSPoint) -> Bool {
        let effWidth = a.kind == .mosaic ? max(a.lineWidth, 14) : a.lineWidth
        let tolerance = max(7, effWidth + 4)
        switch a.kind {
        case .rectangle:
            let b = a.bounds()
            let outer = b.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = b.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(p) && !inner.contains(p)
        case .ellipse:
            let b = a.bounds()
            guard b.width > 1, b.height > 1 else { return false }
            let rx = b.width / 2, ry = b.height / 2
            let dx = (p.x - b.midX) / rx, dy = (p.y - b.midY) / ry
            let offset = abs(sqrt(dx * dx + dy * dy) - 1) * min(rx, ry)
            return offset <= tolerance
        case .text:
            return a.bounds().insetBy(dx: -4, dy: -4).contains(p)
        case .line, .arrow, .pen, .mosaic:
            guard a.points.count > 1 else {
                guard let first = a.points.first else { return false }
                return hypot(p.x - first.x, p.y - first.y) <= tolerance
            }
            for i in 0..<(a.points.count - 1) {
                if Self.distance(p, a.points[i], a.points[i + 1]) <= tolerance { return true }
            }
            return false
        }
    }

    private func annotationHandlePoints(_ a: Annotation) -> [NSPoint] {
        let b = a.bounds()
        switch a.kind {
        case .rectangle, .ellipse:
            return [NSPoint(x: b.midX, y: b.minY), NSPoint(x: b.midX, y: b.maxY),
                    NSPoint(x: b.minX, y: b.midY), NSPoint(x: b.maxX, y: b.midY),
                    NSPoint(x: b.minX, y: b.minY), NSPoint(x: b.maxX, y: b.minY),
                    NSPoint(x: b.minX, y: b.maxY), NSPoint(x: b.maxX, y: b.maxY)]
        case .line, .arrow:
            guard a.points.count > 1 else { return [] }
            return [a.points[0], a.points[1]]
        default:
            return []
        }
    }

    private func hitAnnotationHandle(_ index: Int, at local: NSPoint) -> Int? {
        guard index < annotations.count else { return nil }
        for (i, h) in annotationHandlePoints(annotations[index]).enumerated() {
            if hypot(local.x - h.x, local.y - h.y) <= 9 { return i }
        }
        return nil
    }

    private func nearestPointIndex(_ h: NSPoint, points: [NSPoint]) -> Int {
        var best = 0
        var bestD = CGFloat.greatestFiniteMagnitude
        for (i, pt) in points.enumerated() {
            let d = hypot(h.x - pt.x, h.y - pt.y)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    private static func distance(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSquared
        t = max(0, min(1, t))
        let proj = NSPoint(x: a.x + abx * t, y: a.y + aby * t)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    private func normalized(_ rect: NSRect) -> NSRect {
        NSRect(x: min(rect.minX, rect.maxX), y: min(rect.minY, rect.maxY),
               width: abs(rect.width), height: abs(rect.height))
    }

    private func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func clampToSelection(_ p: NSPoint, in sel: NSRect) -> NSPoint {
        NSPoint(x: min(max(p.x, sel.minX), sel.maxX),
                y: min(max(p.y, sel.minY), sel.maxY))
    }

    private func clearEditing() {
        commitPendingText()
        pending = nil
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        selected = nil
        setToolInternal(.none)
        refreshHistory()
    }

    // MARK: - 标注绘制

    private func beginAnnotation(at local: NSPoint) {
        let kind: Annotation.Kind
        switch tool {
        case .rectangle: kind = .rectangle
        case .ellipse: kind = .ellipse
        case .arrow: kind = .arrow
        case .line: kind = .line
        case .pen: kind = .pen
        case .mosaic: kind = .mosaic
        case .text:
            beginText(at: local)
            return
        case .none: return
        }
        if kind == .pen || kind == .mosaic {
            pending = Annotation(kind: kind, color: strokeColor, lineWidth: strokeWidth, points: [local])
        } else {
            pending = Annotation(kind: kind, color: strokeColor, lineWidth: strokeWidth, points: [local, local])
        }
    }

    private func commit(annotation: Annotation) {
        let valid: Bool
        if annotation.kind == .pen || annotation.kind == .mosaic {
            valid = annotation.points.count > 2
        } else if annotation.kind == .text {
            valid = !annotation.text.isEmpty
        } else {
            let drag = abs(annotation.points[1].x - annotation.points[0].x) +
                       abs(annotation.points[1].y - annotation.points[0].y)
            valid = drag > 2
        }
        guard valid else { return }
        pushUndo()
        annotations.append(annotation)
        selected = annotations.count - 1
        refreshHistory()
        needsDisplay = true
    }

    // MARK: - 文本标注

    private func beginText(at local: NSPoint) {
        beginTextEdit(existing: nil, insertAt: local)
    }

    private func beginTextEdit(existing: Int?, insertAt local: NSPoint = .zero) {
        guard activeTextField == nil, let sel = selection else { return }
        let annotation = existing.flatMap { $0 < annotations.count ? annotations[$0] : nil }
        textEditIndex = existing
        textInsertPoint = annotation?.points.first ?? local

        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AnnotationRenderer.handFont(size: annotation?.fontSize ?? 18)
        field.textColor = annotation?.color ?? strokeColor
        field.stringValue = annotation?.text ?? ""
        field.placeholderString = "输入文字，回车确认"
        field.delegate = self
        field.frame = NSRect(x: textInsertPoint.x, y: textInsertPoint.y,
                             width: 260, height: 28)
        addSubview(field)
        activeTextField = field
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func commitPendingText() {
        guard let field = activeTextField else { return }
        window?.makeFirstResponder(self)
        fieldTextDidEnd(field)
    }

    fileprivate func fieldTextDidEnd(_ field: NSTextField) {
        activeTextField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let editingExisting = textEditIndex
        field.removeFromSuperview()

        defer {
            textEditIndex = nil
            needsDisplay = true
        }
        guard !text.isEmpty else { return }

        pushUndo()
        if let index = editingExisting, index < annotations.count {
            var updated = annotations[index]
            updated.text = text
            annotations[index] = updated
        } else {
            annotations.append(Annotation(kind: .text, color: strokeColor, lineWidth: strokeWidth,
                                          points: [textInsertPoint], text: text))
        }
        refreshHistory()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        fieldTextDidEnd(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(self)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if let field = activeTextField {
                window?.makeFirstResponder(self)
                if textEditIndex == nil { field.stringValue = "" }
                fieldTextDidEnd(field)
            }
            return true
        }
        return false
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)

        if cmd && chars == "z" && !shift { undoAction(); return }
        if cmd && chars == "z" && shift { redoAction(); return }
        if cmd && chars == "s" && shift { saveAsAction(); return }
        if cmd && chars == "s" { saveAction(); return }
        if chars == "\u{7F}" || chars == "\u{F728}" {
            deleteSelected()
            return
        }
        if chars == "\u{1B}" {
            if selected != nil {
                selected = nil
                needsDisplay = true
            } else if tool != .none {
                setToolInternal(.none)
            } else if activeTextField != nil {
                commitPendingText()
            } else {
                controller?.cancelAll()
            }
            return
        }
        if chars == "\r" || chars == "\u{3}" { confirmCopy(); return }
        super.keyDown(with: event)
    }

    private func deleteSelected() {
        guard let index = selected, index < annotations.count else { return }
        commitPendingText()
        pushUndo()
        annotations.remove(at: index)
        selected = nil
        refreshHistory()
        needsDisplay = true
    }

    // MARK: - 工具条布局

    private func layoutToolbar() {
        guard let sel = selection, sel.width > 0, !isSelecting else {
            toolbar.isHidden = true
            return
        }
        toolbar.isHidden = false
        let gap: CGFloat = 10
        let s = sel.integral
        let size = toolbar.idealSize

        let belowY = s.maxY + gap
        let aboveY = s.minY - gap - size.height
        var origin: NSPoint
        if belowY + size.height <= bounds.height - 4 {
            origin = NSPoint(x: s.maxX - size.width, y: belowY)
        } else if aboveY >= 4 {
            origin = NSPoint(x: s.maxX - size.width, y: aboveY)
        } else {
            origin = NSPoint(x: s.maxX - size.width, y: bounds.height - size.height - 4)
        }

        origin.x = max(4, min(origin.x, bounds.width - size.width - 4))
        origin.y = max(4, min(origin.y, bounds.height - size.height - 4))
        toolbar.frame = NSRect(origin: origin, size: size)
    }

    // MARK: - EditorToolbarDelegate

    func toolbarDidChangeTool(_ newTool: ShotTool) {
        commitPendingText()
        selected = nil
        setToolInternal(newTool == tool ? .none : newTool)
    }

    private func setToolInternal(_ newTool: ShotTool) {
        tool = newTool
        toolbar.setTool(newTool)
    }

    func toolbarDidRequestStyle(_ sender: NSButton) {
        styleUndoPushed = false
        let popover = NSPopover()
        popover.behavior = .transient
        let vc = NSViewController()
        vc.view = StylePickerView(color: strokeColor, width: strokeWidth) { [weak self] color, width in
            guard let self = self else { return }
            self.strokeColor = color
            self.strokeWidth = width
            self.toolbar.setColor(color)
            if let index = self.selected, index < self.annotations.count {
                if !self.styleUndoPushed {
                    self.pushUndo()
                    self.styleUndoPushed = true
                }
                self.annotations[index].color = color
                self.annotations[index].lineWidth = width
            }
            self.needsDisplay = true
        }
        popover.contentViewController = vc
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    func toolbarDidRequestOCR() {
        commitPendingText()
        guard let sel = selection else { return }
        let pxRect = NSRect(x: floor(sel.minX * scale), y: floor(sel.minY * scale),
                            width: ceil(sel.width * scale), height: ceil(sel.height * scale)).integral
        guard let cropped = snapshot.cropping(to: pxRect) else { return }
        let global = controller?.globalFrame(for: sel)
        // 产出类操作：点击后即退出截图模式，识别完成后独立弹出结果窗
        controller?.finishEditing()
        Toast.shared.show("正在识别文字…", duration: 1.2)
        OCRService.recognize(in: cropped) { result in
            let text: String
            switch result {
            case .success(let value): text = value.isEmpty ? "未识别到文字" : value
            case .failure(let error): text = "识别失败：\(error.localizedDescription)"
            }
            let window = OCRResultWindow(text: text)
            if let global { window.center(in: global) }
            window.orderFrontRegardless()
        }
    }

    func toolbarDidRequestPin() {
        commitPendingText()
        guard let sel = selection, let controller = controller else { return }
        let rep = ScreenshotCompositor.compositedRep(snapshot: snapshot, scale: scale,
                                                     selection: sel, annotations: annotations)
        guard let cg = rep.cgImage else { return }
        PinWindowController.pin(image: cg, scale: scale, near: controller.globalFrame(for: sel))
        Toast.shared.show("已钉在桌面")
        controller.finishEditing()
    }

    func toolbarDidRequestUndo() { undoAction() }
    func toolbarDidRequestRedo() { redoAction() }
    func toolbarDidRequestSave() { saveAction() }
    func toolbarDidRequestSaveAs() { saveAsAction() }
    func toolbarDidRequestCancel() { controller?.cancelAll() }
    func toolbarDidRequestConfirm() { confirmCopy() }

    // MARK: - 撤销 / 重做

    private func undoAction() {
        guard let previous = undoStack.popLast() else { return }
        commitPendingText()
        redoStack.append(annotations)
        annotations = previous
        selected = nil
        refreshHistory()
        needsDisplay = true
    }

    private func redoAction() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        selected = nil
        refreshHistory()
        needsDisplay = true
    }

    private func pushUndo() {
        undoStack.append(annotations)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func refreshHistory() {
        toolbar.refreshHistory(canUndo: !undoStack.isEmpty, canRedo: !redoStack.isEmpty)
    }

    // MARK: - 保存 / 复制

    private func saveAction() {
        guard let sel = selection else { return }
        let rep = ScreenshotCompositor.compositedRep(snapshot: snapshot, scale: scale,
                                                     selection: sel, annotations: annotations)
        switch SaveService.saveToDefaultDirectory(rep: rep, jpeg: AppSettings.shared.saveAsJPEG) {
        case .success(let url):
            Toast.shared.show("已保存：\(url.lastPathComponent)")
            controller?.finishEditing()
        case .failure(let error):
            NSAlert(error: error).runModal()
        }
    }

    private func saveAsAction() {
        guard let sel = selection else { return }
        let rep = ScreenshotCompositor.compositedRep(snapshot: snapshot, scale: scale,
                                                     selection: sel, annotations: annotations)
        if SaveService.saveAs(rep: rep) {
            controller?.finishEditing()
        }
    }

    private func confirmCopy() {
        guard let sel = selection else { return }
        commitPendingText()
        let rep = ScreenshotCompositor.compositedRep(snapshot: snapshot, scale: scale,
                                                     selection: sel, annotations: annotations)
        if let data = rep.representation(using: .png, properties: [:]) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(data, forType: .png)
        }
        var message = "已复制到剪贴板"
        if AppSettings.shared.autoSaveOnConfirm {
            if case .success(let url) = SaveService.saveToDefaultDirectory(rep: rep, jpeg: AppSettings.shared.saveAsJPEG) {
                message = "已复制到剪贴板，并保存 \(url.lastPathComponent)"
            }
        }
        controller?.finishEditing()
        Toast.shared.show(message)
    }

    private func clampAnnotationsToSelection() {
        guard let sel = selection else { return }
        let s = sel.integral
        for i in annotations.indices {
            var a = annotations[i]
            let b0 = a.bounds()
            // 最小位移平移（绝对坐标语义：与选区的绝对边界比较）
            var dx: CGFloat = 0
            var dy: CGFloat = 0
            if b0.maxX > s.maxX { dx = s.maxX - b0.maxX }
            else if b0.minX < s.minX { dx = s.minX - b0.minX }
            if b0.maxY > s.maxY { dy = s.maxY - b0.maxY }
            else if b0.minY < s.minY { dy = s.minY - b0.minY }
            // 只做最小位移兜底（手绘笔迹越界 ≤ 半线宽）：不缩放、不重定位——
            // 提交后的内容必须与拖动中看到的位置逐点一致，任何缩放/居中都会被感知为跳动
            if dx != 0 || dy != 0 {
                a = a.translated(x: dx, y: dy)
            }
            annotations[i] = a
        }
    }

    // MARK: - 调试回放（真实处理链路 + 渲染帧导出）

    func debugRunDragSequence() {
        DebugTrace.log("回放开始")
        dump("0_initial")
        handleMouseDown(at: NSPoint(x: 400, y: 300), clickCount: 1)
        dump("1_select_down")
        let selectTicks = [NSPoint(x: 500, y: 350), NSPoint(x: 700, y: 450), NSPoint(x: 900, y: 550)]
        for (i, pt) in selectTicks.enumerated() {
            handleMouseDrag(at: pt)
            if i == selectTicks.count - 1 { dump("2_select_drag") }
        }
        handleMouseUp(at: NSPoint(x: 900, y: 550), clickCount: 1)
        dump("3_select_up")
        handleMouseMoved(at: NSPoint(x: 650, y: 300))
        dump("3b_hover_top")
        // 先画一个椭圆（验证调整选区时内容固定不动）
        setToolInternal(.ellipse)
        handleMouseDown(at: NSPoint(x: 500, y: 400), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 800, y: 500))
        handleMouseUp(at: NSPoint(x: 800, y: 500), clickCount: 1)
        dump("3c_ellipse_drawn")
        handleMouseMoved(at: NSPoint(x: 650, y: 300))
        handleMouseDown(at: NSPoint(x: 650, y: 300), clickCount: 1)
        dump("4_edgeA_down")
        let edgeTicks = [NSPoint(x: 650, y: 380), NSPoint(x: 650, y: 480), NSPoint(x: 650, y: 560),
                         NSPoint(x: 650, y: 700), NSPoint(x: 650, y: 800)]
        for (i, pt) in edgeTicks.enumerated() {
            handleMouseDrag(at: pt)
            dump("5_edge_drag_\(i)_y\(Int(pt.y))")
        }
        handleMouseUp(at: NSPoint(x: 650, y: 800), clickCount: 1)
        dump("6_edge_up")
        handleMouseDown(at: NSPoint(x: 300, y: 900), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 693, y: 923))
        handleMouseUp(at: NSPoint(x: 693, y: 923), clickCount: 1)
        dump("7_thin_up")
        handleMouseDown(at: NSPoint(x: 496, y: 900), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 496, y: 960))
        dump("8_thin_flip")
        handleMouseUp(at: NSPoint(x: 496, y: 960), clickCount: 1)
        dump("9_thin_flip_up")
        handleMouseDown(at: NSPoint(x: 693, y: 923), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 760, y: 980))
        dump("10_corner_drag")
        handleMouseUp(at: NSPoint(x: 760, y: 980), clickCount: 1)
        dump("11_corner_up")
        handleMouseDown(at: NSPoint(x: 500, y: 970), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 500, y: 1090))
        handleMouseUp(at: NSPoint(x: 500, y: 1090), clickCount: 1)
        dump("12_move_bottom_edge")
        handleMouseDown(at: NSPoint(x: 500, y: 1085), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 500, y: 1160))
        handleMouseUp(at: NSPoint(x: 500, y: 1160), clickCount: 1)
        dump("13_move_beyond_bottom")
        handleMouseDown(at: NSPoint(x: 1100, y: 900), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 1710, y: 1110))
        handleMouseUp(at: NSPoint(x: 1710, y: 1110), clickCount: 1)
        dump("14_corner_bottom_right")
        handleMouseDown(at: NSPoint(x: 20, y: 900), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 400, y: 1110))
        handleMouseUp(at: NSPoint(x: 400, y: 1110), clickCount: 1)
        dump("15_corner_bottom_left")
        handleMouseDown(at: NSPoint(x: 1100, y: 40), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 1710, y: 200))
        handleMouseUp(at: NSPoint(x: 1710, y: 200), clickCount: 1)
        dump("16_corner_top_right")
        handleMouseDown(at: NSPoint(x: 20, y: 40), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 400, y: 200))
        handleMouseUp(at: NSPoint(x: 400, y: 200), clickCount: 1)
        dump("17_corner_top_left")
        // —— 场景：右侧选区 + 画图形 + 左移选区（内容应跟随）——
        handleMouseDown(at: NSPoint(x: 1000, y: 300), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 1600, y: 700))
        handleMouseUp(at: NSPoint(x: 1600, y: 700), clickCount: 1)
        dump("30_right_selection")
        setToolInternal(.rectangle)
        handleMouseDown(at: NSPoint(x: 1200, y: 400), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 1500, y: 600))
        handleMouseUp(at: NSPoint(x: 1500, y: 600), clickCount: 1)
        dump("31_shape_drawn")
        setToolInternal(.none)
        handleMouseDown(at: NSPoint(x: 1100, y: 500), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 600, y: 500))
        handleMouseUp(at: NSPoint(x: 600, y: 500), clickCount: 1)
        dump("32_selection_moved_left")
        // —— 贴边绘制跳变复现：起点贴近选区右缘 (1450,480)，拖出右缘（被钳制到 x=1600）再拖回，
        //    mouseUp 前后两帧（22c vs 22d）中矩形位置必须完全一致，不得跳动 ——
        setToolInternal(.rectangle)
        handleMouseDown(at: NSPoint(x: 1450, y: 480), clickCount: 1)
        dump("22a_draw_down")
        handleMouseDrag(at: NSPoint(x: 1700, y: 560))
        dump("22b_draw_out")
        handleMouseDrag(at: NSPoint(x: 1500, y: 520))
        dump("22c_draw_in")
        handleMouseUp(at: NSPoint(x: 1500, y: 520), clickCount: 1)
        dump("22d_draw_up")
        dumpComposite("22e_composited")
        setToolInternal(.none)
        // —— 标注管线验证 ——
        setToolInternal(.rectangle)
        handleMouseDown(at: NSPoint(x: 80, y: 90), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 260, y: 150))
        handleMouseUp(at: NSPoint(x: 260, y: 150), clickCount: 1)
        dump("20_rect_drawn")
        setToolInternal(.none)
        handleMouseDown(at: NSPoint(x: 170, y: 120), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 140, y: 100))
        handleMouseUp(at: NSPoint(x: 140, y: 100), clickCount: 1)
        dump("21_rect_moved")
        if selected != nil {
            let hp = annotationHandlePoints(annotations[selected!])[3]  // 右中
            handleMouseDown(at: hp, clickCount: 1)
            handleMouseDrag(at: NSPoint(x: hp.x + 50, y: hp.y))
            handleMouseUp(at: NSPoint(x: hp.x + 50, y: hp.y), clickCount: 1)
            dump("22_rect_resized")
        }
        undoAction()
        dump("23_undo")
        setToolInternal(.arrow)
        handleMouseDown(at: NSPoint(x: 60, y: 130), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 200, y: 60))
        handleMouseUp(at: NSPoint(x: 200, y: 60), clickCount: 1)
        dump("24_arrow_drawn")
        setToolInternal(.text)
        handleMouseDown(at: NSPoint(x: 100, y: 100), clickCount: 1)
        if let f = activeTextField { f.stringValue = "验证文本" }
        commitPendingText()
        dump("25_text_placed")
        deleteSelected()
        dump("26_deleted")
        undoAction()
        dump("27_undone")
        setToolInternal(.none)
        // —— 马赛克贴笔迹验证：V 形笔迹围出开放区域，只有笔迹本身应被马赛克覆盖 ——
        handleMouseDown(at: NSPoint(x: 100, y: 200), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 600, y: 400))
        handleMouseUp(at: NSPoint(x: 600, y: 400), clickCount: 1)
        setToolInternal(.mosaic)
        handleMouseDown(at: NSPoint(x: 180, y: 260), clickCount: 1)
        handleMouseDrag(at: NSPoint(x: 350, y: 370))
        handleMouseDrag(at: NSPoint(x: 520, y: 260))
        handleMouseUp(at: NSPoint(x: 520, y: 260), clickCount: 1)
        dump("40_mosaic_stroke")
        dumpComposite("41_mosaic_composited")
        setToolInternal(.none)
        // —— 图钉链路验证：合成 → 钉图 → 按真实绘制路径导出钉图视图 → 收起覆盖层 ——
        if let sel = selection, let controller = controller {
            let rep = ScreenshotCompositor.compositedRep(snapshot: snapshot, scale: scale,
                                                         selection: sel, annotations: annotations)
            if let cg = rep.cgImage {
                PinWindowController.pin(image: cg, scale: scale, near: controller.globalFrame(for: sel))
            }
            PinManager.shared.debugDumpLastView("42_pin_view")
            controller.cancelAll()
        }
        DebugTrace.log("回放结束")
    }

    private func dump(_ name: String) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width),
                                   pixelsHigh: Int(bounds.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = bounds.size
        cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("menushot_dumps", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? png.write(to: base.appendingPathComponent("\(name).png"))
        DebugTrace.log("dump[\(name)] sel=\(selectionText()) toolbar=\(toolbarStateText())")
    }

    /// 导出管线验证：按正式合成管线（裁剪 + 坐标换算 + 标注渲染）输出当前选区为 PNG
    private func dumpComposite(_ name: String) {
        guard let sel = selection else { return }
        let rep = ScreenshotCompositor.compositedRep(snapshot: snapshot, scale: scale,
                                                     selection: sel, annotations: annotations)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("menushot_dumps", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? png.write(to: base.appendingPathComponent("\(name).png"))
        DebugTrace.log("dump[\(name)] composite=\(Int(sel.width))x\(Int(sel.height)) annotations=\(annotations.count)")
    }

    private func selectionText() -> String {
        selection.map { "(\(Int($0.minX)),\(Int($0.minY))) \(Int($0.width))x\(Int($0.height))" } ?? "nil"
    }

    private func toolbarStateText() -> String {
        toolbar.isHidden ? "hidden" : "x\(Int(toolbar.frame.minX)) y\(Int(toolbar.frame.minY))"
    }
}
