import Composition
import PlaygroundCore
import SwiftUI
import Timeline

/// Stacked semantic tracks: clips (yellow), zooms (purple), masks (teal), with a playhead.
struct TimelineView: View {
    @Bindable var model: EditorModel

    static let rulerH: CGFloat = 24
    static let clipY: CGFloat = 30
    static let clipH: CGFloat = 54
    static let zoomY: CGFloat = 92
    static let zoomH: CGFloat = 34
    static let maskY: CGFloat = 134
    static let maskH: CGFloat = 26
    static let captionY: CGFloat = 166
    static let captionH: CGFloat = 26
    static let totalH: CGFloat = 198
    static let inset: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let map = TimeMap(slices: model.doc.scene.slices)
            let duration = max(map.duration, 0.1)
            let pps = max((geo.size.width - 2 * Self.inset) / duration, 1) * model.timelineZoom
            let contentW = duration * pps + 2 * Self.inset
            ScrollView(.horizontal, showsIndicators: model.timelineZoom > 1.01) {
                ZStack(alignment: .topLeading) {
                    RulerView(duration: duration, pps: pps)
                        .frame(width: contentW, height: Self.rulerH)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in model.seek((v.location.x - Self.inset) / pps) })
                    trackBackground(y: Self.clipY, h: Self.clipH, width: contentW)
                    trackBackground(y: Self.zoomY, h: Self.zoomH, width: contentW)
                        .gesture(SpatialTapGesture(coordinateSpace: .named("timeline")).onEnded { v in
                            model.addZoom(at: (v.location.x - Self.inset) / pps)
                        })
                    trackBackground(y: Self.maskY, h: Self.maskH, width: contentW)
                        .gesture(SpatialTapGesture(coordinateSpace: .named("timeline")).onEnded { v in
                            model.addMask(at: (v.location.x - Self.inset) / pps)
                        })
                    if model.doc.scene.zooms.isEmpty {
                        hint("Click to add a zoom", y: Self.zoomY, h: Self.zoomH)
                    }
                    trackBackground(y: Self.captionY, h: Self.captionH, width: contentW)
                        .gesture(SpatialTapGesture(coordinateSpace: .named("timeline")).onEnded { v in
                            model.addCaption(at: (v.location.x - Self.inset) / pps)
                        })
                    if model.doc.scene.masks.isEmpty {
                        hint("Click to add a mask or highlight", y: Self.maskY, h: Self.maskH)
                    }
                    if model.doc.scene.captions.isEmpty {
                        hint("Click to add a caption", y: Self.captionY, h: Self.captionH)
                    }
                    clips(map: map, pps: pps)
                    zooms(map: map, pps: pps)
                    masks(map: map, pps: pps)
                    captions(map: map, pps: pps)
                    Playhead(height: Self.totalH)
                        .offset(x: Self.inset + model.time * pps - Playhead.hitWidth / 2)
                        .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in
                            model.seek((v.location.x - Self.inset) / pps)
                        })
                }
                .coordinateSpace(.named("timeline"))
                .frame(width: contentW, height: Self.totalH, alignment: .topLeading)
            }
            .scrollDisabled(model.timelineZoom <= 1.01)
            .onScrollWheelZoom { delta in
                model.timelineZoom = min(max(model.timelineZoom * (1 + delta), 1), 60)
            }
        }
        .frame(height: Self.totalH)
    }

    func trackBackground(y: CGFloat, h: CGFloat, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.control)
            .frame(width: width - 2 * Self.inset + 8, height: h)
            .offset(x: Self.inset - 4, y: y)
    }

    func hint(_ text: String, y: CGFloat, h: CGFloat) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: h)
            .offset(y: y)
            .allowsHitTesting(false)
    }

    // MARK: Clips

    @ViewBuilder func clips(map: TimeMap, pps: Double) -> some View {
        ForEach(Array(map.slices.enumerated()), id: \.element.id) { i, slice in
            let x = Self.inset + map.outputStarts[i] * pps
            let w = max(slice.outputDuration * pps, ClipBlock.gap + 3)
            ClipBlock(model: model, slice: slice, width: w, pps: pps)
                .frame(width: w, height: Self.clipH)
                .offset(x: x, y: Self.clipY)
        }
    }

    // MARK: Zooms

    @ViewBuilder func zooms(map: TimeMap, pps: Double) -> some View {
        ForEach(model.doc.scene.zooms) { zoom in
            let ranges = map.outputRanges(for: zoom.source)
            if let first = ranges.first, let last = ranges.last {
                let x = Self.inset + first.start.seconds * pps
                let w = max((last.end.seconds - first.start.seconds) * pps, 14)
                RangeBlock(model: model, kind: .zoom(zoom.id), color: Theme.zoom, disabled: zoom.disabled,
                           title: "Zoom", subtitle: "\(String(format: "%.1f", zoom.level))× · \(zoom.mode == .auto ? "Auto" : "Manual")\(zoom.style == .loupe ? " · Loupe" : "")",
                           icon: "plus.magnifyingglass", outputStart: first.start.seconds, outputEnd: last.end.seconds, pps: pps) { start0, end0 in
                    model.moveZoom(zoom.id, outputStart: start0, outputEnd: end0)
                }
                .contextMenu {
                    Button(zoom.disabled ? "Enable" : "Disable") { model.update("Toggle zoom") { d in
                        if let i = d.scene.zooms.firstIndex(where: { $0.id == zoom.id }) { d.scene.zooms[i].disabled.toggle() }
                    } }
                    Button("Duplicate") { model.update("Duplicate zoom") { d in
                        var copy = zoom
                        copy.id = makeItemID()
                        let len = zoom.source.duration
                        copy.source = SourceRange(zoom.source.end + 0.2, zoom.source.end + 0.2 + len)
                        if copy.source.end.seconds <= model.recordingDuration { d.scene.zooms.append(copy) }
                    } }
                    Divider()
                    Button("Remove", role: .destructive) { model.update("Remove zoom") { $0.scene = Edits.removeZoom($0.scene, id: zoom.id) } }
                }
                .frame(width: w, height: Self.zoomH)
                .offset(x: x, y: Self.zoomY)
            }
        }
    }

    // MARK: Masks

    @ViewBuilder func masks(map: TimeMap, pps: Double) -> some View {
        ForEach(model.doc.scene.masks) { mask in
            let ranges = map.outputRanges(for: mask.source)
            if let first = ranges.first, let last = ranges.last {
                let x = Self.inset + first.start.seconds * pps
                let w = max((last.end.seconds - first.start.seconds) * pps, 14)
                RangeBlock(model: model, kind: .mask(mask.id), color: Theme.mask, disabled: false,
                           title: mask.kind == .highlight ? "Highlight" : "Mask", subtitle: mask.kind.rawValue.capitalized,
                           icon: mask.kind == .highlight ? "rectangle.inset.filled" : "eye.slash",
                           outputStart: first.start.seconds, outputEnd: last.end.seconds, pps: pps) { start, end in
                    model.update("Move mask", coalesce: true) { doc in
                        guard let i = doc.scene.masks.firstIndex(where: { $0.id == mask.id }),
                              let s = map.source(at: OutputTime(start))?.time, let e = map.source(at: OutputTime(end))?.time,
                              e.seconds - s.seconds >= 0.1 else { return }
                        doc.scene.masks[i].source = SourceRange(s, e)
                    }
                }
                .contextMenu {
                    Button("Remove", role: .destructive) { model.update("Remove mask") { $0.scene.masks.removeAll { $0.id == mask.id } } }
                }
                .frame(width: w, height: Self.maskH)
                .offset(x: x, y: Self.maskY)
            }
        }
    }
}

