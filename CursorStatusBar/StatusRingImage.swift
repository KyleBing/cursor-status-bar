import AppKit

enum StatusRingImage {
    // 单环 Auto 仍用绿色扇形
    private static let autoPieColor = NSColor.systemGreen
    // 三柱固定色：绿 Auto、蓝 API、橙 On-demand
    private static let autoBarColor = NSColor(srgbRed: 0.22, green: 0.80, blue: 0.38, alpha: 1)
    private static let apiBarColor = NSColor(srgbRed: 0.25, green: 0.56, blue: 1.00, alpha: 1)
    private static let ondBarColor = NSColor(srgbRed: 1.00, green: 0.62, blue: 0.12, alpha: 1)
    // 三柱图标比单环更宽，状态栏占位要跟着变
    static let barIconSize = NSSize(width: 27, height: 18)
    static let pieIconSize = NSSize(width: 21, height: 21)

    // 菜单栏：默认 Auto 扇形；打开后改成三根整柱
    static func make(
        autoPercent: Int?,
        apiPercent: Int? = nil,
        ondPercent: Int? = nil,
        showExtraRings: Bool = false
    ) -> NSImage {
        let size = showExtraRings ? barIconSize : pieIconSize
        let image = NSImage(size: size, flipped: false) { rect in
            if showExtraRings {
                drawUsageBars(
                    rect: rect,
                    autoPercent: autoPercent,
                    apiPercent: apiPercent,
                    ondPercent: ondPercent
                )
            } else {
                drawAutoPie(center: NSPoint(x: rect.midX, y: rect.midY), rect: rect, autoPercent: autoPercent)
            }
            return true
        }
        // 柱子带颜色，不能当模板图，否则菜单栏会抹成黑白
        image.isTemplate = false
        return image
    }

    // 左 Auto、中 API、右 On-demand。淡色是整根柱，实色从底部按剩余比例填
    private static func drawUsageBars(
        rect: NSRect,
        autoPercent: Int?,
        apiPercent: Int?,
        ondPercent: Int?
    ) {
        let specs: [(Int?, NSColor)] = [
            (autoPercent, autoBarColor),
            (apiPercent, apiBarColor),
            (ondPercent, ondBarColor)
        ]
        let inset: CGFloat = 1
        let gap: CGFloat = 2
        let barWidth = (rect.width - inset * 2 - gap * CGFloat(specs.count - 1)) / CGFloat(specs.count)
        let bottom = inset
        let fullHeight = rect.height - inset * 2

        for (index, spec) in specs.enumerated() {
            let x = inset + CGFloat(index) * (barWidth + gap)
            let track = NSRect(x: x, y: bottom, width: barWidth, height: fullHeight)
            spec.1.withAlphaComponent(0.28).setFill()
            track.fill()

            guard let percent = spec.0 else { continue }
            let p = min(100, max(0, percent))
            let filled = fullHeight * CGFloat(p) / 100
            guard filled > 0 else { continue }
            let bar = NSRect(x: x, y: bottom, width: barWidth, height: filled)
            spec.1.setFill()
            bar.fill()
        }
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
