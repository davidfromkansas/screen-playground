import Foundation

/// Mass-spring-damper parameters. Defaults come from observed Screen Studio projects.
public struct SpringConfig: Hashable, Codable, Sendable {
    public var stiffness: Double
    public var damping: Double
    public var mass: Double

    public init(stiffness: Double, damping: Double, mass: Double) {
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
    }

    public static let mouseDefault = SpringConfig(stiffness: 470, damping: 70, mass: 3)
    public static let screenDefault = SpringConfig(stiffness: 200, damping: 40, mass: 2.25)
    public static let clickDefault = SpringConfig(stiffness: 700, damping: 30, mass: 1)
}

// MARK: - Background & frame

public enum BackgroundKind: String, Codable, Sendable, CaseIterable {
    case wallpaper, gradient, color, image
}

public struct GradientStop: Hashable, Codable, Sendable {
    public var color: RGBAColor
    public var at: Double
    public init(color: RGBAColor, at: Double) {
        self.color = color
        self.at = at
    }
}

public struct GradientConfig: Hashable, Codable, Sendable {
    public var start = NormPoint(0, 0)
    public var end = NormPoint(1, 1)
    public var stops = [GradientStop(color: RGBAColor(hex: "#3F37C9"), at: 0),
                        GradientStop(color: RGBAColor(hex: "#8C87DF"), at: 1)]
    public init() {}
}

public struct BackgroundConfig: Hashable, Codable, Sendable {
    public var kind: BackgroundKind = .wallpaper
    /// Identifier of a built-in wallpaper ("procedural/aurora") or a system one ("system/<path>").
    public var wallpaper = "procedural/aurora"
    public var gradient = GradientConfig()
    public var color = RGBAColor(hex: "#3F37C9")
    /// Path of a user image, relative to the bundle's `assets/` folder or absolute.
    public var imagePath: String? = nil
    public var blur: Double = 0
    public init() {}
}

public enum ShadowStyle: String, Codable, Sendable, CaseIterable { case classic, directional }

public struct FrameConfig: Hashable, Codable, Sendable {
    /// Padding as a fraction of the shorter output side (0 = edge to edge).
    public var padding: Double = 0.08
    public var cornerRadius: Double = 12
    public var insetEnabled = false
    public var inset: Double = 0
    public var insetColor = RGBAColor.black
    public var insetOpacity: Double = 0.5
    public var shadowIntensity: Double = 0.75
    public var shadowStyle: ShadowStyle = .classic
    public var shadowAngle: Double = 90
    public var shadowDistance: Double = 25
    public var shadowBlur: Double = 20
    public init() {}
}

// MARK: - Cursor

public enum CursorSet: String, Codable, Sendable, CaseIterable {
    case system, macos, touch, outline
}

public enum ClickEffect: String, Codable, Sendable, CaseIterable { case none, circle, ripple, shockwave }
public enum ClickSound: String, Codable, Sendable, CaseIterable { case none, soft, crisp }
public enum CursorRotationMode: String, Codable, Sendable, CaseIterable { case tilt, follow }

public struct CursorConfig: Hashable, Codable, Sendable {
    public var hidden = false
    /// Multiplier on the cursor's native point size.
    public var size: Double = 1.5
    public var set: CursorSet = .system
    public var alwaysUsePointer = false
    public var hideWhenIdle = false
    public var idleHideAfter: Double = 2.0
    public var loopPosition = false
    public var loopDuration: Double = 1.0
    public var stopMovementBeforeEnd: Double = 0
    public var removeShakes = true
    public var shakeThreshold: Double = 0.5
    public var optimizeCursorChanges = true
    public var clickEffect: ClickEffect = .none
    public var clickSound: ClickSound = .none
    public var clickSoundVolume: Double = 0.25
    public var baseRotation: Double = 0
    public var rotationMode: CursorRotationMode = .tilt
    public var tiltAmount: Double = 0.5
    public init() {}
}

// MARK: - Motion

public enum CursorAnimationStyle: String, Codable, Sendable, CaseIterable {
    case smooth, medium, rapid, none

    public var spring: SpringConfig? {
        switch self {
        case .smooth: return .mouseDefault
        case .medium: return SpringConfig(stiffness: 700, damping: 75, mass: 2)
        case .rapid: return SpringConfig(stiffness: 1200, damping: 80, mass: 1.2)
        case .none: return nil
        }
    }
}

public enum ScreenAnimationStyle: String, Codable, Sendable, CaseIterable {
    case focused, smooth

    public var spring: SpringConfig {
        switch self {
        case .focused: return .screenDefault
        case .smooth: return SpringConfig(stiffness: 120, damping: 34, mass: 2.6)
        }
    }
}

