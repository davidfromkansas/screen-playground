@preconcurrency import AVFoundation
import Foundation
import PlaygroundCore

/// Finds recordings that never finished (crash, power loss) and makes them editable.
/// Channel files are fragmented movies, so everything up to the last 2-second fragment survives.
public enum RecoveryScanner {
    public static func unfinishedBundles(in folder: URL) -> [ProjectBundle] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == ProjectBundle.fileExtension }.map(ProjectBundle.init).filter {
            (try? $0.loadManifest().status) == .recording
        }
    }

    /// Repairs the manifest from whatever media made it to disk. Returns false if nothing usable remains.
    public static func recover(_ bundle: ProjectBundle) async -> Bool {
        guard var manifest = try? bundle.loadManifest() else { return false }
        let files: [(ChannelKind, String)] = [(.display, "display.mov"), (.systemAudio, "system-audio.mov"),
                                              (.microphone, "microphone.mov"), (.camera, "camera.mov")]
        var channels: [ChannelInfo] = []
        var duration = 0.0
        for (kind, file) in files {
            let url = bundle.recordingFolder.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            guard let d = try? await asset.load(.duration).seconds, d > 0.1 else { continue }
            var info = ChannelInfo(kind: kind, file: file)
            if kind == .display || kind == .camera,
               let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                info.pixelWidth = Int(size.width)
                info.pixelHeight = Int(size.height)
            }
            if kind == .display { duration = d }
            channels.append(info)
        }
        guard channels.contains(where: { $0.kind == .display }) else { return false }
        manifest.channels = channels
        manifest.duration = duration
        manifest.status = .recovered
        try? bundle.saveManifest(manifest)
        return true
    }
}
