import Composition
import PlaygroundCore
import Render
import SwiftUI
import Timeline

extension EditorModel {
    /// Binding to any document value; each change is undoable and drags coalesce into one step.
    func binding<V: Equatable>(_ keyPath: WritableKeyPath<ProjectDocument, V>, _ name: String) -> Binding<V> {
        Binding(get: { self.doc[keyPath: keyPath] }, set: { v in self.update(name, coalesce: true) { $0[keyPath: keyPath] = v } })
    }

    /// Binding to a field of a timeline item found by ID. Safe if the item is deleted while a view still
    /// holds the binding (SwiftUI may read it once more): reads fall back, writes are ignored.
    func item<T: Identifiable, V: Equatable>(_ list: WritableKeyPath<PlaygroundCore.Scene, [T]>, _ id: ItemID, _ field: WritableKeyPath<T, V>,
                                             fallback: V, _ name: String) -> Binding<V> where T.ID == ItemID {
        Binding(get: {
            self.doc.scene[keyPath: list].first { $0.id == id }?[keyPath: field] ?? fallback
        }, set: { v in
            self.update(name, coalesce: true) { d in
                if let i = d.scene[keyPath: list].firstIndex(where: { $0.id == id }) { d.scene[keyPath: list][i][keyPath: field] = v }
            }
        })
    }
}

struct SidebarView: View {
    @Bindable var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch model.selection {
                case let .zoom(id)?: ZoomInspector(model: model, id: id)
                case let .slice(id)?: SliceInspector(model: model, id: id)
                case let .mask(id)?: MaskInspector(model: model, id: id)
                case nil:
                    switch model.panel {
                    case .background: BackgroundPanel(model: model)
                    case .cursor: CursorPanel(model: model)
                    case .camera: CameraPanel(model: model)
                    case .audio: AudioPanel(model: model)
                    case .animation: AnimationPanel(model: model)
                    case .shortcuts: ShortcutsPanel(model: model)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
    }
}

/// The floating glass sidebar: a segmented tab bar over the panel content.
struct SidebarPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            PanelTabs(model: model)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)
            SidebarView(model: model)
        }
        .glass(cornerRadius: Theme.panelRadius)
    }
}

/// Segmented icon tabs that switch sidebar panels (disabled when the recording lacks that data).
struct PanelTabs: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(EditorPanel.allCases) { p in
                let enabled = (p != .camera || model.hasCamera) && (p != .shortcuts || model.hasKeystrokes)
                let selected = model.panel == p && model.selection == nil
                Button {
                    model.selection = nil
                    model.panel = p
                } label: {
                    Image(systemName: p.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(selected ? Theme.accentSoft : Theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(selected ? Color.white : .clear)
                                .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 2, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.3)
                .help(enabled ? p.title : "\(p.title) — not available for this recording")
                .accessibilityLabel(p.title)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.control))
    }
}

// MARK: - Background

struct BackgroundPanel: View {
    var model: EditorModel
    @State private var category = "Playground"

