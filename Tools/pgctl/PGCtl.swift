import Composition
import Export
import Foundation
import Media
import PlaygroundCore
import Render
import TestSupport
import Timeline

/// Headless tool for tests and automation.
///
///   pgctl make-fixture <out.screenplayground> [--duration 6] [--clicks 1.5,2.2,4]
///   pgctl export <project.screenplayground> <out.mp4|.gif> [--res 1080] [--fps 60] [--quality social] [--aspect 9:16]
///                [--speed <from>:<to>:<speed>] [--cut <from>:<to>] [--preset <file.spgpreset>]
///   pgctl render-frame <project.screenplayground> <seconds> <out.png> [--res 1080]
///   pgctl info <project.screenplayground>
@main
struct PGCtl {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { usage() }
        args.removeFirst()
        do {
            switch command {
            case "make-fixture": try await makeFixture(args)
            case "export": try await export(args)
            case "render-frame": try await renderFrame(args)
            case "info": try await info(args)
            default: usage()
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func usage() -> Never {
        print("""
        usage:
          pgctl make-fixture <out.screenplayground> [--duration 6] [--clicks 1.5,2.2,4]
          pgctl export <project> <out.mp4|.gif|.mov> [--res 1080] [--fps 60] [--quality studio|social|web|webLow]
                       [--aspect auto|16:9|9:16|1:1|4:3|3:4|4:5] [--cut from:to] [--speed from:to:x] [--auto-zoom] [--preset file]
          pgctl render-frame <project> <seconds> <out.png> [--res 1080]
          pgctl info <project>
        """)
        exit(2)
    }

    static func option(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func options(_ args: [String], _ name: String) -> [String] {
        args.indices.filter { args[$0] == name && $0 + 1 < args.count }.map { args[$0 + 1] }
    }

    static func makeFixture(_ args: [String]) async throws {
        guard let path = args.first else { usage() }
        var opts = FixtureFactory.Options()
        if let d = option(args, "--duration").flatMap(Double.init) { opts.duration = d }
        if let c = option(args, "--clicks") { opts.clickTimes = c.split(separator: ",").compactMap { Double($0) } }
        let bundle = try await FixtureFactory.makeProject(at: URL(fileURLWithPath: path), options: opts)
        print(bundle.url.path)
    }

    /// Applies command-line edits (aspect, cuts, speed, preset) to a document.
    static func edited(_ project: LoadedProject, _ args: [String]) throws -> ProjectDocument {
        var doc = project.document
        if let presetPath = option(args, "--preset") {
            let data = try Data(contentsOf: URL(fileURLWithPath: presetPath))
            struct PresetFile: Codable { var config: ProjectConfig }
            doc.config = try TolerantJSON.decode(PresetFile.self, from: data, defaults: PresetFile(config: doc.config)).config
        }
        if let a = option(args, "--aspect"), let aspect = AspectRatio(rawValue: a) { doc.config.output.aspect = aspect }
        // Cuts and speed changes are expressed in source seconds.
        var scene = doc.scene
        for spec in options(args, "--cut") {
            let p = spec.split(separator: ":").compactMap { Double($0) }
            guard p.count == 2 else { continue }
            scene = try Edits.removeSource(scene, range: SourceRange(p[0], p[1]))
        }
        for spec in options(args, "--speed") {
            let p = spec.split(separator: ":").compactMap { Double($0) }
            guard p.count == 3 else { continue }
            scene = Edits.setSpeed(scene, source: SourceRange(p[0], p[1]), speed: p[2])
        }
        if args.contains("--auto-zoom") {
            let clicks = project.events.downClicks.map { AutoZoom.Click(t: $0.t, point: project.manifest.captureRect.normalize(x: $0.x, y: $0.y)) }
            scene = AutoZoom.regenerate(scene, clicks: clicks, duration: project.manifest.duration, config: doc.config.autoZoom)
        }
        doc.scene = scene
        return doc
    }

    static func export(_ args: [String]) async throws {
        guard args.count >= 2 else { usage() }
        let project = try await LoadedProject.load(ProjectBundle(url: URL(fileURLWithPath: args[0])))
        let out = URL(fileURLWithPath: args[1])
        var settings = ExportSettings()
        switch out.pathExtension.lowercased() {
        case "gif": settings = .gifDefault
        case "mov": settings.format = .prores
        default: settings.format = .mp4
        }
        if let r = option(args, "--res").flatMap(Int.init), let preset = ResolutionPreset(rawValue: r) { settings.resolution = preset }
        if let f = option(args, "--fps").flatMap(Int.init) { settings.fps = f }
        if let q = option(args, "--quality").flatMap(ExportQuality.init) { settings.quality = q }
        if option(args, "--codec") == "hevc" { settings.codec = .hevc }
        let doc = try edited(project, args)
        let start = Date()
        try await Exporter(project: project, document: doc, settings: settings).run(to: out) { p in
            if p.framesDone % 60 == 0 || p.fraction >= 1 {
                FileHandle.standardError.write(Data("\r\(Int(p.fraction * 100))%".utf8))
            }
        }
        FileHandle.standardError.write(Data("\n".utf8))
        print("exported \(out.path) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
    }

    static func renderFrame(_ args: [String]) async throws {
        guard args.count >= 3, let t = Double(args[1]) else { usage() }
        let project = try await LoadedProject.load(ProjectBundle(url: URL(fileURLWithPath: args[0])))
        let doc = try edited(project, args)
        let snap = project.snapshot(document: doc)
        let res = option(args, "--res").flatMap(Int.init) ?? 1080
        let size = snap.canvasSize(shortSide: res)
        let frame = SceneEvaluator.evaluate(snap, at: OutputTime(t), width: size.width, height: size.height)
        guard let ctx = MetalContext.shared else { throw RenderError.noDevice }
        let comp = Compositor(context: ctx)
        comp.setCursorSource(folder: project.bundle.cursorsFolder, infos: project.events.cursors)
        let screen = try await project.displayURL.map { try await VideoFrameSource(url: $0) }
        let camera = try await project.cameraURL.map { try await VideoFrameSource(url: $0) }
        guard let img = comp.renderImage(frame, screen: screen?.frame(at: frame.sourceTime.seconds),
                                         camera: camera?.frame(at: frame.sourceTime.seconds), cursorSet: doc.config.cursor.set)
        else { throw ExportError.writerFailed("render failed") }
        ImageIOHelpers.writePNG(img, to: URL(fileURLWithPath: args[2]))
        print(args[2])
    }

    static func info(_ args: [String]) async throws {
        guard let path = args.first else { usage() }
        let project = try await LoadedProject.load(ProjectBundle(url: URL(fileURLWithPath: path)))
        let m = project.manifest
        print("name:      \(project.document.name)")
        print("status:    \(m.status.rawValue)   target: \(m.target.rawValue) (\(m.targetName))")
        print("duration:  \(String(format: "%.2f", m.duration))s   source: \(Int(project.sourcePixelSize.width))×\(Int(project.sourcePixelSize.height))")
        print("channels:  \(m.channels.map(\.kind.rawValue).joined(separator: ", "))")
        print("events:    \(project.events.moves.count) moves, \(project.events.downClicks.count) clicks, \(project.events.keys.count) keys, \(project.events.cursors.count) cursors")
        print("edit:      \(project.document.scene.slices.count) clips, \(project.document.scene.zooms.count) zooms, output \(String(format: "%.2f", TimeMap(slices: project.document.scene.slices).duration))s")
    }
}

extension Optional {
    func map<U>(_ transform: (Wrapped) async throws -> U) async rethrows -> U? {
        switch self {
        case let .some(v): return try await transform(v)
        case .none: return nil
        }
    }
}