public struct MotionConfig: Hashable, Codable, Sendable {
    public var cursorStyle: CursorAnimationStyle = .smooth
    public var screenStyle: ScreenAnimationStyle = .focused
    public var clickSpring = SpringConfig.clickDefault
    /// 0...1 overall motion-blur strength.
    public var motionBlur: Double = 1
    public var motionBlurCursor: Double = 1
    public var motionBlurPan: Double = 1
    public var motionBlurZoom: Double = 1
    public init() {}
}

// MARK: - Auto zoom

public struct AutoZoomConfig: Hashable, Codable, Sendable {
    public var enabled = true
    public var defaultLevel: Double = 2.0
    public var maxLevel: Double = 3.0
    public var leadIn: Double = 0.8
    public var leadOut: Double = 1.5
    public var maxClickGap: Double = 2.5
    public var mergeGap: Double = 1.0
    public init() {}
}

// MARK: - Camera

public enum CameraLayoutKind: String, Codable, Sendable, CaseIterable {
    case overlay, split, cameraOnly, screenOnly, cutout
}

public enum CameraAspect: String, Codable, Sendable, CaseIterable {
    case r16x9 = "16:9", r4x3 = "4:3", r1x1 = "1:1", r3x4 = "3:4", r9x16 = "9:16"

    public var value: Double {
        switch self {
        case .r16x9: return 16.0 / 9
        case .r4x3: return 4.0 / 3
        case .r1x1: return 1
        case .r3x4: return 3.0 / 4
        case .r9x16: return 9.0 / 16
        }
    }
}

public struct CameraConfig: Hashable, Codable, Sendable {
    public var hidden = false
    public var mirror = true
    public var layout: CameraLayoutKind = .overlay
    /// Normalized anchor in the canvas; snaps to the 8-point grid but any value is allowed.
    public var position = NormPoint(1, 1)
    public var aspect: CameraAspect = .r1x1
    /// Fraction of the shorter canvas side.
    public var size: Double = 0.28
    public var roundness: Double = 0.5
    public var scaleDuringZoom: Double = 0.7
    public var hideDuringSilence = false
    public init() {}
}

// MARK: - Output & overlays

public enum AspectRatio: String, Codable, Sendable, CaseIterable {
    case auto, wide = "16:9", vertical = "9:16", square = "1:1", classic = "4:3", tall = "3:4", portrait = "4:5"

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .wide: return "Wide 16:9"
        case .vertical: return "Vertical 9:16"
        case .square: return "Square 1:1"
        case .classic: return "Classic 4:3"
        case .tall: return "Tall 3:4"
        case .portrait: return "Portrait 4:5"
        }
    }

    /// width / height, or nil for "match the recording".
    public var value: Double? {
        switch self {
        case .auto: return nil
        case .wide: return 16.0 / 9
        case .vertical: return 9.0 / 16
        case .square: return 1
        case .classic: return 4.0 / 3
        case .tall: return 3.0 / 4
        case .portrait: return 4.0 / 5
        }
    }
}

public struct OutputConfig: Hashable, Codable, Sendable {
    public var aspect: AspectRatio = .auto
    public var crop = NormRect.full
    public init() {}
}

public struct ShortcutOverlayConfig: Hashable, Codable, Sendable {
    public var enabled = false
    public var size: Double = 1
    public var includeSingleKeys = false
    public init() {}
}

public enum CaptionHighlight: String, Codable, Sendable, CaseIterable { case line, word }

public struct CaptionConfig: Hashable, Codable, Sendable {
    public var enabled = false
    public var size: Double = 1
    public var highlight: CaptionHighlight = .word
    public init() {}
}

// MARK: - Audio

public enum MicMode: String, Codable, Sendable, CaseIterable { case standard, noiseReduction, podcast }

public struct AudioConfig: Hashable, Codable, Sendable {
    public var masterVolume: Double = 1
    public var muteMicrophone = false
    public var muteSystemAudio = false
    public var micMode: MicMode = .standard
    public var backgroundMusicPath: String? = nil
    public var backgroundMusicVolume: Double = 0.1
    public init() {}
}

/// All look-and-feel settings of a project. Presets are snapshots of this.
public struct ProjectConfig: Hashable, Codable, Sendable {
    public var background = BackgroundConfig()
    public var frame = FrameConfig()
    public var cursor = CursorConfig()
    public var motion = MotionConfig()
    public var autoZoom = AutoZoomConfig()
    public var camera = CameraConfig()
    public var output = OutputConfig()
    public var shortcuts = ShortcutOverlayConfig()
    public var captions = CaptionConfig()
    public var audio = AudioConfig()
    public init() {}
}