    var body: some View {
        let bg = model.doc.config.background
        PanelSection(title: "Background") {
            PillPicker(options: BackgroundKind.allCases, selection: model.binding(\.config.background.kind, "Background type"),
                       label: { $0.rawValue.capitalized })
        }
        switch bg.kind {
        case .wallpaper:
            PanelSection(title: "Wallpaper", trailing: AnyView(Button {
                let all = WallpaperCatalog.procedural + WallpaperCatalog.systemWallpapers()
                if let pick = all.randomElement() { model.update("Wallpaper") { $0.config.background.wallpaper = pick.id } }
            } label: { Label("Random", systemImage: "dice") }.buttonStyle(SmallButtonStyle()))) {
                PillPicker(options: ["Playground", "macOS"], selection: $category, label: { $0 })
                let items = category == "macOS" ? WallpaperCatalog.systemWallpapers() : WallpaperCatalog.procedural
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 6), count: 5), spacing: 6) {
                    ForEach(items) { w in
                        Button { model.update("Wallpaper") { $0.config.background.wallpaper = w.id } } label: {
                            WallpaperThumb(info: w)
                                .frame(width: 52, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(bg.wallpaper == w.id ? Color.white : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(w.name)
                    }
                }
                if items.isEmpty { Text("No system wallpapers found.").font(.system(size: 11)).foregroundStyle(Theme.secondaryText) }
            }
        case .gradient:
            PanelSection(title: "Gradient") {
                HStack {
                    ColorPicker("From", selection: colorBinding(\.config.background.gradient.stops[0].color, "Gradient"))
                    ColorPicker("To", selection: colorBinding(\.config.background.gradient.stops[1].color, "Gradient"))
                }
                .font(.system(size: 12))
                PillPicker(options: ["↘", "↓", "→", "↗"], selection: Binding(get: { gradientDirection(bg.gradient) }, set: { d in
                    model.update("Gradient direction") { doc in
                        let (s, e): (NormPoint, NormPoint) = switch d {
                        case "↓": (NormPoint(0.5, 0), NormPoint(0.5, 1))
                        case "→": (NormPoint(0, 0.5), NormPoint(1, 0.5))
                        case "↗": (NormPoint(0, 1), NormPoint(1, 0))
                        default: (NormPoint(0, 0), NormPoint(1, 1))
                        }
                        doc.config.background.gradient.start = s
                        doc.config.background.gradient.end = e
                    }
                }), label: { $0 })
            }
        case .color:
            PanelSection(title: "Color") {
                ColorPicker("Background color", selection: colorBinding(\.config.background.color, "Color")).font(.system(size: 12))
            }
        case .image:
            PanelSection(title: "Image") {
                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    if panel.runModal() == .OK, let url = panel.url { model.update("Background image") { $0.config.background.imagePath = url.path } }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "photo").font(.system(size: 20))
                        Text(bg.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Click to choose an image")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(Theme.stroke))
                }
                .buttonStyle(.plain)
            }
        }
        PanelSection(title: "Background blur") {
            ResettableSlider(value: model.binding(\.config.background.blur, "Blur"), range: 0...1, defaultValue: 0)
        }
        Divider()
        PanelSection(title: "Padding") {
            ResettableSlider(value: model.binding(\.config.frame.padding, "Padding"), range: 0...0.3, defaultValue: FrameConfig().padding,
                             format: { String(format: "%.0f%%", $0 / 0.3 * 100) })
        }
        PanelSection(title: "Rounded corners") {
            ResettableSlider(value: model.binding(\.config.frame.cornerRadius, "Corners"), range: 0...48, defaultValue: FrameConfig().cornerRadius,
                             format: { String(format: "%.0f px", $0) })
        }
        PanelSection(title: "Inset") {
            HelpToggle(title: "Add inset around the screen", isOn: model.binding(\.config.frame.insetEnabled, "Inset"))
            if model.doc.config.frame.insetEnabled {
                ResettableSlider(value: model.binding(\.config.frame.inset, "Inset"), range: 0...40, defaultValue: 0, format: { String(format: "%.0f px", $0) })
                ColorPicker("Inset color", selection: colorBinding(\.config.frame.insetColor, "Inset color")).font(.system(size: 12))
            }
        }
        Divider()
        PanelSection(title: "Shadow") {
            ResettableSlider(value: model.binding(\.config.frame.shadowIntensity, "Shadow"), range: 0...1, defaultValue: FrameConfig().shadowIntensity)
            PillPicker(options: ShadowStyle.allCases, selection: model.binding(\.config.frame.shadowStyle, "Shadow style"), label: { $0.rawValue.capitalized })
        }
        Disclosure(title: "Advanced shadow settings") {
            ResettableSlider(title: "Distance", value: model.binding(\.config.frame.shadowDistance, "Shadow"), range: 0...100, defaultValue: 25,
                             format: { String(format: "%.0f", $0) })
            ResettableSlider(title: "Angle", value: model.binding(\.config.frame.shadowAngle, "Shadow"), range: 0...360, defaultValue: 90,
                             format: { String(format: "%.0f°", $0) })
            ResettableSlider(title: "Blur", value: model.binding(\.config.frame.shadowBlur, "Shadow"), range: 0...80, defaultValue: 20,
                             format: { String(format: "%.0f", $0) })
        }
    }

    func colorBinding(_ kp: WritableKeyPath<ProjectDocument, RGBAColor>, _ name: String) -> Binding<Color> {
        Binding(get: {
            let c = model.doc[keyPath: kp]
            return Color(red: c.r, green: c.g, blue: c.b, opacity: c.a)
        }, set: { color in
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
            model.update(name, coalesce: true) {
                $0[keyPath: kp] = RGBAColor(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
            }
        })
    }

    func gradientDirection(_ g: GradientConfig) -> String {
        if g.start.x == 0.5 { return "↓" }
        if g.start.y == 0.5 { return "→" }
        if g.start.y == 1 { return "↗" }
        return "↘"
    }
}

