import Composition
import Foundation

public enum ExportFormat: String, Codable, Sendable, CaseIterable {
    case mp4, gif, prores

    public var fileExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .gif: return "gif"
        case .prores: return "mov"
        }
    }

    public var label: String {
        switch self {
        case .mp4: return "MP4"
        case .gif: return "GIF"
        case .prores: return "ProRes"
        }
    }
}

public enum ExportQuality: String, Codable, Sendable, CaseIterable {
    case studio, social, web, webLow

    public var label: String {
        switch self {
        case .studio: return "Studio"
        case .social: return "Social Media"
        case .web: return "Web"
        case .webLow: return "Web (Low)"
        }
    }

    /// Bits per pixel per frame for H.264/HEVC.
    public var bitsPerPixel: Double {
        switch self {
        case .studio: return 0.25
        case .social: return 0.12
        case .web: return 0.07
        case .webLow: return 0.04
        }
    }
}

public enum VideoCodec: String, Codable, Sendable, CaseIterable { case h264, hevc }

public struct ExportSettings: Codable, Sendable, Hashable {
    public var format: ExportFormat = .mp4
    public var resolution: ResolutionPreset = .p1080
    public var fps: Int = 60
    public var quality: ExportQuality = .social
    public var codec: VideoCodec = .h264
    public var gifLoopCount: Int = 0
    public var gifMaxWidth: Int = 960

    public init() {}

    /// GIFs are capped at 30 fps and 1080p.
    public var effectiveFPS: Int { format == .gif ? min(fps, 30) : fps }

    public static let gifDefault: ExportSettings = {
        var s = ExportSettings()
        s.format = .gif
        s.fps = 24
        s.resolution = .p720
        return s
    }()
}

public struct ExportProgress: Sendable {
    public var fraction: Double
    public var framesDone: Int
    public var framesTotal: Int
}

public enum ExportError: Error, LocalizedError {
    case noVideo
    case writerFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noVideo: return "The recording has no video."
        case let .writerFailed(msg): return "Export failed: \(msg)"
        case .cancelled: return "Export was cancelled."
        }
    }
}