extension TimelineView {
    // MARK: Captions

    @ViewBuilder func captions(map: TimeMap, pps: Double) -> some View {
        ForEach(model.doc.scene.captions) { caption in
            let ranges = map.outputRanges(for: caption.source)
            if let first = ranges.first, let last = ranges.last {
                let x = Self.inset + first.start.seconds * pps
                let w = max((last.end.seconds - first.start.seconds) * pps, 14)
                RangeBlock(model: model, kind: .caption(caption.id), color: Theme.caption, disabled: false,
                           title: "Caption", subtitle: caption.text, icon: "captions.bubble",
                           outputStart: first.start.seconds, outputEnd: last.end.seconds, pps: pps) { start, end in
                    model.update("Move caption", coalesce: true) { doc in
                        guard let i = doc.scene.captions.firstIndex(where: { $0.id == caption.id }),
                              let s = map.source(at: OutputTime(start))?.time, let e = map.source(at: OutputTime(end))?.time,
                              e.seconds - s.seconds >= 0.3 else { return }
                        doc.scene.captions[i].source = SourceRange(s, e)
                    }
                }
                .contextMenu {
                    Button("Remove", role: .destructive) { model.update("Remove caption") { $0.scene = Edits.removeCaption($0.scene, id: caption.id) } }
                }
                .frame(width: w, height: Self.captionH)
                .offset(x: x, y: Self.captionY)
            }
        }
    }
}

