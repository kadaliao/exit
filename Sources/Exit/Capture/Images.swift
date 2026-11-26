import AppKit

/// Procedural images: the demo window used for previews, and the stand-in card used when
/// Screen Recording is not granted.
enum Images {
    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// Draws with a top-left origin in points.
    private static func draw(size: CGSize, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard let ctx = context(w, h) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        body(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static let demoCorner: CGFloat = 16

    /// A believable app window with a sidebar, a photo and some text.
    static func demoWindow(size: CGSize = CGSize(width: 720, height: 460), scale: CGFloat = 2, dark: Bool = false) -> CGImage? {
        draw(size: size, scale: scale) { ctx in
            let bounds = CGRect(origin: .zero, size: size)
            let shape = NSBezierPath(roundedRect: bounds, xRadius: demoCorner, yRadius: demoCorner)
            shape.addClip()

            let bg = dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor(calibratedWhite: 0.985, alpha: 1)
            bg.setFill(); bounds.fill()

            // Sidebar
            let sidebar = CGRect(x: 0, y: 0, width: 190, height: size.height)
            (dark ? NSColor(calibratedWhite: 0.18, alpha: 1) : NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)).setFill()
            sidebar.fill()

            // Traffic lights
            let lights: [NSColor] = [
                NSColor(calibratedRed: 1.0, green: 0.37, blue: 0.34, alpha: 1),
                NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.18, alpha: 1),
                NSColor(calibratedRed: 0.16, green: 0.79, blue: 0.25, alpha: 1),
            ]
            for (i, c) in lights.enumerated() {
                c.setFill()
                NSBezierPath(ovalIn: CGRect(x: 18 + CGFloat(i) * 20, y: 18, width: 12, height: 12)).fill()
            }

            // Sidebar items
            let labels = ["Inbox", "Today", "Photos", "Projects", "Archive"]
            let textColor = dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.2, alpha: 1)
            for (i, label) in labels.enumerated() {
                let y = 62 + CGFloat(i) * 30
                if i == 2 {
                    NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                    NSBezierPath(roundedRect: CGRect(x: 10, y: y - 6, width: 170, height: 26), xRadius: 7, yRadius: 7).fill()
                }
                let color = i == 2 ? NSColor.white : textColor
                NSColor(calibratedHue: CGFloat(i) / 5, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: 22, y: y, width: 14, height: 14), xRadius: 4, yRadius: 4).fill()
                (label as NSString).draw(at: CGPoint(x: 44, y: y - 2), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: color,
                ])
            }

            // Title
            ("Weekend in Kyoto" as NSString).draw(at: CGPoint(x: 214, y: 22), withAttributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: textColor,
            ])
            ("Photos · 24 items" as NSString).draw(at: CGPoint(x: 214, y: 54), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ])

            // Hero "photo": sunset gradient with mountains and a sun
            let hero = CGRect(x: 214, y: 84, width: size.width - 238, height: 200)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: hero, xRadius: 12, yRadius: 12).addClip()
            NSGradient(colors: [
                NSColor(calibratedRed: 0.20, green: 0.25, blue: 0.62, alpha: 1),
                NSColor(calibratedRed: 0.93, green: 0.40, blue: 0.45, alpha: 1),
                NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.42, alpha: 1),
            ])?.draw(in: hero, angle: -90)
            NSColor(calibratedRed: 1, green: 0.93, blue: 0.7, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: hero.midX + 40, y: hero.minY + 80, width: 64, height: 64)).fill()
            let mountains = NSBezierPath()
            mountains.move(to: CGPoint(x: hero.minX, y: hero.maxY))
            var x = hero.minX
            var up = true
            while x < hero.maxX {
                x += 60 + CGFloat(Int(x) % 37)
                mountains.line(to: CGPoint(x: x, y: hero.minY + (up ? 110 : 160)))
                up.toggle()
            }
            mountains.line(to: CGPoint(x: hero.maxX, y: hero.maxY))
            mountains.close()
            NSColor(calibratedRed: 0.17, green: 0.13, blue: 0.30, alpha: 0.9).setFill()
            mountains.fill()
            NSGraphicsContext.restoreGraphicsState()

            // Thumbnails
            let thumbW = (hero.width - 3 * 12) / 4
            for i in 0..<4 {
                let r = CGRect(x: hero.minX + CGFloat(i) * (thumbW + 12), y: hero.maxY + 16, width: thumbW, height: 64)
                NSGradient(colors: [
                    NSColor(calibratedHue: 0.08 + CGFloat(i) * 0.18, saturation: 0.55, brightness: 0.95, alpha: 1),
                    NSColor(calibratedHue: 0.15 + CGFloat(i) * 0.18, saturation: 0.75, brightness: 0.70, alpha: 1),
                ])?.draw(in: NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9), angle: -60)
            }

            // Text lines
            let lineColor = dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.10)
            lineColor.setFill()
            for i in 0..<3 {
                let w = (hero.width) * [0.92, 0.78, 0.55][i]
                NSBezierPath(roundedRect: CGRect(x: hero.minX, y: hero.maxY + 98 + CGFloat(i) * 16, width: w, height: 8),
                             xRadius: 4, yRadius: 4).fill()
            }
            _ = ctx
        }
    }

    /// Stand-in card: app icon and window title on a frosted card.
    static func placeholder(size: CGSize, scale: CGFloat, icon: NSImage?, title: String?, corner: CGFloat) -> CGImage? {
        let size = CGSize(width: max(size.width, 40), height: max(size.height, 40))
        let dark = AppAppearance.systemIsDark
        return draw(size: size, scale: scale) { _ in
            let bounds = CGRect(origin: .zero, size: size)
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: corner, yRadius: corner)
            NSGradient(colors: dark
                       ? [NSColor(white: 0.20, alpha: 0.96), NSColor(white: 0.12, alpha: 0.96)]
                       : [NSColor(white: 0.99, alpha: 0.96), NSColor(white: 0.90, alpha: 0.96)])?
                .draw(in: shape, angle: -90)
            (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.12)).setStroke()
            shape.lineWidth = 1
            shape.stroke()

            let side = min(min(size.width, size.height) * 0.35, 128)
            let iconRect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2 - 10, width: side, height: side)
            icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

            if let title, !title.isEmpty, size.height > 160 {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                style.lineBreakMode = .byTruncatingTail
                (title as NSString).draw(in: CGRect(x: 20, y: iconRect.maxY + 14, width: size.width - 40, height: 20), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                    .foregroundColor: dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.25, alpha: 1),
                    .paragraphStyle: style,
                ])
            }
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Exit", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
        }
        try data.write(to: url)
    }

    /// Composites frames onto a checkerboard-free dark backdrop grid.
    static func contactSheet(rows: [(label: String, frames: [CGImage])], cell: CGSize, background: CGImage? = nil) -> CGImage? {
        let cols = rows.map(\.frames.count).max() ?? 0
        let labelW: CGFloat = 150
        let size = CGSize(width: labelW + CGFloat(cols) * cell.width, height: CGFloat(rows.count) * cell.height)
        return draw(size: size, scale: 1) { ctx in
            NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1).setFill()
            CGRect(origin: .zero, size: size).fill()
            for (r, row) in rows.enumerated() {
                let y = CGFloat(r) * cell.height
                (row.label as NSString).draw(in: CGRect(x: 8, y: y + cell.height / 2 - 10, width: labelW - 12, height: 40), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
                ])
                for (c, img) in row.frames.enumerated() {
                    let rect = CGRect(x: labelW + CGFloat(c) * cell.width, y: y, width: cell.width, height: cell.height)
                    // Desktop-like backdrop so transparency reads correctly.
                    NSGradient(colors: [NSColor(calibratedRed: 0.24, green: 0.36, blue: 0.52, alpha: 1),
                                        NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.48, alpha: 1)])?
                        .draw(in: rect.insetBy(dx: 2, dy: 2), angle: -45)
                    ctx.saveGState()
                    // Undo the flip for CGImage drawing.
                    ctx.translateBy(x: rect.minX, y: rect.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(img, in: CGRect(origin: .zero, size: rect.size).insetBy(dx: 2, dy: 2))
                    ctx.restoreGState()
                }
            }
        }
    }
}
