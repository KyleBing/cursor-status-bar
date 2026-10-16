import AppKit

enum StatusRingImage {
    // 单环 Auto 仍用绿色扇形；三环模式全部黑色，交给菜单栏模板色随亮/暗变化
    private static let autoPieColor = NSColor.systemGreen

    // 菜单栏：默认内圈 Auto 扇形；三环时外环 Auto、中环 API、最里 Demand 实心扇形
    static func make(
        autoPercent: Int?,
        apiPercent: Int? = nil,
        ondPercent: Int? = nil,
        showExtraRings: Bool = false
    ) -> NSImage {
        // 单环和三环用同一画布，外缘大小保持一致
        let size: CGFloat = 21
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            if showExtraRings {
                drawTripleRings(
                    center: center,
                    rect: rect,
                    autoPercent: autoPercent,
                    apiPercent: apiPercent,
                    ondPercent: ondPercent
                )
            } else {
                drawAutoPie(center: center, rect: rect, autoPercent: autoPercent)
            }
            return true
        }
        // 模板图只认黑色和透明度，菜单栏会在亮色用黑、暗色用白
        image.isTemplate = showExtraRings
        return image
    }

    // 外环 Auto、中环 API 描边；最里 Demand 实心扇形。外缘与单环扇形对齐
    private static func drawTripleRings(
        center: NSPoint,
        rect: NSRect,
        autoPercent: Int?,
        apiPercent: Int?,
        ondPercent: Int?
    ) {
        let ringWidth: CGFloat = 1.95
        // 环与环之间留出略宽的缝，避免三环贴在一起
        let ringGap: CGFloat = 0.75
        // 与 drawAutoPie 的 pieRadius 相同，保证外圈视觉大小一致
        let outerEdge = min(rect.width, rect.height) / 2 - 0.4
        let outerRadius = outerEdge - ringWidth / 2
        let midRadius = outerRadius - ringWidth - ringGap
        let innerRadius = midRadius - ringWidth / 2 - ringGap
        let ink = NSColor.black

        drawStrokeRing(center: center, radius: outerRadius, width: ringWidth, percent: autoPercent, color: ink)
        drawStrokeRing(center: center, radius: midRadius, width: ringWidth, percent: apiPercent, color: ink)
        drawInnerPie(center: center, radius: innerRadius, percent: ondPercent, color: ink)
    }

    // 单环：Auto 剩余扇形 + 中间数字
    private static func drawAutoPie(center: NSPoint, rect: NSRect, autoPercent: Int?) {
        let pieRadius = min(rect.width, rect.height) / 2 - 0.4
        let used = NSBezierPath(ovalIn: NSRect(
            x: center.x - pieRadius,
            y: center.y - pieRadius,
            width: pieRadius * 2,
            height: pieRadius * 2
        ))
        NSColor.black.withAlphaComponent(0.72).setFill()
        used.fill()

        if let percent = autoPercent {
            let p = min(100, max(0, percent))
            if p > 0 {
                drawPie(center: center, radius: pieRadius, percent: p, color: autoPieColor)
            }
            drawCenterText("\(p)", in: rect, fontSize: p >= 100 ? 7 : 8.5)
        } else {
            drawCenterText("--", in: rect, fontSize: 8)
        }
    }

    // 剩余百分比扇形（从 12 点顺时针）
    private static func drawPie(center: NSPoint, radius: CGFloat, percent: Int, color: NSColor) {
        let startDeg: CGFloat = 90
        let endDeg = startDeg - 360 * CGFloat(percent) / 100
        let pie = NSBezierPath()
        pie.move(to: center)
        pie.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: startDeg,
            endAngle: endDeg,
            clockwise: true
        )
        pie.close()
        color.setFill()
        pie.fill()
    }

    // 最内层实心扇形：暗色底盘 + 剩余百分比实心扇区
    private static func drawInnerPie(center: NSPoint, radius: CGFloat, percent: Int?, color: NSColor) {
        let disk = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        NSColor.black.withAlphaComponent(0.28).setFill()
        disk.fill()

        guard let percent else { return }
        let p = min(100, max(0, percent))
        guard p > 0 else { return }
        drawPie(center: center, radius: radius, percent: p, color: color)
    }

    // 描边环：底轨 + 剩余弧；percent 为 nil 时只画暗轨
    private static func drawStrokeRing(
        center: NSPoint,
        radius: CGFloat,
        width: CGFloat,
        percent: Int?,
        color: NSColor
    ) {
        let track = NSBezierPath()
        track.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 0,
            endAngle: 360,
            clockwise: false
        )
        track.lineWidth = width
        // 底轨用较低透明度，剩余弧用实色，模板模式下仍能分出进度
        NSColor.black.withAlphaComponent(0.28).setStroke()
        track.stroke()

        guard let percent else { return }
        let p = min(100, max(0, percent))
        guard p > 0 else { return }
        let startDeg: CGFloat = 90
        let endDeg = startDeg - 360 * CGFloat(p) / 100
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: startDeg,
            endAngle: endDeg,
            clockwise: true
        )
        arc.lineWidth = width
        arc.lineCapStyle = .butt
        color.setStroke()
        arc.stroke()
    }

    private static func drawCenterText(_ text: String, in rect: NSRect, fontSize: CGFloat) {
        let ns = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let ts = ns.size(withAttributes: attrs)
        ns.draw(
            at: NSPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2 - 0.4),
            withAttributes: attrs
        )
    }
}
