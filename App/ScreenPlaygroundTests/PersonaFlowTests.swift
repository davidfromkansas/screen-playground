@preconcurrency import AVFoundation
import Composition
import Export
import Foundation
import Media
import PlaygroundCore
import Render
@testable import Screen_Playground
import TestSupport
import Testing
import Timeline

/// End-to-end flows for three personas, driven through the same EditorModel calls the UI makes.
/// Each flow ends in a real exported file. Nothing touches the user's projects, presets or clipboard.
@MainActor
@Suite(.serialized) struct PersonaFlowTests {
    // MARK: Helpers

    static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pg-persona-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func openFixture(duration: Double = 12, clicks: [Double] = [1.5, 2.2, 4.0, 7.0, 9.5]) async throws -> EditorModel {
        var opts = FixtureFactory.Options()
        opts.duration = duration
        opts.width = 1280
        opts.height = 720
        opts.clickTimes = clicks
        opts.idleGaps = [5.0...6.0] // like a real, variable-frame-rate recording
        let bundle = try await FixtureFactory.makeProject(at: tempDir().appendingPathComponent("Persona.screenplayground"), options: opts)
        try ProjectFactory.finalize(bundle) // same post-processing as a real recording (auto zooms)
        let model = EditorModel(url: bundle.url)
        for _ in 0..<400 where model.project == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(model.project != nil, "project failed to load: \(model.loadError ?? "")")
        return model
    }

