import Foundation

public typealias ItemID = String

public func makeItemID() -> ItemID {
    let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    return String((0..<10).map { _ in chars.randomElement()! })
}

/// One segment of the edit: a range of source time played at `timeScale`.
/// `timeScale` follows Screen Studio's convention: output duration = source duration × timeScale,
/// so 0.5 plays twice as fast.
public struct Slice: Hashable, Codable, Sendable, Identifiable {
    public var id: ItemID
    public var source: SourceRange
    public var timeScale: Double
    public var volume: Double
    public var systemAudioVolume: Double
    public var hideCursor: Bool
    public var disableSmoothing: Bool
    /// When true, the slice holds the frame at `source.start` for `freezeDuration` seconds.
    public var freezeDuration: Double?

    public init(id: ItemID = makeItemID(), source: SourceRange, timeScale: Double = 1, volume: Double = 1,
                systemAudioVolume: Double = 1, hideCursor: Bool = false, disableSmoothing: Bool = false,
                freezeDuration: Double? = nil) {
        self.id = id
        self.source = source
        self.timeScale = timeScale
        self.volume = volume
        self.systemAudioVolume = systemAudioVolume
        self.hideCursor = hideCursor
        self.disableSmoothing = disableSmoothing
        self.freezeDuration = freezeDuration
    }

    /// Playback speed multiplier (2 = twice as fast).
    public var speed: Double { 1 / timeScale }

    public var outputDuration: Double {
        if let freeze = freezeDuration { return freeze }
        return source.duration * timeScale
    }
}

public enum ZoomMode: String, Codable, Sendable { case auto, manual }
public enum ZoomStyle: String, Codable, Sendable { case classic, loupe }

/// A zoom anchored in source time so cuts and speed changes never displace it.
public struct ZoomRange: Hashable, Codable, Sendable, Identifiable {
    public var id: ItemID
    public var source: SourceRange
    public var level: Double
    public var mode: ZoomMode
    public var style: ZoomStyle
    public var manualTarget: NormPoint
    /// Dead-zone (fraction of the viewport) before the camera re-centers on the cursor.
    public var deadZone: Double
    public var instant: Bool
    public var disabled: Bool
    /// True when created by auto-zoom (regenerating replaces these, not user ones).
    public var isAuto: Bool

    public init(id: ItemID = makeItemID(), source: SourceRange, level: Double = 2, mode: ZoomMode = .auto,
                style: ZoomStyle = .classic, manualTarget: NormPoint = .center, deadZone: Double = 0.25,
                instant: Bool = false, disabled: Bool = false, isAuto: Bool = false) {
        self.id = id
        self.source = source
        self.level = level
        self.mode = mode
        self.style = style
        self.manualTarget = manualTarget
        self.deadZone = deadZone
        self.instant = instant
        self.disabled = disabled
        self.isAuto = isAuto
    }
}

public struct LayoutRange: Hashable, Codable, Sendable, Identifiable {
    public var id: ItemID
    public var source: SourceRange
    public var layout: CameraLayoutKind
    public var cameraSize: Double?

    public init(id: ItemID = makeItemID(), source: SourceRange, layout: CameraLayoutKind, cameraSize: Double? = nil) {
        self.id = id
        self.source = source
        self.layout = layout
        self.cameraSize = cameraSize
    }
}

public enum MaskKind: String, Codable, Sendable, CaseIterable { case blur, solid, blend, highlight }

public struct MaskRange: Hashable, Codable, Sendable, Identifiable {
    public var id: ItemID
    public var source: SourceRange
    public var kind: MaskKind
    public var rect: NormRect
    public var opacity: Double

    public init(id: ItemID = makeItemID(), source: SourceRange, kind: MaskKind = .blur,
                rect: NormRect = NormRect(x: 0.35, y: 0.35, width: 0.3, height: 0.2), opacity: Double = 0.7) {
        self.id = id
        self.source = source
        self.kind = kind
        self.rect = rect
        self.opacity = opacity
    }
}

/// On-screen text shown over a source range (e.g. a demo script's step captions).
public struct CaptionRange: Hashable, Codable, Sendable, Identifiable {
    public var id: ItemID
    public var source: SourceRange
    public var text: String

    public init(id: ItemID = makeItemID(), source: SourceRange, text: String) {
        self.id = id
        self.source = source
        self.text = text
    }
}

/// One recording plus all edits on it. Projects can hold several scenes (multi-clip, post-v1).
public struct Scene: Hashable, Codable, Sendable, Identifiable {
    public var id: ItemID = makeItemID()
    public var name = "Default"
    public var slices: [Slice] = []
    public var zooms: [ZoomRange] = []
    public var layouts: [LayoutRange] = []
    public var masks: [MaskRange] = []
    public var captions: [CaptionRange] = []
    /// Keystroke indices hidden from the shortcut overlay.
    public var hiddenShortcutIndices: Set<Int> = []

    public init() {}

    enum CodingKeys: String, CodingKey { case id, name, slices, zooms, layouts, masks, captions, hiddenShortcutIndices }

    /// Scenes live in an array, which TolerantJSON can't fill with defaults, so every field is optional
    /// here: projects saved by older versions (no `captions`, …) still open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(ItemID.self, forKey: .id) ?? makeItemID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Default"
        slices = try c.decodeIfPresent([Slice].self, forKey: .slices) ?? []
        zooms = try c.decodeIfPresent([ZoomRange].self, forKey: .zooms) ?? []
        layouts = try c.decodeIfPresent([LayoutRange].self, forKey: .layouts) ?? []
        masks = try c.decodeIfPresent([MaskRange].self, forKey: .masks) ?? []
        captions = try c.decodeIfPresent([CaptionRange].self, forKey: .captions) ?? []
        hiddenShortcutIndices = try c.decodeIfPresent(Set<Int>.self, forKey: .hiddenShortcutIndices) ?? []
    }
}
