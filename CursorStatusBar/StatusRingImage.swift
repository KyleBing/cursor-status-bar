import AppKit

enum StatusRingImage {
    // 菜单栏：Auto 剩余扇形；已用部分更深，数字白色
    static func make(percent: Int?, size: CGFloat = 21) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset: CGFloat = 0.8
            let bounds = rect.insetBy(dx: inset, dy: inset)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = min(bounds.width, bounds.height) / 2

            // 已用完：深色底圈
            let used = NSBezierPath(ovalIn: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            NSColor.black.withAlphaComponent(0.72).setFill()
            used.fill()

            if let percent {
                let p = min(100, max(0, percent))
                if p > 0 {
                    let startDeg: CGFloat = 90
                    let endDeg = startDeg - 360 * CGFloat(p) / 100
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
                    fillColor(p).setFill()
                    pie.fill()
                }

                let text = "\(p)" as NSString
                let font = NSFont.systemFont(ofSize: p >= 100 ? 7 : 8.5, weight: .bold)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.white
                ]
                let ts = text.size(withAttributes: attrs)
                text.draw(
                    at: NSPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2 - 0.4),
                    withAttributes: attrs
                )
            } else {
                let text = "--" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                    .foregroundColor: NSColor.white
                ]
                let ts = text.size(withAttributes: attrs)
                text.draw(
                    at: NSPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2 - 0.4),
                    withAttributes: attrs
                )
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func fillColor(_ percent: Int) -> NSColor {
        if percent <= 15 { return NSColor.systemRed }
        if percent <= 35 { return NSColor.systemOrange }
        return NSColor.systemGreen
    }
}
