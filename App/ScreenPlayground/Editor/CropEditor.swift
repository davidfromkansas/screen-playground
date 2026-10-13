import PlaygroundCore
import SwiftUI

/// Crop mode: the whole recording with a glowing frame you drag to choose what stays.
/// Corners and edges resize, dragging inside moves it, everything outside is dimmed.
struct CropEditor: View {
    @Bindable var model: EditorModel
    /// Width/height of the crop in source pixels when an aspect is locked.
    var lockedAspect: Double?

    @State private var dragStart: NormRect?
    @State private var dragging = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, body }

    static let minSize = 0.08

    var body: some View {
        GeometryReader { geo in
            let image = fittedRect(in: geo.size)
            let crop = model.cropDraft ?? .full
            let r = CGRect(x: image.minX + crop.x * image.width, y: image.minY + crop.y * image.height,
                           width: crop.width * image.width, height: crop.height * image.height)
            ZStack(alignment: .topLeading) {
                frameImage
                    .frame(width: image.width, height: image.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .offset(x: image.minX, y: image.minY)

                // Dim everything outside the crop.
                Path { p in
                    p.addRect(image)
                    p.addRect(r)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                // Rule-of-thirds grid while dragging.
                if dragging {
                    Path { p in
                        for i in 1...2 {
                            let x = r.minX + r.width * Double(i) / 3, y = r.minY + r.height * Double(i) / 3
                            p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                            p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
                    .allowsHitTesting(false)
                }

                // The glowing frame.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 3)
                    .shadow(color: Theme.accent, radius: 8)
                    .shadow(color: Theme.accent.opacity(0.7), radius: 22)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .allowsHitTesting(false)

                // Move by dragging inside.
                Rectangle().fill(Color.white.opacity(0.001))
                    .frame(width: max(r.width - 24, 1), height: max(r.height - 24, 1))
                    .offset(x: r.minX + 12, y: r.minY + 12)
                    .gesture(drag(.body, image: image))
                    .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }

                ForEach(Handle.allCases.filter { $0 != .body }, id: \.self) { h in
                    handleView(h)
                        .position(point(for: h, in: r))
                        .gesture(drag(h, image: image))
                }

                sizeLabel(crop: crop)
                    .position(x: r.midX, y: max(r.minY - 18, image.minY + 14))
                    .opacity(dragging ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .scaleEffect(appeared || reduceMotion ? 1 : 0.98)
            .opacity(appeared ? 1 : 0)
            .onAppear { withAnimation(Anim.easeOut(0.25)) { appeared = true } }
            .animation(Anim.hover, value: dragging)
        }
    }

    // MARK: Pieces

    @ViewBuilder var frameImage: some View {
        if let img = model.cropFrame {
            Image(nsImage: img).resizable().interpolation(.high)
        } else {
            ZStack {
                Color.black.opacity(0.8)
                ProgressView().controlSize(.small).tint(.white)
            }
        }
    }

    func handleView(_ h: Handle) -> some View {
        let corner = [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(h)
        let vertical = h == .left || h == .right
        return Capsule()
            .fill(Color.white)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 1.5))
            .frame(width: corner ? 16 : (vertical ? 7 : 30), height: corner ? 16 : (vertical ? 30 : 7))
            .clipShape(corner ? AnyShape(Circle()) : AnyShape(Capsule()))
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
            .accessibilityLabel("Crop handle")
            .onHover { inside in if inside { cursor(for: h).push() } else { NSCursor.pop() } }
    }

    func sizeLabel(crop: NormRect) -> some View {
        let w = Int((model.project?.sourcePixelSize.width ?? 0) * crop.width)
        let h = Int((model.project?.sourcePixelSize.height ?? 0) * crop.height)
        return Text("\(w) × \(h)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.6)))
    }

    // MARK: Geometry

    func fittedRect(in size: CGSize) -> CGRect {
        let aspect = model.sourceAspect
        var w = size.width - 8, h = w / aspect
        if h > size.height - 8 { h = size.height - 8; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    func point(for h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        case .body: CGPoint(x: r.midX, y: r.midY)
        }
    }

    func cursor(for h: Handle) -> NSCursor {
        switch h {
        case .left, .right: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        case .body: .openHand
        default: .crosshair
        }
    }

    func drag(_ h: Handle, image: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let start = dragStart ?? (model.cropDraft ?? .full)
                if dragStart == nil { dragStart = start; dragging = true }
                let dx = v.translation.width / image.width, dy = v.translation.height / image.height
                model.cropDraft = Self.resize(start, handle: h, dx: dx, dy: dy, lockedAspect: lockedAspect, sourceAspect: model.sourceAspect)
            }
            .onEnded { _ in dragStart = nil; dragging = false }
    }

    /// New crop after dragging a handle by (dx, dy) of the image size. Pure; kept inside 0…1.
    static func resize(_ s: NormRect, handle: Handle, dx: Double, dy: Double, lockedAspect: Double?, sourceAspect: Double) -> NormRect {
        var minX = s.x, minY = s.y, maxX = s.x + s.width, maxY = s.y + s.height
        let snap = 0.012
        func clamp(_ v: Double) -> Double { let c = min(max(v, 0), 1); return c < snap ? 0 : (c > 1 - snap ? 1 : c) }
        switch handle {
        case .body:
            let w = s.width, h = s.height
            minX = min(max(s.x + dx, 0), 1 - w); minY = min(max(s.y + dy, 0), 1 - h)
            if minX < snap { minX = 0 }; if minY < snap { minY = 0 }
            if 1 - (minX + w) < snap { minX = 1 - w }; if 1 - (minY + h) < snap { minY = 1 - h }
            return NormRect(x: minX, y: minY, width: w, height: h)
        case .left: minX = min(clamp(minX + dx), maxX - minSize)
        case .right: maxX = max(clamp(maxX + dx), minX + minSize)
        case .top: minY = min(clamp(minY + dy), maxY - minSize)
        case .bottom: maxY = max(clamp(maxY + dy), minY + minSize)
        case .topLeft: minX = min(clamp(minX + dx), maxX - minSize); minY = min(clamp(minY + dy), maxY - minSize)
        case .topRight: maxX = max(clamp(maxX + dx), minX + minSize); minY = min(clamp(minY + dy), maxY - minSize)
        case .bottomLeft: minX = min(clamp(minX + dx), maxX - minSize); maxY = max(clamp(maxY + dy), minY + minSize)
        case .bottomRight: maxX = max(clamp(maxX + dx), minX + minSize); maxY = max(clamp(maxY + dy), minY + minSize)
        }
        var r = NormRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let lockedAspect {
            // Normalized height that gives `lockedAspect` in pixels, anchored at the opposite edge/corner.
            let wantH = r.width * sourceAspect / lockedAspect
            let wantW = r.height * lockedAspect / sourceAspect
            let widthDriven = [.left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight].contains(handle)
            var w = widthDriven ? r.width : wantW, h = widthDriven ? wantH : r.height
            // Keep inside the frame.
            let anchorRight = [.left, .topLeft, .bottomLeft].contains(handle)
            let anchorBottom = [.top, .topLeft, .topRight].contains(handle)
            let maxW = anchorRight ? maxX : 1 - minX, maxH = anchorBottom ? maxY : 1 - minY
            if h > maxH { h = maxH; w = h * lockedAspect / sourceAspect }
            if w > maxW { w = maxW; h = w * sourceAspect / lockedAspect }
            r = NormRect(x: anchorRight ? maxX - w : minX, y: anchorBottom ? maxY - h : minY, width: w, height: h)
        }
        return r
    }

    /// The largest centred crop with `aspect` (pixels), for the preset buttons.
    static func centered(aspect: Double, sourceAspect: Double) -> NormRect {
        if sourceAspect > aspect {
            let w = aspect / sourceAspect
            return NormRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
        let h = sourceAspect / aspect
        return NormRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
    }
}

/// Replaces the playback bar while cropping: aspect presets, Reset, Cancel and Done.
struct CropToolbar: View {
    @Bindable var model: EditorModel
    @Binding var lockedAspect: Double?

    struct Preset: Identifiable { var id: String; var aspect: Double? }
    static let presets = [Preset(id: "Free", aspect: nil), Preset(id: "16:9", aspect: 16.0 / 9), Preset(id: "4:3", aspect: 4.0 / 3),
                          Preset(id: "1:1", aspect: 1), Preset(id: "9:16", aspect: 9.0 / 16)]
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Self.presets) { p in
                    let on = lockedAspect == p.aspect
                    Button {
                        withAnimation(Anim.easeInOut(0.25)) {
                            lockedAspect = p.aspect
                            if let a = p.aspect { model.cropDraft = CropEditor.centered(aspect: a, sourceAspect: model.sourceAspect) }
                        }
                    } label: {
                        Text(p.id).font(.system(size: 12, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? Theme.accentSoft : Theme.text)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background {
                                if on {
                                    Capsule().fill(Color.white).shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                        .matchedGeometryEffect(id: "pill", in: pill)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Capsule().fill(Theme.control))

            Menu {
                Button("Remove browser toolbar (top 8%)") {
                    lockedAspect = nil
                    withAnimation(Anim.easeInOut(0.25)) { model.cropDraft = NormRect(x: 0, y: 0.08, width: 1, height: 0.92) }
                }
                Button("Reset to full frame") {
                    lockedAspect = nil
                    withAnimation(Anim.easeInOut(0.25)) { model.cropDraft = .full }
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More crop options")

            Spacer(minLength: 4)
            Button("Cancel") { model.cancelCrop() }.buttonStyle(SmallButtonStyle())
            Button("Done") { model.commitCrop() }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .glass()
    }
}
