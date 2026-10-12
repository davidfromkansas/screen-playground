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
    static let totalH: CGFloat = 168
    static let inset: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let duration = max(model.duration, 0.1)
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
                        .onTapGesture { p in model.addZoom(at: (p.x - Self.inset) / pps) }
                    trackBackground(y: Self.maskY, h: Self.maskH, width: contentW)
                        .onTapGesture { p in model.addMask(at: (p.x - Self.inset) / pps) }
                    if model.doc.scene.zooms.isEmpty {
                        hint("Click to add a zoom", y: Self.zoomY, h: Self.zoomH)
                    }
                    if model.doc.scene.masks.isEmpty {
                        hint("Click to add a mask or highlight", y: Self.maskY, h: Self.maskH)
                    }
                    if let snap = model.snapshot {
                        clips(snap: snap, pps: pps)
                        zooms(snap: snap, pps: pps)
                        masks(snap: snap, pps: pps)
                    }
                    Playhead(height: Self.totalH)
                        .offset(x: Self.inset + model.time * pps - 6)
                        .gesture(DragGesture().onChanged { v in
                            model.seek((v.location.x + model.time * pps - 6 - Self.inset + 6) / pps)
                        })
                }
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
        RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03))
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

    @ViewBuilder func clips(snap: RenderSnapshot, pps: Double) -> some View {
        let map = snap.timeMap
        ForEach(Array(map.slices.enumerated()), id: \.element.id) { i, slice in
            let x = Self.inset + map.outputStarts[i] * pps
            let w = max(slice.outputDuration * pps, 4)
            ClipBlock(model: model, slice: slice, width: w, pps: pps)
                .frame(width: w, height: Self.clipH)
                .offset(x: x, y: Self.clipY)
        }
    }

    // MARK: Zooms

    @ViewBuilder func zooms(snap: RenderSnapshot, pps: Double) -> some View {
        ForEach(model.doc.scene.zooms) { zoom in
            let ranges = snap.timeMap.outputRanges(for: zoom.source)
            if let first = ranges.first, let last = ranges.last {
                let x = Self.inset + first.start.seconds * pps
                let w = max((last.end.seconds - first.start.seconds) * pps, 6)
                RangeBlock(model: model, kind: .zoom(zoom.id), color: Theme.zoom, disabled: zoom.disabled,
                           title: "Zoom", subtitle: "\(String(format: "%.1f", zoom.level))× · \(zoom.mode == .auto ? "Auto" : "Manual")\(zoom.style == .loupe ? " · Loupe" : "")",
                           icon: "plus.magnifyingglass", outputStart: first.start.seconds, outputEnd: last.end.seconds, pps: pps) { start, end in
                    model.update("Move zoom", coalesce: true) { doc in
                        guard let i = doc.scene.zooms.firstIndex(where: { $0.id == zoom.id }),
                              let s = snap.timeMap.source(at: OutputTime(start))?.time, let e = snap.timeMap.source(at: OutputTime(end))?.time,
                              e.seconds - s.seconds >= Edits.minimumZoomDuration else { return }
                        doc.scene.zooms[i].source = SourceRange(s, e)
                    }
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

    @ViewBuilder func masks(snap: RenderSnapshot, pps: Double) -> some View {
        ForEach(model.doc.scene.masks) { mask in
            let ranges = snap.timeMap.outputRanges(for: mask.source)
            if let first = ranges.first, let last = ranges.last {
                let x = Self.inset + first.start.seconds * pps
                let w = max((last.end.seconds - first.start.seconds) * pps, 6)
                RangeBlock(model: model, kind: .mask(mask.id), color: Theme.mask, disabled: false,
                           title: mask.kind == .highlight ? "Highlight" : "Mask", subtitle: mask.kind.rawValue.capitalized,
                           icon: mask.kind == .highlight ? "rectangle.inset.filled" : "eye.slash",
                           outputStart: first.start.seconds, outputEnd: last.end.seconds, pps: pps) { start, end in
                    model.update("Move mask", coalesce: true) { doc in
                        guard let i = doc.scene.masks.firstIndex(where: { $0.id == mask.id }),
                              let s = snap.timeMap.source(at: OutputTime(start))?.time, let e = snap.timeMap.source(at: OutputTime(end))?.time,
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

// MARK: - Clip block

struct ClipBlock: View {
    var model: EditorModel
    var slice: Slice
    var width: Double
    var pps: Double
    @State private var dragBase: Slice?

    var selected: Bool { model.selection == .slice(slice.id) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.clip.opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.white : .clear, lineWidth: 2))
            if width > 70 {
                VStack(spacing: 1) {
                    Text("Clip").font(.system(size: 10, weight: .medium)).opacity(0.7)
                    HStack(spacing: 6) {
                        Text(durationLabel(slice.outputDuration))
                        Label(speedLabel(slice.speed), systemImage: "timer").labelStyle(.titleAndIcon)
                        if slice.hideCursor { Image(systemName: "cursorarrow.slash") }
                        if slice.volume != 1 { Image(systemName: slice.volume == 0 ? "speaker.slash" : "speaker.wave.1") }
                    }
                    .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.black.opacity(0.8))
            }
            HStack {
                edge(leading: true)
                Spacer()
                edge(leading: false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = .slice(slice.id) }
        .contextMenu { sliceMenu }
    }

    func edge(leading: Bool) -> some View {
        Rectangle().fill(Color.black.opacity(0.001)).frame(width: 9)
            .overlay(Capsule().fill(Color.black.opacity(0.35)).frame(width: 3, height: 18))
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

    var body: some View {
        let selected = model.selection == kind
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(disabled ? 0.35 : 0.95))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.white : .clear, lineWidth: 2))
            if (outputEnd - outputStart) * pps > 60 {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                    Text(subtitle).lineLimit(1)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(disabled ? 0.5 : 0.95))
                .padding(.horizontal, 8)
            }
            HStack {
                handle(leading: true)
                Spacer()
                handle(leading: false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = kind }
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

    func handle(leading: Bool) -> some View {
        Rectangle().fill(Color.black.opacity(0.001)).frame(width: 9)
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
            let step = Self.step(pps: pps)
            var t = 0.0
            while t <= duration + 0.001 {
                let x = TimelineView.inset + t * pps
                let major = (t / step).rounded().truncatingRemainder(dividingBy: 5) == 0
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height - (major ? 9 : 5)))
                p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(major ? 0.35 : 0.18)), lineWidth: 1)
                if major {
                    let label = t < 60 ? String(format: "0:%02d", Int(t)) : String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
                    ctx.draw(Text(label).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.secondaryText),
                             at: CGPoint(x: x, y: 7))
                }
                t += step
            }
        }
    }

    static func step(pps: Double) -> Double {
        for s in [0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60] where s * pps >= 14 { return s }
        return 120
    }
}

struct Playhead: View {
    var height: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 11)).foregroundStyle(Theme.accentSoft)
            Rectangle().fill(Theme.accentSoft).frame(width: 2)
        }
        .frame(width: 12, height: height)
        .contentShape(Rectangle())
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
