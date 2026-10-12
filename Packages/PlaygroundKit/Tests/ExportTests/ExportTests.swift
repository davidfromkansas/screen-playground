@preconcurrency import AVFoundation
import Composition
import Foundation
import Media
import Testing
@testable import Export
@testable import PlaygroundCore
import Render
import TestSupport
import Timeline

@Suite(.serialized) struct ExportTests {
    static func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pg-export-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// Every exported frame shows exactly the source frame the time map says it should.
    @Test func barcodeMatchesTimeMap() async throws {
        let bundle = try await FixtureFactory.makeProject(at: Self.tempURL("Fixture.screenplayground"))
        var project = try await LoadedProject.load(bundle)
        var doc = project.document
        // Plain frame so the screen maps 1:1 onto the canvas.
        doc.config.frame.padding = 0
        doc.config.frame.cornerRadius = 0
        doc.config.frame.shadowIntensity = 0
        doc.config.cursor.hidden = true
        doc.config.motion.motionBlur = 0
        // [0,2) at 1x, cut [2,3), [3,6) at 2x  → 2 + 1.5 = 3.5 s
        doc.scene.slices = [Slice(source: SourceRange(0, 2)), Slice(source: SourceRange(3, 6), timeScale: 0.5)]
        project.document = doc

        var settings = ExportSettings()
        settings.fps = 30
        settings.quality = .studio
        let out = Self.tempURL("out.mp4")
        try await Exporter(project: project, settings: settings).run(to: out)

        let asset = AVURLAsset(url: out)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 1920, height: 1080))
        #expect(abs(try await asset.load(.duration).seconds - 3.5) < 0.05)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        let map = TimeMap(slices: doc.scene.slices)
        var i = 0, mismatches = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let src = map.source(at: OutputTime(Double(i) / 30))!.time.seconds
            let expected = Int((src * 30 + 1e-6).rounded(.down))
            if FixtureFactory.decodeBarcode(pb) != expected { mismatches += 1 }
            i += 1
        }
        #expect(i == 105)
        #expect(mismatches == 0)
    }

    @Test func styledExportAndGIF() async throws {
        let bundle = try await FixtureFactory.makeProject(at: Self.tempURL("Styled.screenplayground"))
        var project = try await LoadedProject.load(bundle)
        project.document.config.cursor.clickEffect = .ripple
        let clicks = project.events.downClicks.map { AutoZoom.Click(t: $0.t, point: project.manifest.captureRect.normalize(x: $0.x, y: $0.y)) }
        project.document.scene = AutoZoom.regenerate(project.document.scene, clicks: clicks, duration: project.manifest.duration,
                                                     config: project.document.config.autoZoom)
        #expect(!project.document.scene.zooms.isEmpty)

        var settings = ExportSettings()
        settings.resolution = .p720
        let mp4 = Self.tempURL("styled.mp4")
        let start = Date()
        try await Exporter(project: project, settings: settings).run(to: mp4)
        let elapsed = Date().timeIntervalSince(start)
        let attrs = try FileManager.default.attributesOfItem(atPath: mp4.path)
        #expect((attrs[.size] as? Int ?? 0) > 50_000)
        print("styled 720p60 export of 6s took \(elapsed)s → \(mp4.path)")

        let gif = Self.tempURL("styled.gif")
        try await Exporter(project: project, settings: .gifDefault).run(to: gif)
        let src = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(src) == 144)
    }

    /// Regression: export must use the edited document's music, not the project as it was loaded.
    @Test func musicFollowsEditedDocument() async throws {
        let bundle = try await FixtureFactory.makeProject(at: Self.tempURL("Music.screenplayground"))
        // A 2-second 440 Hz tone as the "song".
        let toneURL = Self.tempURL("tone.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let file = try AVAudioFile(forWriting: toneURL, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000)!
        buffer.frameLength = 96000
        for ch in 0..<2 { for i in 0..<96000 { buffer.floatChannelData![ch][i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / 48000) } }
        try file.write(from: buffer)

        var project = try await LoadedProject.load(bundle)
        project.document.config.audio.backgroundMusicPath = toneURL.path   // as loaded: has music
        var settings = ExportSettings()
        settings.resolution = .p720
        settings.fps = 30

        var withoutMusic = project.document
        withoutMusic.config.audio.backgroundMusicPath = nil                 // edit removes it
        let silent = Self.tempURL("silent.mp4")
        try await Exporter(project: project, document: withoutMusic, settings: settings).run(to: silent)
        #expect(try await AVURLAsset(url: silent).loadTracks(withMediaType: .audio).isEmpty)

        let loud = Self.tempURL("music.mp4")
        try await Exporter(project: project, document: project.document, settings: settings).run(to: loud)
        #expect(try await AVURLAsset(url: loud).loadTracks(withMediaType: .audio).count == 1)
    }
}
