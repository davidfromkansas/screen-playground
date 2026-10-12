import PlaygroundCore

/// A rectangle in output pixels (top-left origin).
public struct PixelRect: Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    /// Maps a normalized point inside this rect to pixels.
    public func point(_ p: NormPoint) -> (x: Double, y: Double) { (x + p.x * width, y + p.y * height) }

    public func insetBy(_ d: Double) -> PixelRect {
        PixelRect(x: x + d, y: y + d, width: max(0, width - 2 * d), height: max(0, height - 2 * d))
    }
}

/// Pose of the cursor sprite for one motion-blur sub-sample.
public struct CursorPose: Hashable, Sendable {
    /// Hotspot position in pixels.
    public var x: Double
    public var y: Double
    /// Pixels per cursor point (cursor size setting × zoom × click squash).
    public var scale: Double
    public var rotation: Double
    public var opacity: Double
}

public struct ClickEffectDesc: Hashable, Sendable {
    public var kind: ClickEffect
    public var x: Double
    public var y: Double
    /// 0...1 progress of the effect animation.
    public var progress: Double
    public var radius: Double
}

public struct MaskDesc: Hashable, Sendable {
    public var kind: MaskKind
    public var rect: PixelRect
    public var opacity: Double
}

public struct LoupeDesc: Hashable, Sendable {
    public var centerX: Double
    public var centerY: Double
    public var radius: Double
    public var magnification: Double
    public var opacity: Double
}

public struct CameraDesc: Hashable, Sendable {
    public var rect: PixelRect
    public var cornerRadius: Double
    public var mirror: Bool
    /// Normalized crop of the camera frame to match the target aspect.
    public var crop: NormRect
    public var opacity: Double
}

public struct ShadowDesc: Hashable, Sendable {
    public var opacity: Double
    public var blur: Double
    public var offsetX: Double
    public var offsetY: Double
}

/// A keyboard-shortcut overlay: keycap labels drawn as a pill near the bottom of the frame.
public struct KeycapDesc: Hashable, Sendable {
    public var keys: [String]
    public var centerX: Double
    public var bottomY: Double
    /// Keycap height in pixels.
    public var height: Double
    public var opacity: Double
}

/// Everything the compositor needs to draw one output frame. Plain values, no GPU types.
public struct FrameDescription: Sendable {
    public var width: Int
    public var height: Int
    public var background: BackgroundConfig
    /// Source time of the screen frame to show.
    public var sourceTime: SourceTime
    /// Normalized crop of the recorded frame.
    public var crop: NormRect
    /// Screen layer quad per motion-blur sub-sample (all share equal weight).
    public var screenQuads: [PixelRect]
    public var cornerRadius: Double
    public var shadow: ShadowDesc
    public var insetWidth: Double
    public var insetColor: RGBAColor
    public var cursorID: String?
    public var cursorPoses: [CursorPose]
    public var clickEffects: [ClickEffectDesc]
    public var masks: [MaskDesc]
    public var loupe: LoupeDesc?
    public var camera: CameraDesc?
    public var keycaps: KeycapDesc?
    /// Screen layer opacity (0 for camera-only layouts).
    public var screenOpacity: Double
}
