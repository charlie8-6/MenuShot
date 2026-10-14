import AppKit

/// 标注元素：坐标为「图片点坐标」（左上原点，y 向下），与屏幕显示一致。
/// 图形采用 Excalidraw 式手绘风：以 seed 驱动的确定性抖动，保证每次重绘形状稳定。
struct Annotation {
    enum Kind {
        case rectangle, ellipse, arrow, line, pen, text, mosaic
    }

    var kind: Kind
    var color: NSColor
    var lineWidth: CGFloat
    var points: [NSPoint]
    var text: String = ""
    var fontSize: CGFloat = 18
    var seed: Int = Int.random(in: 1...Int.max)

    func bounds() -> NSRect {
        switch kind {
        case .rectangle, .ellipse:
            guard points.count > 1 else { return .zero }
            return Annotation.rect(min: points[0], max: points[1])
        case .line, .arrow, .pen, .mosaic:
            guard let first = points.first else { return .zero }
            // 马赛克实际描边宽度有下限 14，命中/边界需与渲染一致
            let w = kind == .mosaic ? max(lineWidth, 14) : lineWidth
            var r = CGRect(x: first.x, y: first.y, width: 0, height: 0)
            for p in points { r = r.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
            return r.insetBy(dx: -w / 2 - 2, dy: -w / 2 - 2)
        case .text:
            let size = AnnotationRenderer.textBoundingSize(self)
            return NSRect(origin: points.first ?? .zero, size: size)
        }
    }

    func translated(x dx: CGFloat, y dy: CGFloat) -> Annotation {
        var copy = self
        copy.points = points.map { NSPoint(x: $0.x + dx, y: $0.y + dy) }
        return copy
    }

    static func rect(min a: NSPoint, max b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

/// 确定性伪随机（SplitMix64）：同一 seed 每次渲染出相同手绘形状
struct SeededRandom {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(truncatingIfNeeded: seed) &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 11) & 0xFF_FFFF) / Double(0xFF_FFFF)
    }

    /// ±magnitude 的抖动
    mutating func jitter(_ magnitude: Double) -> Double {
        (next() - 0.5) * 2 * magnitude
    }
}

/// 马赛克引擎：把图片降采样再放大，得到色块
enum MosaicEngine {
    static func pixelate(_ image: CGImage, block: CGFloat = 14) -> CGImage? {
        let w = image.width, h = image.height
        let sw = max(1, Int((CGFloat(w) / block).rounded()))
        let sh = max(1, Int((CGFloat(h) / block).rounded()))
        guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        small.interpolationQuality = .low
        small.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let smallImage = small.makeImage() else { return nil }

        guard let big = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        big.interpolationQuality = .none
        big.draw(smallImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return big.makeImage()
    }
}

/// 马赛克渲染所需的图像上下文
struct RenderContext {
    var pixelatedImage: CGImage?
    /// 马赛克图像的目标区域（当前坐标系）
    var pixelatedRect: NSRect = .zero
}

/// 统一的标注绘制：在**已翻转（y 向下）的坐标系**中调用，手绘风格。
enum AnnotationRenderer {