/// Thumbnail for a wallpaper: system images are loaded downscaled; procedural ones are drawn as gradients.
struct WallpaperThumb: View {
    var info: WallpaperInfo
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let path = info.filePath {
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) } else { Color.gray.opacity(0.3) }
                Color.clear.task(id: path) { image = await Self.thumbnail(path) }
            } else {
                let c = info.palette.map { Color(red: $0.r, green: $0.g, blue: $0.b) }
                ZStack {
                    LinearGradient(colors: [c[0], c[1]], startPoint: .topLeading, endPoint: .topTrailing)
                    LinearGradient(colors: [c[2], c[3]], startPoint: .bottomLeading, endPoint: .bottomTrailing)
                        .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                }
            }
        }
    }

    static func thumbnail(_ path: String) async -> NSImage? {
        await Task.detached {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                        kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }
}

// MARK: - Cursor

struct CursorPanel: View {
    var model: EditorModel

    var body: some View {
        PanelSection(title: "Cursor size") {
            ResettableSlider(value: model.binding(\.config.cursor.size, "Cursor size"), range: 0.5...4, defaultValue: CursorConfig().size,
                             format: { String(format: "%.1f×", $0) })
        }
        PanelSection(title: "Cursor style") {
            PillPicker(options: CursorSet.allCases, selection: model.binding(\.config.cursor.set, "Cursor style"), label: { s in
                switch s {
                case .system: return "Recorded"
                case .macos: return "macOS"
                case .touch: return "Touch"
                case .outline: return "Outline"
                }
            })
            HelpToggle(title: "Always use pointer cursor", help: "Don't change cursor, even if selecting text, etc.",
                       isOn: model.binding(\.config.cursor.alwaysUsePointer, "Always pointer"))
        }
        Divider()
        PanelSection(title: "Visibility") {
            HelpToggle(title: "Hide cursor if not moving", isOn: model.binding(\.config.cursor.hideWhenIdle, "Hide idle"))
            HelpToggle(title: "Loop cursor position", help: "Near the end of the video, the cursor moves back to its initial position.",
                       isOn: model.binding(\.config.cursor.loopPosition, "Loop cursor"))
            HelpToggle(title: "Hide cursor", isOn: model.binding(\.config.cursor.hidden, "Hide cursor"))
        }
        Divider()
        PanelSection(title: "Click effect") {
            PillPicker(options: ClickEffect.allCases, selection: model.binding(\.config.cursor.clickEffect, "Click effect"), label: { $0.rawValue.capitalized })
        }
        Disclosure(title: "Rotation") {
            ResettableSlider(title: "Rotate cursor", value: model.binding(\.config.cursor.baseRotation, "Rotation"), range: -45...45, defaultValue: 0,
                             format: { String(format: "%.0f°", $0) })
            Text("Rotate while moving").font(.system(size: 12))
            PillPicker(options: CursorRotationMode.allCases, selection: model.binding(\.config.cursor.rotationMode, "Rotation mode"),
                       label: { $0.rawValue.capitalized })
            Text(model.doc.config.cursor.rotationMode == .tilt ? "Leans with fast horizontal movement, settling back upright at rest."
                 : "Points in the direction the cursor travels.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            ResettableSlider(title: "Tilt amount", value: model.binding(\.config.cursor.tiltAmount, "Tilt"), range: 0...1.5, defaultValue: 0.5)
        }
        Disclosure(title: "Advanced") {
            ResettableSlider(title: "Stop cursor movement at the end", value: model.binding(\.config.cursor.stopMovementBeforeEnd, "Stop at end"),
                             range: 0...5, defaultValue: 0, format: { String(format: "%.1fs", $0) })
            HelpToggle(title: "Remove cursor shakes", help: "Detect and remove sudden tiny movements.",
                       isOn: model.binding(\.config.cursor.removeShakes, "Shakes"))
            HelpToggle(title: "Optimize cursor changes", help: "Minimize rapid cursor flicker when moving over elements.",
                       isOn: model.binding(\.config.cursor.optimizeCursorChanges, "Cursor changes"))
        }
    }
}

// MARK: - Camera

struct CameraPanel: View {
    var model: EditorModel

