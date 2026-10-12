import Foundation

/// Modifier flags captured with input events.
public struct Modifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = Modifiers(rawValue: 1 << 0)
    public static let control = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)
    public static let function = Modifiers(rawValue: 1 << 4)
    public static let capsLock = Modifiers(rawValue: 1 << 5)
}

/// Mouse position sample. `t` is source time in seconds; x/y are global screen points.
public struct MouseMove: Hashable, Codable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double
    public var cursor: String?

    public init(t: Double, x: Double, y: Double, cursor: String? = nil) {
        self.t = t
        self.x = x
        self.y = y
        self.cursor = cursor
    }
}

public enum MouseButton: String, Codable, Sendable { case left, right, other }

public struct MouseClick: Hashable, Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case down, up }
    public var t: Double
    public var x: Double
    public var y: Double
    public var phase: Phase
    public var button: MouseButton
    public var modifiers: Modifiers

    public init(t: Double, x: Double, y: Double, phase: Phase, button: MouseButton = .left, modifiers: Modifiers = []) {
        self.t = t
        self.x = x
        self.y = y
        self.phase = phase
        self.button = button
        self.modifiers = modifiers
    }
}

public struct KeyStroke: Hashable, Codable, Sendable {
    public var t: Double
    public var keyCode: Int
    /// Characters produced, captured at record time with the active layout.
    public var characters: String
    public var charactersIgnoringModifiers: String
    public var modifiers: Modifiers
    public var isRepeat: Bool

    public init(t: Double, keyCode: Int, characters: String, charactersIgnoringModifiers: String,
                modifiers: Modifiers, isRepeat: Bool = false) {
        self.t = t
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }
}

/// Cursor image recorded while capturing.
public struct CursorImageInfo: Hashable, Codable, Sendable {
    public var id: String
    /// PNG file name within `recording/cursors/`.
    public var file: String
    public var hotSpotX: Double
    public var hotSpotY: Double
    /// Size in points.
    public var width: Double
    public var height: Double
    /// Name of a matching system cursor ("arrow", "iBeam", "pointingHand", ...), if any.
    public var systemMatch: String?

    public init(id: String, file: String, hotSpotX: Double, hotSpotY: Double, width: Double, height: Double,
                systemMatch: String? = nil) {
        self.id = id
        self.file = file
        self.hotSpotX = hotSpotX
        self.hotSpotY = hotSpotY
        self.width = width
        self.height = height
        self.systemMatch = systemMatch
    }
}

/// Window bounds over time, for window-mode recordings where the window moves.
public struct GeometrySample: Hashable, Codable, Sendable {
    public var t: Double
    public var rect: ScreenRect
    public init(t: Double, rect: ScreenRect) {
        self.t = t
        self.rect = rect
    }
}

public enum RecordingTargetKind: String, Codable, Sendable { case display, window, area, device, imported }

public enum ChannelKind: String, Codable, Sendable { case display, camera, microphone, systemAudio }

public struct ChannelInfo: Hashable, Codable, Sendable {
    public var kind: ChannelKind
    /// Finalized file relative to `recording/` (e.g. "display.mp4").
    public var file: String
    /// Segment folder relative to `recording/`, used for crash recovery.
    public var segmentFolder: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(kind: ChannelKind, file: String, segmentFolder: String? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.kind = kind
        self.file = file
        self.segmentFolder = segmentFolder
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum RecordingStatus: String, Codable, Sendable { case recording, finished, recovered }

/// `recording/manifest.json` — what was captured and how to map coordinates.
public struct RecordingManifest: Hashable, Codable, Sendable {
    public var status: RecordingStatus = .recording
    public var target: RecordingTargetKind = .display
    public var targetName: String = ""
    /// Captured region in global screen points at the start of the recording.
    public var captureRect = ScreenRect(x: 0, y: 0, width: 1920, height: 1080)
    public var pixelScale: Double = 2
    public var refreshRate: Double = 60
    public var duration: Double = 0
    public var startUnixTime: Double = 0
    public var channels: [ChannelInfo] = []
    /// Pauses in source time (the source clock does not advance while paused).
    public var pauses: [Double] = []
    public var flags: [Double] = []

    public init() {}

    public func channel(_ kind: ChannelKind) -> ChannelInfo? { channels.first { $0.kind == kind } }
}

/// All input data loaded from a recording, ready for the motion/timeline systems.
public struct RecordingEvents: Sendable {
    public var moves: [MouseMove]
    public var clicks: [MouseClick]
    public var keys: [KeyStroke]
    public var cursors: [String: CursorImageInfo]
    public var geometry: [GeometrySample]

    public init(moves: [MouseMove] = [], clicks: [MouseClick] = [], keys: [KeyStroke] = [],
                cursors: [String: CursorImageInfo] = [:], geometry: [GeometrySample] = []) {
        self.moves = moves
        self.clicks = clicks
        self.keys = keys
        self.cursors = cursors
        self.geometry = geometry
    }

    public var downClicks: [MouseClick] { clicks.filter { $0.phase == .down } }
}

/// An annotation dropped while recording (by an agent or a demo script). `t` is source time.
public struct RecordingMark: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Show `text` as a caption from here until the next caption (or `value` seconds).
        case caption
        /// Zoom on the next click; `value` is the zoom level.
        case zoom
        /// Remove everything between a cut-start and the following cut-end.
        case cutStart = "cut-start", cutEnd = "cut-end"
        /// Speed up from here to the next `speedEnd`; `value` is the speed.
        case speedStart = "speed-start", speedEnd = "speed-end"
        /// Deliberate pause that idle-cutting must keep (`value` = seconds).
        case hold
        /// Free-form note (step boundaries, etc.); not used by the edit.
        case note
    }

    public var t: Double
    public var kind: Kind
    public var text: String?
    public var value: Double?

    public init(t: Double, kind: Kind, text: String? = nil, value: Double? = nil) {
        self.t = t
        self.kind = kind
        self.text = text
        self.value = value
    }
}
