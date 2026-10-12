import CoreGraphics
import CoreText
import Foundation

/// Draws a caption — white, centred, wrapped text on a dark rounded pill — as a premultiplied RGBA image.
enum CaptionArt {
    static func image(text: String, fontSize: Double, maxWidth: Double) -> CGImage? {
        let size = max(fontSize.rounded(), 10)
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let bold = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) ?? font
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { ptr in
            CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: ptr)], 1)
        }
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): bold,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
        let padX = size * 0.9, padY = size * 0.5, shadow = size * 0.5
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let textMax = max(maxWidth - 2 * padX, size * 4)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: textMax, height: .greatestFiniteMagnitude), nil)
        let textW = ceil(fit.width), textH = ceil(fit.height)
        let pill = CGRect(x: shadow, y: shadow, width: textW + 2 * padX, height: textH + 2 * padY)
        let totalW = pill.width + 2 * shadow, totalH = pill.height + 2 * shadow
        guard let ctx = CGContext(data: nil, width: Int(totalW.rounded(.up)), height: Int(totalH.rounded(.up)), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let radius = min(size * 0.7, pill.height / 2)
        let path = CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.08), blur: shadow, color: CGColor(gray: 0, alpha: 0.3))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 0.82))
        ctx.fillPath()
        ctx.restoreGState()
        let textRect = CGRect(x: pill.minX + padX, y: pill.minY + padY, width: textW, height: textH)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: textRect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }
}
