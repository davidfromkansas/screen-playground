import CoreGraphics
import Foundation
import ImageIO
import PlaygroundCore

/// Produces high-resolution cursor sprites for rendering. Thread-safe (no AppKit).
///
/// Recorded cursors that match a known system cursor are replaced with vector art:
/// the arrow and I-beam are drawn procedurally, and the others come from the system's own
/// cursor PDFs in HIServices (read at runtime, never redistributed). Anything else uses the
/// recorded PNG.
public enum CursorArt {
    /// Raster scale for sprites (point size × this). 6x stays sharp at 4K while zoomed.
    public static let rasterScale: CGFloat = 6

    public struct Sprite: @unchecked Sendable {
        public var image: CGImage
        /// Size in points.
        public var size: CGSize
        /// Hotspot in points from the top-left.
        public var hotSpot: CGPoint
    }

    static let hiServicesCursors = URL(fileURLWithPath:
        "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors")

    /// Maps our system-cursor names to HIServices folder names.
    static let pdfNames: [String: String] = [
        "pointingHand": "pointinghand", "openHand": "openhand", "closedHand": "closedhand", "crosshair": "cross",
        "resizeLeftRight": "resizeleftright", "resizeUpDown": "resizeupdown", "operationNotAllowed": "notallowed",
        "dragCopy": "copy", "contextualMenu": "contextualmenu", "zoomIn": "zoomin", "zoomOut": "zoomout",
        "resizeLeft": "resizeleft", "resizeRight": "resizeright", "resizeUp": "resizeup", "resizeDown": "resizedown",
        "move": "move", "help": "help", "busyButClickable": "busybutclickable",
    ]

    public static func sprite(for info: CursorImageInfo?, set: CursorSet, cursorsFolder: URL?) -> Sprite? {
        switch set {
        case .touch: return touch()
        case .outline: return arrow(fill: CGColor(gray: 1, alpha: 1), stroke: CGColor(gray: 0, alpha: 1))
        case .macos:
            if let name = info?.systemMatch, name != "arrow", let s = systemSprite(named: name) { return s }
            return systemSprite(named: "arrow")
        case .system:
            if let name = info?.systemMatch, let s = systemSprite(named: name) { return s }
            if let info, let folder = cursorsFolder,
               let src = CGImageSourceCreateWithURL(folder.appendingPathComponent(info.file) as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return Sprite(image: img, size: CGSize(width: info.width, height: info.height),
                              hotSpot: CGPoint(x: info.hotSpotX, y: info.hotSpotY))
            }
            return systemSprite(named: "arrow")
        }
    }

    public static func systemSprite(named name: String) -> Sprite? {
        switch name {
        case "arrow": return arrow(fill: CGColor(gray: 0, alpha: 1), stroke: CGColor(gray: 1, alpha: 1))
        case "iBeam": return iBeam()
        default:
            guard let folder = pdfNames[name] else { return nil }
            return pdfSprite(folder: folder)
        }
    }

    static func pdfSprite(folder: String) -> Sprite? {
        let dir = hiServicesCursors.appendingPathComponent(folder)
        guard let doc = CGPDFDocument(dir.appendingPathComponent("cursor.pdf") as CFURL), let page = doc.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let plist = (try? Data(contentsOf: dir.appendingPathComponent("info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let hotX = (plist?["hotx"] as? Double) ?? Double(box.width / 2)
        let hotY = (plist?["hoty"] as? Double) ?? Double(box.height / 2)
        let s = rasterScale
        guard let img = render(size: CGSize(width: box.width * s, height: box.height * s), draw: { ctx in
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
            ctx.drawPDFPage(page)
        }) else { return nil }
        return Sprite(image: img, size: box.size, hotSpot: CGPoint(x: hotX, y: hotY))
    }

    /// macOS-style arrow: black fill with white outline and a soft shadow.
    static func arrow(fill: CGColor, stroke: CGColor) -> Sprite? {
        let size = CGSize(width: 22, height: 30)
        let s = rasterScale
        guard let img = render(size: CGSize(width: size.width * s, height: size.height * s), draw: { ctx in
            // Points in top-left coordinates, flipped into CG space.
            let pts: [(CGFloat, CGFloat)] = [(4, 3), (4, 22.5), (8.6, 18.2), (11.6, 25.2), (14.7, 23.9), (11.8, 17.1), (17.8, 17.1)]
            let path = CGMutablePath()
            path.addLines(between: pts.map { CGPoint(x: $0.0 * s, y: (size.height - $0.1) * s) })
            path.closeSubpath()
            ctx.setShadow(offset: CGSize(width: 0, height: -1 * s), blur: 2.2 * s, color: CGColor(gray: 0, alpha: 0.45))
            ctx.addPath(path)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(2.6 * s)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            // The fill covers the inner half of the stroke, leaving an outline outside the shape.
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addPath(path)
            ctx.setFillColor(fill)
            ctx.fillPath()
        }) else { return nil }
        return Sprite(image: img, size: size, hotSpot: CGPoint(x: 4, y: 3))
    }

    static func iBeam() -> Sprite? {
        let size = CGSize(width: 12, height: 22)
        let s = rasterScale
        guard let img = render(size: CGSize(width: size.width * s, height: size.height * s), draw: { ctx in
            let path = CGMutablePath()
            let midX = size.width / 2
            for (a, b) in [((midX, 3.0), (midX, 19.0)), ((midX - 3.5, 2.0), (midX + 3.5, 2.0)), ((midX - 3.5, 20.0), (midX + 3.5, 20.0))] {
                path.move(to: CGPoint(x: a.0 * s, y: (size.height - a.1) * s))
                path.addLine(to: CGPoint(x: b.0 * s, y: (size.height - b.1) * s))
            }
            ctx.setLineCap(.round)
            ctx.addPath(path)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(3.2 * s)
            ctx.strokePath()
            ctx.addPath(path)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(1.4 * s)
            ctx.strokePath()
        }) else { return nil }
        return Sprite(image: img, size: size, hotSpot: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    static func touch() -> Sprite? {
        let pt: CGFloat = 28
        let px = pt * rasterScale
        guard let img = render(size: CGSize(width: px, height: px), draw: { ctx in
            let r = CGRect(x: px * 0.1, y: px * 0.1, width: px * 0.8, height: px * 0.8)
            ctx.setShadow(offset: .zero, blur: px * 0.06, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.6))
            ctx.fillEllipse(in: r)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.2))
            ctx.setLineWidth(px * 0.03)
            ctx.strokeEllipse(in: r)
        }) else { return nil }
        return Sprite(image: img, size: CGSize(width: pt, height: pt), hotSpot: CGPoint(x: pt / 2, y: pt / 2))
    }

    static func render(size: CGSize, draw: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width.rounded()), height: Int(size.height.rounded()), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        draw(ctx)
        return ctx.makeImage()
    }
}