    static func handFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        if let rounded = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: rounded, size: size) ?? base
        }
        return base
    }

    static func textAttributes(for a: Annotation) -> [NSAttributedString.Key: Any] {
        [.font: handFont(size: a.fontSize),
         .foregroundColor: a.color]
    }

    static func textBoundingSize(_ a: Annotation) -> NSSize {
        (a.text as NSString).size(withAttributes: textAttributes(for: a))
    }

    static func draw(_ a: Annotation, in ctx: NSGraphicsContext, context: RenderContext? = nil) {
        let cg = ctx.cgContext
        let pts = a.points
        guard !pts.isEmpty else { return }
        var rng = SeededRandom(seed: a.seed)

        switch a.kind {
        case .rectangle:
            guard pts.count > 1 else { return }
            roughRect(cg, Annotation.rect(min: pts[0], max: pts[1]), a: a, rng: &rng)
        case .ellipse:
            guard pts.count > 1 else { return }
            roughEllipse(cg, Annotation.rect(min: pts[0], max: pts[1]), a: a, rng: &rng)
        case .line:
            guard pts.count > 1 else { return }
            roughSegment(cg, from: pts[0], to: pts[1], a: a, rng: &rng)
        case .arrow:
            guard pts.count > 1 else { return }
            roughArrow(cg, from: pts[0], to: pts[1], a: a, rng: &rng)
        case .pen:
            guard pts.count > 1 else { return }
            let path = CGMutablePath()
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.addLine(to: p) }
            cg.setStrokeColor(a.color.cgColor)
            cg.setLineWidth(a.lineWidth)
            cg.addPath(path)
            cg.strokePath()
        case .text:
            (a.text as NSString).draw(at: pts[0], withAttributes: textAttributes(for: a))
        case .mosaic:
            drawMosaic(a, in: cg, context: context)
        }
    }

    // MARK: - 马赛克

    private static func drawMosaic(_ a: Annotation, in cg: CGContext, context: RenderContext?) {
        guard let ctx = context, let image = ctx.pixelatedImage else { return }
        let stroke = CGMutablePath()
        stroke.move(to: a.points[0])
        for p in a.points.dropFirst() { stroke.addLine(to: p) }

        cg.saveGState()
        let strokeWidth = max(a.lineWidth, 14)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        // 裁剪到「描边轮廓」而非路径填充：直接 clip() 裁到的是折线首尾相接闭合出的多边形，
        // 表现为整块矩形被马赛克覆盖；copy(strokingWithWidth:) 才是涂到哪盖到哪
        let outline = stroke.copy(strokingWithWidth: strokeWidth, lineCap: .round, lineJoin: .round, miterLimit: 2)
        cg.addPath(outline)
        cg.clip()
        // flipped 坐标系内按原始方向绘制像素图
        let r = ctx.pixelatedRect
        cg.translateBy(x: r.minX, y: r.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        cg.restoreGState()
    }

    // MARK: - Excalidraw 式手绘（平滑低频摆动，非逐点抖动）

    /// 相邻中点二次贝塞尔：把折线变成平滑曲线
    private static func smoothPath(_ points: [NSPoint], closed: Bool = false) -> CGPath {
        let path = CGMutablePath()
        guard !points.isEmpty else { return path }
        if points.count < 3 {
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
            if closed { path.closeSubpath() }
            return path
        }
        path.move(to: points[0])
        if closed {
            for i in 0..<points.count {
                let cur = points[i]
                let next = points[(i + 1) % points.count]
                let mid = NSPoint(x: (cur.x + next.x) / 2, y: (cur.y + next.y) / 2)
                path.addQuadCurve(to: mid, control: cur)
            }
            path.closeSubpath()
        } else {
            for i in 1..<points.count {
                let cur = points[i]
                let next = i + 1 < points.count ? points[i + 1] : points[i]
                let mid = NSPoint(x: (cur.x + next.x) / 2, y: (cur.y + next.y) / 2)
                path.addQuadCurve(to: mid, control: cur)
            }
        }
        return path
    }

    /// 手绘线段：低频正弦摆动（端点归零）+ 第二遍更浅、略短的偏移描边
    private static func roughSegment(_ cg: CGContext, from: NSPoint, to: NSPoint,
                                     a: Annotation, rng: inout SeededRandom,
                                     alpha: CGFloat = 1) {
        let dx = to.x - from.x, dy = to.y - from.y
        let dist = hypot(dx, dy)
        guard dist > 0.5 else { return }
        let nx = -dy / dist, ny = dx / dist
        // 低频摆动系数：主波 + 次波，起止为零
        let c1 = rng.jitter(1.5), c2 = rng.jitter(1.1)
        let steps = max(4, Int(dist / 9))

        for pass in 0..<2 {
            let tStart = pass == 0 ? 0.0 : 0.06
            let tEnd = pass == 0 ? 1.0 : 0.94
            let scale = pass == 0 ? 1.0 : 1.65
            let count = pass == 0 ? steps : max(3, steps * 2 / 3)
            var pts: [NSPoint] = []
            for i in 0...count {
                let t = tStart + (tEnd - tStart) * Double(i) / Double(count)
                let wobble = (c1 * sin(.pi * t) + 0.6 * c2 * sin(2 * .pi * t)) * scale + rng.jitter(0.3)
                pts.append(NSPoint(x: from.x + dx * t + nx * wobble,
                                   y: from.y + dy * t + ny * wobble))
            }
            cg.setStrokeColor(a.color.withAlphaComponent(pass == 0 ? alpha : alpha * 0.38).cgColor)
            cg.setLineWidth(pass == 0 ? a.lineWidth : a.lineWidth * 0.8)
            cg.addPath(smoothPath(pts))
            cg.strokePath()
        }
    }

    /// 手绘矩形：四边带出笔/收笔的自然越界
    private static func roughRect(_ cg: CGContext, _ rect: NSRect, a: Annotation, rng: inout SeededRandom) {
        let over = 2.0 + rng.next() * 2.5
        let corners = [
            NSPoint(x: rect.minX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.maxY),
            NSPoint(x: rect.minX, y: rect.maxY),
        ]
        for i in 0..<4 {
            let from = corners[i]
            let to = corners[(i + 1) % 4]
            let dx = to.x - from.x, dy = to.y - from.y
            let len = max(1, hypot(dx, dy))
            let ux = dx / len, uy = dy / len
            let start = NSPoint(x: from.x - ux * over, y: from.y - uy * over)
            let end = NSPoint(x: to.x + ux * over, y: to.y + uy * over)
            roughSegment(cg, from: start, to: end, a: a, rng: &rng)
        }
    }

    /// 手绘椭圆：半径低频调制（正弦谐波）+ 微相位偏移的第二圈
    private static func roughEllipse(_ cg: CGContext, _ rect: NSRect, a: Annotation, rng: inout SeededRandom) {
        let cx = rect.midX, cy = rect.midY
        let rx = max(2, rect.width / 2), ry = max(2, rect.height / 2)
        let amp = Double(min(2.2, max(0.8, min(rx, ry) * 0.03)))
        let p1 = rng.jitter(6), p2 = rng.jitter(6)
        let count = 72

        for pass in 0..<2 {
            let phase = pass == 0 ? 0.0 : 0.28
            let radiusScale = pass == 0 ? 1.0 : 1.015
            let magnitude = pass == 0 ? amp : amp * 1.5
            var pts: [NSPoint] = []
            for i in 0...count {
                let t = Double(i) / Double(count) * 2 * .pi
                let modulation = sin(3 * t + p1) * 0.45 + sin(5 * t + p2) * 0.3
                let rx2 = rx * radiusScale + magnitude * modulation
                let ry2 = ry * radiusScale + magnitude * modulation
                let x = cx + rx2 * cos(t + phase) + rng.jitter(0.25)
                let y = cy + ry2 * sin(t + phase) + rng.jitter(0.25)
                pts.append(NSPoint(x: x, y: y))
            }
            cg.setStrokeColor(a.color.withAlphaComponent(pass == 0 ? 1 : 0.32).cgColor)
            cg.setLineWidth(pass == 0 ? a.lineWidth : a.lineWidth * 0.8)
            cg.addPath(smoothPath(pts, closed: true))
            cg.strokePath()
        }
    }

    private static func roughArrow(_ cg: CGContext, from: NSPoint, to: NSPoint,
                                   a: Annotation, rng: inout SeededRandom) {
        roughSegment(cg, from: from, to: to, a: a, rng: &rng)

        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength = max(12, a.lineWidth * 4)
        for spread in [-0.42, 0.42] {
            let end = NSPoint(x: to.x - headLength * cos(angle + spread),
                              y: to.y - headLength * sin(angle + spread))
            roughSegment(cg, from: to, to: end, a: a, rng: &rng, alpha: 0.85)
        }
    }
}