    var body: some View {
        PanelSection(title: "Camera") {
            HelpToggle(title: "Hide camera", isOn: model.binding(\.config.camera.hidden, "Hide camera"))
        }
        PanelSection(title: "Default layout") {
            PillPicker(options: [CameraLayoutKind.overlay, .split, .cameraOnly, .screenOnly], selection: model.binding(\.config.camera.layout, "Layout"),
                       label: { k in
                           switch k {
                           case .overlay: return "Overlay"
                           case .split: return "Split screen"
                           case .cameraOnly: return "Camera only"
                           case .screenOnly: return "Screen only"
                           case .cutout: return "Cutout"
                           }
                       })
        }
        PanelSection(title: "Camera position") {
            let pos = model.doc.config.camera.position
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach([0.0, 0.5, 1.0], id: \.self) { y in
                    GridRow {
                        ForEach([0.0, 0.5, 1.0], id: \.self) { x in
                            let center = x == 0.5 && y == 0.5
                            Button { model.update("Camera position") { $0.config.camera.position = NormPoint(x, y) } } label: {
                                Circle().fill(pos == NormPoint(x, y) ? Theme.accentSoft : Color.white.opacity(center ? 0 : 0.6))
                                    .frame(width: 8, height: 8).frame(maxWidth: .infinity).frame(height: 30).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(center)
                        }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.control))
        }
        PanelSection(title: "Camera aspect ratio") {
            PillPicker(options: CameraAspect.allCases, selection: model.binding(\.config.camera.aspect, "Camera aspect"), label: { $0.rawValue })
        }
        PanelSection(title: "Camera size") {
            ResettableSlider(value: model.binding(\.config.camera.size, "Camera size"), range: 0.1...0.6, defaultValue: CameraConfig().size)
        }
        PanelSection(title: "Camera size during zoom") {
            ResettableSlider(value: model.binding(\.config.camera.scaleDuringZoom, "Camera zoom size"), range: 0.3...1, defaultValue: 0.7)
        }
        PanelSection(title: "Camera rounded corners") {
            ResettableSlider(value: model.binding(\.config.camera.roundness, "Camera roundness"), range: 0...1, defaultValue: CameraConfig().roundness)
            HelpToggle(title: "Mirror camera", isOn: model.binding(\.config.camera.mirror, "Mirror"))
        }
    }
}

// MARK: - Audio

struct AudioPanel: View {
    var model: EditorModel

