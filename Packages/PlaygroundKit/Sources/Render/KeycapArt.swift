import CoreGraphics
import CoreText
import Foundation

/// Draws a row of macOS-style keycaps (one rounded cap per key) as a premultiplied RGBA image.
enum KeycapArt {
    static func image(keys: [String], height: Double) -> CGImage? {
        let h = max(height.rounded(), 12)
        let fontSize = h * 0.46
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let pad = h * 0.36, gap = h * 0.16, shadow = h * 0.12
        let lines: [(CTLine, Double)] = keys.map { key in
            let attr = NSAttributedString(string: key, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1),
            ])
            let line = CTLineCreateWithAttributedString(attr)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            return (line, max(width + 2 * pad, h))
        }
        let totalW = lines.reduce(0) { $0 + $1.1 } + gap * Double(max(lines.count - 1, 0)) + 2 * shadow
        let totalH = h + 2 * shadow
        guard let ctx = CGContext(data: nil, width: Int(totalW.rounded(.up)), height: Int(totalH.rounded(.up)), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var x = shadow
        for (line, w) in lines {
            let rect = CGRect(x: x, y: shadow, width: w, height: h)
            let path = CGPath(roundedRect: rect, cornerWidth: h * 0.22, cornerHeight: h * 0.22, transform: nil)
            // Soft drop shadow, then the cap face with a slightly darker bottom edge.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -h * 0.05), blur: shadow, color: CGColor(gray: 0, alpha: 0.28))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(red: 0.86, green: 0.87, blue: 0.9, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
            let face = CGPath(roundedRect: rect.insetBy(dx: 0, dy: 0).offsetBy(dx: 0, dy: h * 0.05).intersection(rect),
                              cornerWidth: h * 0.22, cornerHeight: h * 0.22, transform: nil)
            ctx.addPath(face)
            ctx.setFillColor(CGColor(red: 0.985, green: 0.985, blue: 0.99, alpha: 1))
            ctx.fillPath()
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX, y: rect.midY + h * 0.02 - bounds.height / 2 - bounds.minY)
            CTLineDraw(line, ctx)
            x += w + gap
        }
        return ctx.makeImage()
    }
}
