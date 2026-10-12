import CoreGraphics
import Foundation

/// A point normalized to the captured content: (0,0) top-left, (1,1) bottom-right.
public struct NormPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let center = NormPoint(0.5, 0.5)

    public static func + (a: NormPoint, b: NormPoint) -> NormPoint { NormPoint(a.x + b.x, a.y + b.y) }
    public static func - (a: NormPoint, b: NormPoint) -> NormPoint { NormPoint(a.x - b.x, a.y - b.y) }
    public static func * (a: NormPoint, s: Double) -> NormPoint { NormPoint(a.x * s, a.y * s) }

    public var length: Double { (x * x + y * y).squareRoot() }
}

/// A rectangle normalized to the captured content.
public struct NormRect: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = NormRect(x: 0, y: 0, width: 1, height: 1)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: NormPoint { NormPoint(x + width / 2, y + height / 2) }

    public func union(_ p: NormPoint) -> NormRect {
        let nx = min(x, p.x), ny = min(y, p.y)
        return NormRect(x: nx, y: ny, width: max(maxX, p.x) - nx, height: max(maxY, p.y) - ny)
    }
}

/// A rectangle in global screen points (top-left origin, y increasing downwards),
/// as reported by CGEvent and CGWindowList.
public struct ScreenRect: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ r: CGRect) {
        self.init(x: r.origin.x, y: r.origin.y, width: r.width, height: r.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// Maps a global point into this rect's normalized space.
    public func normalize(x px: Double, y py: Double) -> NormPoint {
        NormPoint((px - x) / max(width, 1), (py - y) / max(height, 1))
    }
}

/// An RGBA colour stored as a hex string for readable project files.
public struct RGBAColor: Hashable, Codable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count == 8 {
            self.init(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
                      b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
        } else {
            self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255,
                      b: Double(v & 0xFF) / 255)
        }
    }

    public var hex: String {
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        if a < 1 { return String(format: "#%02X%02X%02X%02X", c(r), c(g), c(b), c(a)) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    public init(from decoder: Decoder) throws {
        self.init(hex: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let white = RGBAColor(r: 1, g: 1, b: 1)
}