    var body: some View {
        let channels = model.project?.manifest.channels.map(\.kind) ?? []
        PanelSection(title: "Volume") {
            ResettableSlider(value: model.binding(\.config.audio.masterVolume, "Volume"), range: 0...2, defaultValue: 1)
        }
        if channels.contains(.microphone) {
            PanelSection(title: "Microphone") {
                HelpToggle(title: "Mute microphone", isOn: model.binding(\.config.audio.muteMicrophone, "Mute mic"))
            }
        }
        if channels.contains(.systemAudio) {
            PanelSection(title: "System audio") {
                HelpToggle(title: "Mute system audio", isOn: model.binding(\.config.audio.muteSystemAudio, "Mute system audio"))
            }
        }
        if !channels.contains(.microphone) && !channels.contains(.systemAudio) {
            Text("This recording has no audio.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText).padding(.vertical, 8)
        }
        Divider()
        PanelSection(title: "Background music") {
            if let path = model.doc.config.audio.backgroundMusicPath {
                HStack {
                    Image(systemName: "music.note")
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Button("Remove") { model.update("Remove music") { $0.config.audio.backgroundMusicPath = nil } }.buttonStyle(SmallButtonStyle())
                }
                ResettableSlider(title: "Music volume", value: model.binding(\.config.audio.backgroundMusicVolume, "Music volume"),
                                 range: 0...1, defaultValue: 0.1)
            }
            Button {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio]
                if panel.runModal() == .OK, let url = panel.url { model.update("Add music") { $0.config.audio.backgroundMusicPath = url.path } }
            } label: { Label("Add background audio", systemImage: "plus") }
                .buttonStyle(SmallButtonStyle())
            Text("Music loops to fit the video and fades out at the end.").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
        }
    }
}

// MARK: - Animation

struct AnimationPanel: View {
    var model: EditorModel

    var body: some View {
        PanelSection(title: "Screen animation style") {
            PillPicker(options: ScreenAnimationStyle.allCases, selection: model.binding(\.config.motion.screenStyle, "Screen animation"),
                       label: { $0.rawValue.capitalized }, icon: { $0 == .focused ? "scope" : "point.topleft.down.to.point.bottomright.curvepath" })
        }
        PanelSection(title: "Cursor animation style") {
            PillPicker(options: CursorAnimationStyle.allCases, selection: model.binding(\.config.motion.cursorStyle, "Cursor animation"),
                       label: { $0.rawValue.capitalized })
        }
        Divider()
        PanelSection(title: "Motion blur") {
            Text("Moving elements get a cinematic motion blur.").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            ResettableSlider(value: model.binding(\.config.motion.motionBlur, "Motion blur"), range: 0...1, defaultValue: 1)
        }
        Disclosure(title: "Auto zoom") {
            ResettableSlider(title: "Default zoom level", value: model.binding(\.config.autoZoom.defaultLevel, "Auto zoom"), range: 1.3...3.5,
                             defaultValue: 2, format: { String(format: "%.1f×", $0) })
            ResettableSlider(title: "Start before click", value: model.binding(\.config.autoZoom.leadIn, "Auto zoom"), range: 0...2,
                             defaultValue: 0.8, format: { String(format: "%.1fs", $0) })
            ResettableSlider(title: "Stay after click", value: model.binding(\.config.autoZoom.leadOut, "Auto zoom"), range: 0.3...4,
                             defaultValue: 1.5, format: { String(format: "%.1fs", $0) })
            HStack {
                Button("Regenerate auto zooms") { model.regenerateAutoZooms() }.buttonStyle(SmallButtonStyle())
                Button("Remove all zooms") { model.removeAllZooms() }.buttonStyle(SmallButtonStyle())
            }
        }
    }
}

struct ShortcutsPanel: View {
    var model: EditorModel
    var body: some View {
        PanelSection(title: "Keyboard shortcuts") {
            HelpToggle(title: "Show shortcuts", help: "Overlay keyboard shortcuts you pressed while recording.",
                       isOn: model.binding(\.config.shortcuts.enabled, "Shortcuts"))
            HelpToggle(title: "Show single key shortcuts", isOn: model.binding(\.config.shortcuts.includeSingleKeys, "Single keys"))
            ResettableSlider(title: "Size", value: model.binding(\.config.shortcuts.size, "Shortcut size"), range: 0.5...2, defaultValue: 1,
                             format: { String(format: "%.1f×", $0) })
        }
    }
}

// MARK: - Inspectors

struct InspectorHeader: View {
    var title: String
    var model: EditorModel
    var body: some View {
        HStack {
            Button { model.selection = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(IconButtonStyle())
            Text(title).font(.system(size: 14, weight: .semibold))
            Spacer()
            Button(role: .destructive) { model.deleteSelection() } label: { Image(systemName: "trash") }.buttonStyle(IconButtonStyle())
        }
        .padding(.vertical, 6)
    }
}

struct ZoomInspector: View {
    var model: EditorModel
    var id: ItemID

