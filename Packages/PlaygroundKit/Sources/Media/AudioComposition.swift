@preconcurrency import AVFoundation
import Foundation
import PlaygroundCore
import Timeline

/// Builds an audio-only composition for the edit: every slice inserted, time-scaled for speed
/// changes, with per-slice volume. Preview plays it with AVPlayer; export reads it with
/// AVAssetReaderAudioMixOutput, so both hear exactly the same mix.
public enum AudioCompositionBuilder {
    public struct Source: Sendable {
        public var url: URL
        public var kind: ChannelKind
        public init(url: URL, kind: ChannelKind) {
            self.url = url
            self.kind = kind
        }
    }

    public struct Result: @unchecked Sendable {
        public var composition: AVMutableComposition
        public var audioMix: AVMutableAudioMix
        public var hasAudio: Bool
    }

    public static func build(document: ProjectDocument, sources: [Source], backgroundMusic: URL? = nil) async throws -> Result {
        let composition = AVMutableComposition()
        var params: [AVMutableAudioMixInputParameters] = []
        let slices = document.scene.slices
        let map = TimeMap(slices: slices)
        let cfg = document.config.audio

        for source in sources {
            let muted = (source.kind == .microphone && cfg.muteMicrophone) || (source.kind == .systemAudio && cfg.muteSystemAudio)
            if muted { continue }
            let asset = AVURLAsset(url: source.url)
            guard let srcTrack = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let srcDuration = try await asset.load(.duration)
            let p = AVMutableAudioMixInputParameters(track: track)
            p.audioTimePitchAlgorithm = .spectral

            var cursor = CMTime.zero
            for (i, s) in slices.enumerated() {
                let outDur = CMTime(seconds: s.outputDuration, preferredTimescale: 48000)
                let outStart = CMTime(seconds: map.outputStarts[i], preferredTimescale: 48000)
                let volume = Float((source.kind == .systemAudio ? s.systemAudioVolume : s.volume) * cfg.masterVolume)
                p.setVolume(volume, at: outStart)
                if s.freezeDuration != nil {
                    cursor = CMTimeAdd(outStart, outDur)
                    continue
                }
                let start = CMTime(seconds: s.source.start.seconds, preferredTimescale: 48000)
                var dur = CMTime(seconds: s.source.duration, preferredTimescale: 48000)
                if CMTimeCompare(CMTimeAdd(start, dur), srcDuration) > 0 { dur = CMTimeSubtract(srcDuration, start) }
                guard dur.seconds > 0.001 else { continue }
                // Leave a gap if the previous slice was a freeze.
                if CMTimeCompare(cursor, outStart) < 0 { cursor = outStart }
                try track.insertTimeRange(CMTimeRange(start: start, duration: dur), of: srcTrack, at: cursor)
                let scaled = CMTime(seconds: dur.seconds * s.timeScale, preferredTimescale: 48000)
                if abs(s.timeScale - 1) > 0.0001 {
                    track.scaleTimeRange(CMTimeRange(start: cursor, duration: dur), toDuration: scaled)
                }
                cursor = CMTimeAdd(cursor, scaled)
            }
            params.append(p)
        }

        // Background music, looped to the edit length.
        if let music = backgroundMusic, map.duration > 0 {
            let asset = AVURLAsset(url: music)
            if let srcTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let musicDur = try await asset.load(.duration).seconds
                var at = 0.0
                while at < map.duration, musicDur > 0.5 {
                    let len = min(musicDur, map.duration - at)
                    try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: len, preferredTimescale: 48000)),
                                              of: srcTrack, at: CMTime(seconds: at, preferredTimescale: 48000))
                    at += len
                }
                let p = AVMutableAudioMixInputParameters(track: track)
                p.setVolume(Float(cfg.backgroundMusicVolume), at: .zero)
                // Fade out over the last second.
                let fadeStart = max(0, map.duration - 1)
                p.setVolumeRamp(fromStartVolume: Float(cfg.backgroundMusicVolume), toEndVolume: 0,
                                timeRange: CMTimeRange(start: CMTime(seconds: fadeStart, preferredTimescale: 600),
                                                       duration: CMTime(seconds: map.duration - fadeStart, preferredTimescale: 600)))
                params.append(p)
            }
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return Result(composition: composition, audioMix: mix, hasAudio: !params.isEmpty)
    }
}
