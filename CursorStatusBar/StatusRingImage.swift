import AppKit

enum StatusRingImage {
    // 内圈 Auto 绿、中环 API 蓝、外环 Ond 橙：固定色
    private static let autoPieColor = NSColor.systemGreen
    private static let apiRingColor = NSColor.systemBlue
    private static let ondRingColor = NSColor.systemOrange

    // 菜单栏：内圈 Auto 扇形；可选外圈 API / Ond 描边环
    static func make(
        autoPercent: Int?,
        apiPercent: Int? = nil,
        ondPercent: Int? = nil,
        showExtraRings: Bool = false
    ) -> NSImage {
        let size: CGFloat = showExtraRings ? 28 : 21
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            // 展示外环时环加粗，内圈缩小
            let ringWidth: CGFloat = 2.9
            let ringGap: CGFloat = 0

            let maxRadius = min(rect.width, rect.height) / 2 - 0.4
            let outerRadius: CGFloat
            let midRadius: CGFloat
            let pieRadius: CGFloat
            if showExtraRings {
                outerRadius = maxRadius - ringWidth / 2
                midRadius = outerRadius - ringWidth - ringGap
                // 内圈明显小于双环，留一点呼吸感
                pieRadius = midRadius - ringWidth / 2 - 1.4
            } else {
                outerRadius = 0
                midRadius = 0
                pieRadius = maxRadius
            }

            // 已用完：深色底圈
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
                // 展示外环时不画数字，只保留扇形
                if !showExtraRings {
                    drawCenterText("\(p)", in: rect, fontSize: p >= 100 ? 7 : 8.5)
                }
            } else if !showExtraRings {
                drawCenterText("--", in: rect, fontSize: 8)
            }

            if showExtraRings {
                // 中环：API；外环：On-demand
                drawStrokeRing(
                    center: center,
                    radius: midRadius,
                    width: ringWidth,
                    percent: apiPercent,
                    color: apiRingColor
                )
                drawStrokeRing(
                    center: center,
                    radius: outerRadius,
                    width: ringWidth,
                    percent: ondPercent,
                    color: ondRingColor
                )
            }
            return true
        }
        image.isTemplate = false
        return image
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
        NSColor.white.withAlphaComponent(0.18).setStroke()
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