    var body: some View {
        if let zoom = model.doc.scene.zooms.first(where: { $0.id == id }) {
            InspectorHeader(title: "Zoom", model: model)
            PanelSection(title: "Zoom level", trailing: AnyView(Button("Apply to all") {
                model.update("Apply zoom level") { $0.scene = Edits.applyZoomLevelToAll($0.scene, level: zoom.level) }
            }.buttonStyle(SmallButtonStyle()))) {
                ResettableSlider(value: model.item(\.zooms, id, \.level, fallback: zoom.level, "Zoom level"), range: 1.1...5, defaultValue: 2,
                                 format: { String(format: "%.1f×", $0) })
            }
            PanelSection(title: "Style") {
                PillPicker(options: [ZoomStyle.classic, .loupe], selection: model.item(\.zooms, id, \.style, fallback: zoom.style, "Zoom style"),
                           label: { $0 == .classic ? "Classic" : "Glass Loupe" }, icon: { $0 == .classic ? "plus.magnifyingglass" : "circle.circle" })
            }
            PanelSection(title: "Mode") {
                PillPicker(options: [ZoomMode.auto, .manual], selection: model.item(\.zooms, id, \.mode, fallback: zoom.mode, "Zoom mode"),
                           label: { $0 == .auto ? "Auto (follow cursor)" : "Manual" })
                if zoom.mode == .manual {
                    ManualTargetPicker(target: model.item(\.zooms, id, \.manualTarget, fallback: zoom.manualTarget, "Zoom target"),
                                       level: zoom.level, frame: model.zoomFrames[id], aspect: model.sourceAspect)
                        .task(id: id) { await model.loadZoomFrame(id) }
                    Text("Drag to aim. The preview jumps to this zoom so you see the result.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
            }
            PanelSection(title: "Animation") {
                HelpToggle(title: "Instant animation", help: "Cut straight in instead of animating.",
                           isOn: model.item(\.zooms, id, \.instant, fallback: zoom.instant, "Instant zoom"))
                HelpToggle(title: "Disabled", isOn: model.item(\.zooms, id, \.disabled, fallback: zoom.disabled, "Disable zoom"))
            }
        }
    }
}

/// Shows the actual video frame with a rectangle for exactly what the zoom will show.
/// Drag anywhere to aim the zoom (snaps to the centre lines).
struct ManualTargetPicker: View {
    @Binding var target: NormPoint
    var level: Double
    var frame: NSImage?
    var aspect: Double

    var body: some View {
        GeometryReader { g in
            let half = 0.5 / max(level, 1)
            let cx = min(max(target.x, half), 1 - half), cy = min(max(target.y, half), 1 - half)
            let view = CGRect(x: (cx - half) * g.size.width, y: (cy - half) * g.size.height,
                              width: 2 * half * g.size.width, height: 2 * half * g.size.height)
            ZStack(alignment: .topLeading) {
                if let frame {
                    Image(nsImage: frame).resizable().frame(width: g.size.width, height: g.size.height)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.control)
                }
                // Dim what falls outside the zoomed view.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: g.size))
                    p.addRect(view)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Rectangle().strokeBorder(Theme.accentSoft, lineWidth: 2)
                    .frame(width: view.width, height: view.height).offset(x: view.minX, y: view.minY)
                Circle().fill(Theme.accentSoft).frame(width: 10, height: 10)
                    .position(x: target.x * g.size.width, y: target.y * g.size.height)
                Text("\(Int(target.x * 100))%, \(Int(target.y * 100))% · \(String(format: "%.1f", level))×")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                var x = min(max(v.location.x / g.size.width, 0), 1), y = min(max(v.location.y / g.size.height, 0), 1)
                if abs(x - 0.5) < 0.02 { x = 0.5 }
                if abs(y - 0.5) < 0.02 { y = 0.5 }
                target = NormPoint(x, y)
            })
        }
        .aspectRatio(aspect, contentMode: .fit)
    }
}

struct SliceInspector: View {
    var model: EditorModel
    var id: ItemID