// MARK: - Clip block

struct ClipBlock: View {
    var model: EditorModel
    var slice: Slice
    var width: Double
    var pps: Double
    @State private var dragBase: Slice?

    @State private var hovering = false

    var selected: Bool { model.selection == .slice(slice.id) }
    /// Visual gap between neighbouring segments so they never read as one bar.
    static let gap: CGFloat = 3

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(slice.speed == 1 ? Theme.clip : Theme.clipFast)
                .brightness(hovering ? 0.05 : 0)
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(selected ? Theme.text : .clear, lineWidth: 2))
            label
                .foregroundStyle(Theme.clipText)
                .lineLimit(1)
                .padding(.horizontal, 10)
            if hovering || selected {
                HStack(spacing: 0) {
                    edge(leading: true)
                    Spacer(minLength: 0)
                    edge(leading: false)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Self.gap / 2)
        .contentShape(Rectangle())
        .animation(Anim.hover, value: hovering)
        .onHover { hovering = $0 }
        .gesture(SpatialTapGesture(coordinateSpace: .named("timeline")).onEnded { v in
            model.selection = .slice(slice.id)
            model.seek((v.location.x - TimelineView.inset) / pps)
        })
        .contextMenu { sliceMenu }
        .help("\(durationLabel(slice.outputDuration)) · \(speedLabel(slice.speed)) — right-click for speed, volume and more")
    }

    /// Shows as much as fits: full label, then duration + speed, then speed only.
    @ViewBuilder var label: some View {
        let flags = HStack(spacing: 4) {
            if slice.hideCursor { Image(systemName: "cursorarrow.slash") }
            if slice.volume != 1 { Image(systemName: slice.volume == 0 ? "speaker.slash" : "speaker.wave.1") }
        }
        if width > 120 {
            VStack(spacing: 1) {
                Text("Clip").font(.system(size: 10, weight: .medium)).opacity(0.7)
                HStack(spacing: 6) {
                    Text(durationLabel(slice.outputDuration))
                    Label(speedLabel(slice.speed), systemImage: "timer").labelStyle(.titleAndIcon)
                    flags
                }
                .font(.system(size: 11, weight: .semibold))
            }
        } else if width > 64 {
            HStack(spacing: 4) {
                Text(durationLabel(slice.outputDuration))
                if slice.speed != 1 { Text(speedLabel(slice.speed)) }
            }
            .font(.system(size: 11, weight: .semibold))
        } else if width > 30, slice.speed != 1 {
            Text(speedLabel(slice.speed)).font(.system(size: 10, weight: .bold))
        }
    }

    func edge(leading: Bool) -> some View {
        Rectangle().fill(Color.black.opacity(0.001)).frame(width: min(10, max(width / 4, 4)))
            .overlay(Capsule().fill(Theme.clipText.opacity(0.45)).frame(width: 4, height: 20))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                let base = dragBase ?? slice
                if dragBase == nil { dragBase = slice }
                let deltaSource = v.translation.width / pps / base.timeScale
                model.edit("Trim", coalesce: true) { scene in
                    try Edits.trim(scene, sliceID: slice.id,
                                   start: leading ? base.source.start + deltaSource : nil,
                                   end: leading ? nil : base.source.end + deltaSource,
                                   recordingDuration: model.recordingDuration)
                }
            }.onEnded { _ in dragBase = nil })
    }

    @ViewBuilder var sliceMenu: some View {
        Menu("Speed") {
            ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 8], id: \.self) { s in
                Button { model.update("Speed") { $0.scene = Edits.setSpeed($0.scene, sliceID: slice.id, speed: s) } } label: {
                    if abs(slice.speed - s) < 0.001 { Label(speedLabel(s), systemImage: "checkmark") } else { Text(speedLabel(s)) }
                }
            }
            Divider()
            Button("Apply \(speedLabel(slice.speed)) to all clips") {
                model.update("Speed all") { $0.scene = Edits.setSpeed($0.scene, sliceID: nil, speed: slice.speed) }
            }
        }
        Menu("Volume") {
            ForEach([0, 0.25, 0.5, 0.75, 1, 1.5, 2], id: \.self) { v in
                Button {
                    model.edit("Volume") { try Edits.updateSlice($0, sliceID: slice.id) { $0.volume = v; $0.systemAudioVolume = v } }
                } label: {
                    let title = v == 0 ? "Mute" : "\(Int(v * 100))%"
                    if abs(slice.volume - v) < 0.001 { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        }
        Toggle("Hide cursor", isOn: Binding(get: { slice.hideCursor }, set: { v in
            model.edit("Hide cursor") { try Edits.updateSlice($0, sliceID: slice.id) { $0.hideCursor = v } }
        }))
        Toggle("Disable smooth cursor movement", isOn: Binding(get: { slice.disableSmoothing }, set: { v in
            model.edit("Smooth movement") { try Edits.updateSlice($0, sliceID: slice.id) { $0.disableSmoothing = v } }
        }))
        Divider()
        Button("Split at playhead  (C)") { model.splitAtPlayhead() }
        Button("Remove clip", role: .destructive) { model.edit("Delete clip") { try Edits.remove($0, sliceID: slice.id) } }
        Button("Reset all trims and cuts") {
            model.update("Reset cuts") { $0.scene = Edits.resetCuts($0.scene, recordingDuration: model.recordingDuration) }
        }
    }
}

func speedLabel(_ s: Double) -> String {
    s == s.rounded() ? "\(Int(s))×" : String(format: "%g×", s)
}

func durationLabel(_ d: Double) -> String {
    d < 60 ? String(format: "%.0fs", d.rounded()) : String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
}

func timecode(_ t: Double) -> String {
    let cs = Int((t * 100).rounded())
    return String(format: "%d:%02d.%02d", cs / 6000, (cs / 100) % 60, cs % 100)
}

// MARK: - Range block (zooms, masks)

struct RangeBlock: View {
    var model: EditorModel
    var kind: EditorSelection
    var color: Color
    var disabled: Bool
    var title: String
    var subtitle: String
    var icon: String
    var outputStart: Double
    var outputEnd: Double
    var pps: Double
    var onChange: (Double, Double) -> Void
    @State private var base: (Double, Double)?
    @State private var hovering = false

    var body: some View {
        let selected = model.selection == kind
        let width = (outputEnd - outputStart) * pps
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(color.opacity(disabled ? 0.3 : 1))
                .brightness(hovering ? 0.05 : 0)
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(selected ? Theme.text : .clear, lineWidth: 2))
            if width > 90 {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                    Text(subtitle).lineLimit(1)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(disabled ? Theme.text.opacity(0.6) : .white)
                .padding(.horizontal, 10)
            } else if width > 26 {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(disabled ? Theme.text.opacity(0.6) : .white)
            }
            if hovering || selected {
                HStack(spacing: 0) {
                    handle(leading: true, width: width)
                    Spacer(minLength: 0)
                    handle(leading: false, width: width)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, ClipBlock.gap / 2)
        .contentShape(Rectangle())
        .animation(Anim.hover, value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { model.selection = kind }
        .help("\(title) · \(subtitle)")
        .gesture(DragGesture(minimumDistance: 3).onChanged { v in
            let b = base ?? (outputStart, outputEnd)
            if base == nil { base = b }
            let d = v.translation.width / pps
            let len = b.1 - b.0
            let s = min(max(b.0 + d, 0), max(model.duration - len, 0))
            model.selection = kind
            onChange(s, s + len)
        }.onEnded { _ in base = nil })
    }

    func handle(leading: Bool, width: Double) -> some View {
        Rectangle().fill(Color.black.opacity(0.001)).frame(width: min(10, max(width / 4, 4)))
            .overlay(Capsule().fill(Color.white.opacity(0.6)).frame(width: 3, height: 14))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                let b = base ?? (outputStart, outputEnd)
                if base == nil { base = b }
                let d = v.translation.width / pps
                if leading { onChange(min(max(b.0 + d, 0), b.1 - 0.1), b.1) } else { onChange(b.0, max(min(b.1 + d, model.duration), b.0 + 0.1)) }
            }.onEnded { _ in base = nil })
    }
}