    /// Waits for the background snapshot rebuild after an edit.
    static func settle(_ model: EditorModel) async throws {
        for _ in 0..<200 {
            if let s = model.snapshot, s.document == model.doc { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static func tone(seconds: Double) throws -> URL {
        let url = tempDir().appendingPathComponent("song.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 48000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![ch][i] = 0.25 * sin(Float(i) * 2 * .pi * 330 / 48000) } }
        try file.write(from: buffer)
        return url
    }

    static func export(_ model: EditorModel, _ settings: ExportSettings, name: String) async throws -> URL {
        let out = tempDir().appendingPathComponent(name)
        try await Exporter(project: model.project!, document: model.doc, settings: settings).run(to: out)
        return out
    }

    // MARK: Leo — tutorial editor: lots of cutting, deleting the last segment, undo, manual zooms

    @Test func leoHeavyEditing() async throws {
        let model = try await Self.openFixture()
        for t in [2.0, 4.0, 6.0, 8.0, 10.0] { model.seek(t); model.splitAtPlayhead() }
        #expect(model.doc.scene.slices.count == 6)

        // Select the last segment, hold its inspector binding, delete it (this crashed before).
        let last = model.doc.scene.slices.last!.id
        model.selection = .slice(last)
        let volume = model.item(\.slices, last, \.volume, fallback: 1, "Clip volume")
        model.deleteSelection()
        #expect(model.doc.scene.slices.count == 5)
        #expect(model.selection == nil)
        #expect(volume.wrappedValue == 1)      // stale binding reads safely
        volume.wrappedValue = 0.3               // and writes are ignored
        #expect(model.doc.scene.slices.allSatisfy { $0.volume == 1 })

        // Ripple-delete right at the very end, then delete down to one segment.
        try await Self.settle(model)
        model.seek(model.duration - 0.05)
        model.rippleDeleteAtPlayhead()
        while model.doc.scene.slices.count > 1 {
            model.selection = .slice(model.doc.scene.slices.last!.id)
            model.deleteSelection()
        }
        model.selection = .slice(model.doc.scene.slices[0].id)
        model.deleteSelection()                 // the only segment can't be deleted (beep, no crash)
        #expect(model.doc.scene.slices.count == 1)

        // Undo everything back to six segments, then redo.
        while model.canUndo && model.doc.scene.slices.count < 6 { model.undo() }
        #expect(model.doc.scene.slices.count == 6)
        model.redo()
        #expect(model.doc.scene.slices.count == 5)

        // Manual zoom: aiming it jumps the preview into the settled zoom.
        try await Self.settle(model)
        model.seek(0)
        model.addZoom(at: 0.5)
        guard case let .zoom(zid)? = model.selection else { Issue.record("zoom not selected"); return }
        model.item(\.zooms, zid, \.mode, fallback: .auto, "Zoom mode").wrappedValue = .manual
        model.item(\.zooms, zid, \.manualTarget, fallback: .center, "Zoom target").wrappedValue = NormPoint(0.8, 0.2)
        let zr = TimeMap(slices: model.doc.scene.slices).outputRanges(for: model.doc.scene.zooms.first { $0.id == zid }!.source)[0]
        #expect(model.time > zr.start.seconds && model.time < zr.end.seconds)
        await model.loadZoomFrame(zid)
        #expect(model.zoomFrames[zid] != nil)

        // Zooms dragged onto each other stay side by side.
        let zooms = model.doc.scene.zooms.sorted { $0.source.start < $1.source.start }
        if zooms.count >= 2 {
            let map = TimeMap(slices: model.doc.scene.slices)
            let b = map.outputRanges(for: zooms[1].source)[0]
            model.moveZoom(zooms[1].id, outputStart: 0, outputEnd: b.duration) // try to drop it at 0, over the first
            let after = model.doc.scene.zooms.sorted { $0.source.start < $1.source.start }
            for (x, y) in zip(after, after.dropFirst()) { #expect(x.source.end <= y.source.start + 0.0001) }
        }

        // Blur mask + loupe, then a small 720p export.
        model.addMask(kind: .blur)
        model.addZoom(at: max(model.duration - 1.5, 0))
        if case let .zoom(lid)? = model.selection {
            model.item(\.zooms, lid, \.style, fallback: .classic, "Zoom style").wrappedValue = .loupe
        }
        try await Self.settle(model)
        var settings = ExportSettings()
        settings.resolution = .p720
        settings.fps = 30
        settings.quality = .webLow
        let out = try await Self.export(model, settings, name: "leo.mp4")
        let asset = AVURLAsset(url: out)
        #expect(abs(try await asset.load(.duration).seconds - model.duration) < 0.1)
    }

    // MARK: Maya — product demo: trim, speed up, background music, export

    @Test func mayaDemoWithMusic() async throws {
        let model = try await Self.openFixture()
        let song = try Self.tone(seconds: 5) // shorter than the video: must loop
        #expect(!model.doc.scene.zooms.isEmpty) // auto zooms from clicks

        // Trim the first second and the last second; speed up a slow middle part 2x.
        let id = model.doc.scene.slices[0].id
        model.edit("Trim") { try Edits.trim($0, sliceID: id, start: SourceTime(1), recordingDuration: 12) }
        model.edit("Trim") { try Edits.trim($0, sliceID: id, end: SourceTime(11), recordingDuration: 12) }
        model.update("Speed") { $0.scene = Edits.setSpeed($0.scene, source: SourceRange(5, 7), speed: 2) }
        #expect(abs(TimeMap(slices: model.doc.scene.slices).duration - 9) < 0.001)

        // Add music the way the Audio panel does, and check the *preview* mix picks it up from the current edit.
        model.update("Add music") { $0.config.audio.backgroundMusicPath = song.path }
        model.update("Music volume") { $0.config.audio.backgroundMusicVolume = 0.6 }
        let mix = try await AudioCompositionBuilder.build(document: model.doc, sources: model.project!.audioSources,
                                                          backgroundMusic: LoadedProject.backgroundMusicURL(for: model.doc))
        #expect(mix.hasAudio)
        #expect(abs(mix.composition.duration.seconds - 9) < 0.05)

        try await Self.settle(model)
        var settings = ExportSettings()
        settings.fps = 30
        let out = try await Self.export(model, settings, name: "maya.mp4")
        let asset = AVURLAsset(url: out)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(abs(try await asset.load(.duration).seconds - 9) < 0.1)

        // Removing the music in the edit removes it from the export (no stale music).
        model.update("Remove music") { $0.config.audio.backgroundMusicPath = nil }
        let silent = try await Self.export(model, settings, name: "maya-silent.mp4")
        #expect(try await AVURLAsset(url: silent).loadTracks(withMediaType: .audio).isEmpty)
    }

    // MARK: Priya — designer: styling, aspect ratios, presets, GIF

    @Test func priyaStylingFormatsPresetsGIF() async throws {
        PresetStore.folderOverride = Self.tempDir()
        defer { PresetStore.folderOverride = nil }
        let model = try await Self.openFixture(duration: 6, clicks: [2])

        model.update("Wallpaper") { $0.config.background.wallpaper = "procedural/sunset" }
        model.binding(\.config.frame.padding, "Padding").wrappedValue = 0.12
        model.binding(\.config.frame.cornerRadius, "Corners").wrappedValue = 24
        model.binding(\.config.cursor.set, "Cursor style").wrappedValue = .touch
        model.binding(\.config.cursor.size, "Cursor size").wrappedValue = 2.5
        model.binding(\.config.cursor.clickEffect, "Click effect").wrappedValue = .ripple
        model.binding(\.config.cursor.loopPosition, "Loop").wrappedValue = true

        // Aspect ratios change the canvas, not the content.
        model.binding(\.config.output.aspect, "Aspect").wrappedValue = .square
        try await Self.settle(model)
        #expect(model.snapshot!.canvasSize(shortSide: 1080) == (1080, 1080))
        model.binding(\.config.output.aspect, "Aspect").wrappedValue = .vertical
        try await Self.settle(model)
        #expect(model.snapshot!.canvasSize(shortSide: 1080) == (1080, 1920))

        // Render a styled vertical frame and make sure it's not empty.
        let snap = model.snapshot!
        let frame = SceneEvaluator.evaluate(snap, at: OutputTime(2.1), width: 540, height: 960)
        let comp = Compositor(context: MetalContext.shared!)
        let src = try await VideoFrameSource(url: model.project!.displayURL!)
        let img = comp.renderImage(frame, screen: src.frame(at: frame.sourceTime.seconds), cursorSet: .touch)
        #expect(img?.width == 540)
        #expect(!frame.clickEffects.isEmpty || !frame.cursorPoses.isEmpty)

        // Save the look as a preset, reset it, apply the preset back.
        PresetStore.save(Preset(name: "Priya Brand", config: model.doc.config))
        let saved = try #require(PresetStore.all().first { $0.name == "Priya Brand" })
        model.update("Reset") { $0.config = ProjectConfig() }
        model.update("Apply preset") { $0.config = saved.config }
        #expect(model.doc.config.background.wallpaper == "procedural/sunset")
        #expect(model.doc.config.cursor.set == .touch)

        // Square loop as GIF + MP4.
        model.binding(\.config.output.aspect, "Aspect").wrappedValue = .square
        try await Self.settle(model)
        let gif = try await Self.export(model, .gifDefault, name: "priya.gif")
        let gsrc = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(gsrc) == 6 * 24)
        var mp4 = ExportSettings()
        mp4.fps = 60
        let video = try await Self.export(model, mp4, name: "priya.mp4")
        let track = try #require(try await AVURLAsset(url: video).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 1080, height: 1080))
    }
}

@MainActor
@Suite struct UndoGranularityTests {
    /// Two separate changes to the same slider are two undo steps; one continuous drag is one.
    @Test func separateSliderChangesUndoSeparately() async throws {
        let model = try await PersonaFlowTests.openFixture(duration: 4, clicks: [])
        let padding = model.binding(\.config.frame.padding, "Padding")
        let original = model.doc.config.frame.padding
        for v in stride(from: 0.10, through: 0.14, by: 0.01) { padding.wrappedValue = v } // one drag
        #expect(abs(model.doc.config.frame.padding - 0.14) < 1e-9)
        try await Task.sleep(nanoseconds: 700_000_000)
        padding.wrappedValue = 0.2                                                       // a later, separate change
        model.undo()
        #expect(abs(model.doc.config.frame.padding - 0.14) < 1e-9)
        model.undo()
        #expect(abs(model.doc.config.frame.padding - original) < 1e-9)
    }
}
