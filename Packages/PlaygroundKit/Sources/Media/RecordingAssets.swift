@preconcurrency import AVFoundation
import Composition
import Foundation
import PlaygroundCore

/// Everything loaded from a project bundle that rendering needs.
public struct LoadedProject: Sendable {
    public var bundle: ProjectBundle
    public var document: ProjectDocument
    public var manifest: RecordingManifest
    public var events: RecordingEvents
    public var displayURL: URL?
    public var cameraURL: URL?
    public var audioSources: [AudioCompositionBuilder.Source]
    public var sourcePixelSize: CGSize
    public var cameraAspect: Double

    public static func load(_ bundle: ProjectBundle) async throws -> LoadedProject {
        let document = try bundle.loadDocument()
        let manifest = try bundle.loadManifest()
        let events = bundle.loadEvents()
        let display = manifest.channel(.display).map { bundle.channelURL($0) }
        let camera = manifest.channel(.camera).map { bundle.channelURL($0) }
        var audio: [AudioCompositionBuilder.Source] = []
        for kind in [ChannelKind.microphone, .systemAudio] {
            if let ch = manifest.channel(kind) { audio.append(.init(url: bundle.channelURL(ch), kind: kind)) }
        }
        // The display file may also carry an audio track (imported videos).
        if manifest.target == .imported, let display { audio.append(.init(url: display, kind: .systemAudio)) }

        var size = CGSize(width: Double(manifest.channel(.display)?.pixelWidth ?? 0), height: Double(manifest.channel(.display)?.pixelHeight ?? 0))
        if size.width == 0, let display, let track = try await AVURLAsset(url: display).loadTracks(withMediaType: .video).first {
            size = try await track.load(.naturalSize)
        }
        var camAspect = 16.0 / 9
        if let camera, let track = try await AVURLAsset(url: camera).loadTracks(withMediaType: .video).first {
            let s = try await track.load(.naturalSize)
            if s.height > 0 { camAspect = s.width / s.height }
        }
        return LoadedProject(bundle: bundle, document: document, manifest: manifest, events: events, displayURL: display,
                             cameraURL: camera, audioSources: audio, sourcePixelSize: size, cameraAspect: camAspect)
    }

    public func snapshot(document: ProjectDocument? = nil) -> RenderSnapshot {
        RenderSnapshot(document: document ?? self.document, manifest: manifest, events: events,
                       sourcePixelWidth: Double(sourcePixelSize.width), sourcePixelHeight: Double(sourcePixelSize.height),
                       hasCamera: cameraURL != nil, cameraAspect: cameraAspect)
    }

    public var backgroundMusicURL: URL? {
        guard let path = document.config.audio.backgroundMusicPath else { return nil }
        return URL(fileURLWithPath: path)
    }
}
