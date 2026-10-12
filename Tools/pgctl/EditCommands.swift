import CoreGraphics
import CoreText
import Composition
import Export
import Foundation
import ImageIO
import Media
import PlaygroundCore
import Render
import Timeline
import UniformTypeIdentifiers

/// `pgctl edit` (saved edits) and `pgctl frames` (look at the result).
enum EditCommands {
    /// Edits a project and saves it, so it opens in the editor exactly as the agent left it.
    ///
    /// Times are source seconds (the original recording), or output seconds (the edited video)
    /// with `--output-time`.
    static func edit(_ args: [String]) async throws {
        guard let path = args.first else { PGCtl.usage() }
        let bundle = ProjectBundle(url: URL(fileURLWithPath: path))
        let project = try await LoadedProject.load(bundle)
        let originalMap = TimeMap(slices: project.document.scene.slices)
        let useOutput = args.contains("--output-time")

        /// Converts a user time range into source ranges (output ranges can span several clips).
        func sourceRanges(_ a: Double, _ b: Double) throws -> [SourceRange] {
            guard b > a else { throw ControlError("bad-request", "Range \(a):\(b) must end after it starts.") }
            guard useOutput else { return [SourceRange(a, b)] }
            let ranges = originalMap.sourceRanges(for: OutputRange(a, b))
            guard !ranges.isEmpty else { throw ControlError("bad-request", "\(a):\(b) is outside the video.") }
            return ranges
        }
        func numbers(_ spec: String, _ count: ClosedRange<Int>, _ flag: String) throws -> [Double] {
            let p = spec.split(separator: ":").compactMap { Double($0) }
            guard count.contains(p.count) else { throw ControlError("bad-request", "Couldn't read \(flag) \(spec).") }
            return p
        }

        var doc = try PGCtl.edited(project, stripRangeFlags(args))
        var scene = doc.scene
        var changes: [String] = []

        if args.contains("--clear-captions") { scene.captions = []; changes.append("cleared captions") }
        if args.contains("--clear-zooms") { scene.zooms = []; changes.append("cleared zooms") }

        if args.contains("--apply-marks") || PGCtl.option(args, "--cut-idle") != nil {
            let marks = args.contains("--apply-marks") ? bundle.loadMarks() : []
            let idle = PGCtl.option(args, "--cut-idle").flatMap(Double.init)
            let before = TimeMap(slices: scene.slices).duration
            scene = MarkEdits.apply(scene, marks: marks, events: project.events, duration: project.manifest.duration,
                                    options: MarkEdits.Options(cutIdleLongerThan: idle))
            if !marks.isEmpty { changes.append("applied \(marks.count) marks") }
            if idle != nil { changes.append(String(format: "cut idle time (%.1fs → %.1fs)", before, TimeMap(slices: scene.slices).duration)) }
        }

        // Cuts and speed changes (source time unless --output-time; output times are resolved against
        // the timeline as it was before this command, so several flags compose predictably).
        for spec in PGCtl.options(args, "--cut") {
            let p = try numbers(spec, 2...2, "--cut")
            for r in try sourceRanges(p[0], p[1]) { scene = try Edits.removeSource(scene, range: r) }
            changes.append("cut \(spec)")
        }
        for spec in PGCtl.options(args, "--speed") {
            let p = try numbers(spec, 3...3, "--speed")
            for r in try sourceRanges(p[0], p[1]) { scene = Edits.setSpeed(scene, source: r, speed: p[2]) }
            changes.append("speed \(spec)")
        }

        for spec in PGCtl.options(args, "--caption") {
            // from:to:text (the text may itself contain colons)
            let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let a = Double(parts[0]), let b = Double(parts[1]), !parts[2].isEmpty else {
                throw ControlError("bad-request", "--caption wants from:to:text, e.g. --caption 2:5:\"Sign up in one click\".")
            }
            let pieces = try sourceRanges(a, b)
            guard let first = pieces.first, let last = pieces.last else { continue }
            scene = Edits.addCaption(scene, source: SourceRange(first.start, last.end), text: parts[2]).0
            changes.append("caption \"\(parts[2])\"")
        }

        for spec in PGCtl.options(args, "--zoom") {
            // from:to[:level[:x,y]] — x,y (0…1) aims the zoom; otherwise it follows the cursor.
            let parts = spec.split(separator: ":").map(String.init)
            guard parts.count >= 2, let a = Double(parts[0]), let b = Double(parts[1]) else {
                throw ControlError("bad-request", "--zoom wants from:to[:level[:x,y]].")
            }
            let level = parts.count > 2 ? Double(parts[2]) ?? 2 : 2
            var target: NormPoint?
            if parts.count > 3 {
                let xy = parts[3].split(separator: ",").compactMap { Double($0) }
                guard xy.count == 2 else { throw ControlError("bad-request", "Zoom target wants x,y between 0 and 1.") }
                target = NormPoint(min(max(xy[0], 0), 1), min(max(xy[1], 0), 1))
            }
            let pieces = try sourceRanges(a, b)
            guard let first = pieces.first, let last = pieces.last else { continue }
            let r = SourceRange(first.start, last.end)
            scene.zooms.removeAll { $0.source.overlaps(r) }
            scene.zooms.append(ZoomRange(source: r, level: min(max(level, 1.1), 4), mode: target == nil ? .auto : .manual,
                                         manualTarget: target ?? .center))
            scene.zooms.sort { $0.source.start < $1.source.start }
            changes.append("zoom \(spec)")
        }

        if args.contains("--auto-zoom") { changes.append("auto-zoom") }
        if PGCtl.option(args, "--preset") != nil { changes.append("preset") }
        if PGCtl.option(args, "--aspect") != nil { changes.append("aspect") }
        doc.scene = scene
        try bundle.saveDocument(doc)

        let map = TimeMap(slices: scene.slices)
        Output.emit(["project": .string(bundle.url.path), "changes": .array(changes.map { .string($0) }),
                     "outputDuration": .number((map.duration * 100).rounded() / 100),
                     "captions": .number(Double(scene.captions.count)), "zooms": .number(Double(scene.zooms.count))]) {
            (changes.isEmpty ? "no changes" : changes.joined(separator: "\n")) + String(format: "\nsaved · %.1fs long", map.duration)
        }
    }