/// 在**翻转坐标系**中正确绘制 CGImage 的辅助（否则图片会上下颠倒）。
enum FlippedImageDrawing {

    /// 在 flipped 视图坐标里按原始方向绘制图片（铺满指定区域）
    static func draw(_ image: CGImage, in bounds: NSRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: NSRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()
    }
}

/// 离屏渲染视图：把「裁剪后的原图 + 标注」按显示效果渲染成位图（所见即所得）。
final class SnapshotRenderView: NSView {

    private let image: CGImage
    private let annotations: [Annotation]
    private let pixelated: CGImage?

    init(image: CGImage, annotations: [Annotation], pixelated: CGImage?) {
        self.image = image
        self.annotations = annotations
        self.pixelated = pixelated
        super.init(frame: NSRect(origin: .zero,
                                 size: NSSize(width: image.width, height: image.height)))
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        FlippedImageDrawing.draw(image, in: bounds, ctx: ctx.cgContext)
        let context = RenderContext(pixelatedImage: pixelated, pixelatedRect: bounds)
        for annotation in annotations {
            AnnotationRenderer.draw(annotation, in: ctx, context: context)
        }
    }
}

enum ScreenshotCompositor {

    /// 合成「选区截图 + 标注」为位图。selection 与 annotations 同为覆盖层视图坐标（左上原点），
    /// 此处统一换算为裁剪本地坐标后再渲染。
    static func compositedRep(snapshot: CGImage, scale: CGFloat,
                              selection: NSRect, annotations: [Annotation]) -> NSBitmapImageRep {
        let pxRect = NSRect(x: floor(selection.minX * scale),
                            y: floor(selection.minY * scale),
                            width: ceil(selection.width * scale),
                            height: ceil(selection.height * scale)).integral
        let cropped = snapshot.cropping(to: pxRect) ?? snapshot
        let pixelated = MosaicEngine.pixelate(cropped)
        let ptSize = NSSize(width: CGFloat(cropped.width) / scale,
                            height: CGFloat(cropped.height) / scale)

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: max(1, cropped.width),
                                   pixelsHigh: max(1, cropped.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = ptSize

        let localAnnotations = annotations.map { $0.translated(x: -selection.minX, y: -selection.minY) }
        let renderView = SnapshotRenderView(image: cropped, annotations: localAnnotations, pixelated: pixelated)
        renderView.frame = NSRect(origin: .zero, size: ptSize)
        renderView.cacheDisplay(in: renderView.bounds, to: rep)
        return rep
    }
}