    var body: some View {
        if let slice = model.doc.scene.slices.first(where: { $0.id == id }) {
            InspectorHeader(title: "Clip", model: model)
            PanelSection(title: "Speed") {
                PillPicker(options: [0.5, 1, 1.5, 2, 3, 4, 8], selection: Binding(get: { slice.speed }, set: { s in
                    model.update("Speed") { $0.scene = Edits.setSpeed($0.scene, sliceID: id, speed: s) }
                }), label: speedLabel)
                Button("Apply to all clips") { model.update("Speed all") { $0.scene = Edits.setSpeed($0.scene, sliceID: nil, speed: slice.speed) } }
                    .buttonStyle(SmallButtonStyle())
            }
            PanelSection(title: "Volume") {
                ResettableSlider(value: model.item(\.slices, id, \.volume, fallback: slice.volume, "Clip volume"), range: 0...2, defaultValue: 1)
            }
            PanelSection(title: "Cursor") {
                HelpToggle(title: "Hide cursor in this clip", isOn: model.item(\.slices, id, \.hideCursor, fallback: slice.hideCursor, "Hide cursor"))
                HelpToggle(title: "Disable smooth movement", help: "Useful for dropdown menus and precise moves.",
                           isOn: model.item(\.slices, id, \.disableSmoothing, fallback: slice.disableSmoothing, "Smooth movement"))
            }
            Text("Source \(timecode(slice.source.start.seconds)) – \(timecode(slice.source.end.seconds))")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondaryText)
        }
    }
}

struct MaskInspector: View {
    var model: EditorModel
    var id: ItemID

    var body: some View {
        if let mask = model.doc.scene.masks.first(where: { $0.id == id }) {
            InspectorHeader(title: "Mask", model: model)
            PanelSection(title: "Type") {
                PillPicker(options: MaskKind.allCases, selection: model.item(\.masks, id, \.kind, fallback: mask.kind, "Mask type"), label: { $0.rawValue.capitalized })
            }
            PanelSection(title: "Area") {
                MaskRectEditor(rect: model.item(\.masks, id, \.rect, fallback: mask.rect, "Mask area")).frame(height: 130)
                Text("Drag to move. Drag the corner handle to resize.").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            if mask.kind == .highlight {
                PanelSection(title: "Dim amount") {
                    ResettableSlider(value: model.item(\.masks, id, \.opacity, fallback: mask.opacity, "Highlight"), range: 0.1...0.95, defaultValue: 0.7)
                }
            }
        }
    }
}

struct MaskRectEditor: View {
    @Binding var rect: NormRect
    @State private var base: NormRect?

    var body: some View {
        GeometryReader { g in
            let r = CGRect(x: rect.x * g.size.width, y: rect.y * g.size.height, width: rect.width * g.size.width, height: rect.height * g.size.height)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Theme.control)
                Rectangle().fill(Theme.mask.opacity(0.5)).overlay(Rectangle().stroke(Theme.mask))
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    .gesture(DragGesture().onChanged { v in
                        let b = base ?? rect
                        if base == nil { base = rect }
                        rect.x = min(max(b.x + v.translation.width / g.size.width, 0), 1 - b.width)
                        rect.y = min(max(b.y + v.translation.height / g.size.height, 0), 1 - b.height)
                    }.onEnded { _ in base = nil })
                Circle().fill(.white).frame(width: 10, height: 10).offset(x: r.maxX - 5, y: r.maxY - 5)
                    .gesture(DragGesture().onChanged { v in
                        let b = base ?? rect
                        if base == nil { base = rect }
                        rect.width = min(max(b.width + v.translation.width / g.size.width, 0.03), 1 - b.x)
                        rect.height = min(max(b.height + v.translation.height / g.size.height, 0.03), 1 - b.y)
                    }.onEnded { _ in base = nil })
            }
        }
    }
}