    /// `edited()` handles --preset/--aspect/--auto-zoom; cuts and speed are applied here (with --output-time support).
    static func stripRangeFlags(_ args: [String]) -> [String] {
        var out: [String] = []
        var skip = false
        for a in args {
            if skip { skip = false; continue }
            if a == "--cut" || a == "--speed" { skip = true; continue }
            out.append(a)
        }
        return out
    }

    /// Renders frames every N output seconds plus a contact sheet, so an agent can review the video.
    static func frames(_ args: [String]) async throws {
        guard let path = args.first else { PGCtl.usage() }
        let project = try await LoadedProject.load(ProjectBundle(url: URL(fileURLWithPath: path)))
        let doc = project.document
        let snap = project.snapshot(document: doc)
        let duration = TimeMap(slices: doc.scene.slices).duration
        let every = max(PGCtl.option(args, "--every").flatMap(Double.init) ?? max(duration / 8, 0.5), 0.1)
        let res = PGCtl.option(args, "--res").flatMap(Int.init) ?? 540
        let out = URL(fileURLWithPath: PGCtl.option(args, "--out") ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("pgctl-frames-\(UUID().uuidString.prefix(6))").path)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        guard let ctx = MetalContext.shared else { throw RenderError.noDevice }
        let comp = Compositor(context: ctx)
        comp.setCursorSource(folder: project.bundle.cursorsFolder, infos: project.events.cursors)
        let screen = try await project.displayURL.map { try await VideoFrameSource(url: $0) }
        let camera = try await project.cameraURL.map { try await VideoFrameSource(url: $0) }
        let size = snap.canvasSize(shortSide: res)

        var times: [Double] = []
        var t = min(0.2, duration / 2)
        while t < duration { times.append(t); t += every }
        if times.count > 60 { throw ControlError("bad-request", "That's \(times.count) frames; use a larger --every (max 60 frames).") }

        var images: [(Double, CGImage, URL)] = []
        for t in times {
            let frame = SceneEvaluator.evaluate(snap, at: OutputTime(t), width: size.width, height: size.height)
            guard let img = comp.renderImage(frame, screen: screen?.frame(at: frame.sourceTime.seconds),
                                             camera: camera?.frame(at: frame.sourceTime.seconds), cursorSet: doc.config.cursor.set)
            else { continue }
            let file = out.appendingPathComponent(String(format: "frame-%06.2f.png", t))
            ImageIOHelpers.writePNG(img, to: file)
            images.append((t, img, file))
        }
        let sheet = out.appendingPathComponent("contact-sheet.jpg")
        writeContactSheet(images.map { ($0.0, $0.1) }, to: sheet)
        Output.emit(["folder": .string(out.path), "contactSheet": .string(sheet.path),
                     "frames": .array(images.map { ["t": .number(($0.0 * 100).rounded() / 100), "image": .string($0.2.path)] })]) {
            "\(images.count) frames in \(out.path)\ncontact sheet: \(sheet.path)"
        }
    }

    /// A grid of frames with timestamps (4 columns, 480 px wide cells).
    static func writeContactSheet(_ frames: [(Double, CGImage)], to url: URL) {
        guard let first = frames.first?.1 else { return }
        let cols = min(4, frames.count), rows = (frames.count + cols - 1) / cols
        let cellW = 480.0, cellH = cellW * Double(first.height) / Double(first.width), label = 22.0, gap = 8.0
        let W = Double(cols) * (cellW + gap) + gap, H = Double(rows) * (cellH + label + gap) + gap
        guard let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        for (i, (t, img)) in frames.enumerated() {
            let c = i % cols, r = i / cols
            let x = gap + Double(c) * (cellW + gap)
            let yTop = gap + Double(r) * (cellH + label + gap)
            let y = H - yTop - label - cellH
            ctx.draw(img, in: CGRect(x: x, y: y, width: cellW, height: cellH))
            let text = NSAttributedString(string: String(format: "%.1fs", t), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateUIFontForLanguage(.system, 14, nil)!,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1),
            ])
            ctx.textPosition = CGPoint(x: x + 2, y: y + cellH + 5)
            CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