// MARK: - Ruler & playhead

struct RulerView: View {
    var duration: Double
    var pps: Double

    var body: some View {
        Canvas { ctx, size in
            // Labels on round times (major), with evenly spaced minor ticks between them.
            let (major, minor) = Self.steps(pps: pps)
            let count = Int((duration / minor).rounded(.down))
            let perMajor = max(Int((major / minor).rounded()), 1)
            for i in 0...max(count, 0) {
                let t = Double(i) * minor
                let x = TimelineView.inset + t * pps
                let isMajor = i % perMajor == 0
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height - (isMajor ? 9 : 5)))
                p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(Theme.text.opacity(isMajor ? 0.35 : 0.15)), lineWidth: 1)
                if isMajor {
                    let label = major < 1 ? String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
                        : String(format: "%d:%02d", Int(t.rounded()) / 60, Int(t.rounded()) % 60)
                    ctx.draw(Text(label).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.secondaryText),
                             at: CGPoint(x: x, y: 7))
                }
            }
        }
    }

    /// Major (labelled) step is a round number at least ~70 px apart; minor ticks subdivide it.
    static func steps(pps: Double) -> (major: Double, minor: Double) {
        let options: [(Double, Double)] = [(0.5, 0.1), (1, 0.2), (2, 0.5), (5, 1), (10, 2), (15, 5), (30, 5), (60, 10), (120, 30), (300, 60)]
        for (major, minor) in options where major * pps >= 70 { return (major, minor) }
        return (600, 120)
    }
}

struct Playhead: View {
    static let hitWidth: CGFloat = 18
    var height: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            Circle().fill(Theme.accent).frame(width: 13, height: 13).overlay(Circle().stroke(Color.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            Rectangle().fill(Theme.accent).frame(width: 2)
        }
        .frame(width: Self.hitWidth, height: height)
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }
}

// MARK: - ⌘/pinch zoom for the timeline

extension View {
    func onScrollWheelZoom(_ action: @escaping (Double) -> Void) -> some View {
        background(ScrollZoomCatcher(action: action))
    }
}

private struct ScrollZoomCatcher: NSViewRepresentable {
    var action: (Double) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = CatcherView()
        v.action = action
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? CatcherView)?.action = action }

    final class CatcherView: NSView {
        var action: ((Double) -> Void)?
        private var monitors: [Any] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            guard window != nil else { return }
            let scroll = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
                guard let self, let w = self.window, e.window == w else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                if e.type == .magnify { self.action?(e.magnification); return nil }
                if e.modifierFlags.contains(.command) { self.action?(-e.scrollingDeltaY * 0.01); return nil }
                return e
            }
            if let scroll { monitors.append(scroll) }
        }
    }
}
