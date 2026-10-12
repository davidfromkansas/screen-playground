import AppKit
import Composition
import PlaygroundCore
import Render
import SwiftUI

struct EditorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        Group {
            if let error = model.loadError {
                ContentUnavailableView("Couldn't open project", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.project == nil {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.exportPresented) { ExportSheet(model: model) }
    }

    var content: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PreviewToolbar(model: model)
                    HStack(spacing: 0) {
                        LeftToolbar(model: model)
                        PreviewView(model: model)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    TransportBar(model: model)
                }
                PanelRail(model: model)
                SidebarView(model: model)
                    .frame(width: 300)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                    .padding(.trailing, 10)
                    .padding(.vertical, 8)
            }
            TimelineView(model: model)
                .padding(.bottom, 10)
                .background(Theme.background)
        }
    }
}

struct TopBar: View {
    @Bindable var model: EditorModel
    @State private var name = ""
    @FocusState private var editingName: Bool

    var body: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 70) // traffic lights
            Button { AppModel.shared.showHome() } label: { Image(systemName: "folder") }.buttonStyle(IconButtonStyle()).help("Projects")
            Button { NSWorkspace.shared.activateFileViewerSelecting([model.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(IconButtonStyle()).help("Show project in Finder")
            Spacer()
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .focused($editingName)
                .onSubmit { model.rename(name); editingName = false }
                .onAppear { name = model.doc.name }
                .onChange(of: model.doc.name) { _, n in if !editingName { name = n } }
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(IconButtonStyle()).disabled(!model.canUndo).help("Undo (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(IconButtonStyle()).disabled(!model.canRedo).help("Redo (⇧⌘Z)")
            PresetsMenu(model: model)
            Button { model.exportPresented = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut("e", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }
}

struct PreviewToolbar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Aspect ratio", selection: model.binding(\.config.output.aspect, "Aspect ratio")) {
                    ForEach(AspectRatio.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Label(model.doc.config.output.aspect == .auto ? "Auto" : model.doc.config.output.aspect.rawValue, systemImage: "aspectratio") }
                .menuStyle(.borderlessButton).fixedSize()
            Menu {
                Button("Remove browser toolbar (top 8%)") { model.update("Crop") { $0.config.output.crop = NormRect(x: 0, y: 0.08, width: 1, height: 0.92) } }
                Button("Crop to center 16:9") { model.update("Crop") { $0.config.output.crop = Self.centerCrop(model: model, aspect: 16.0 / 9) } }
                Button("Crop to center square") { model.update("Crop") { $0.config.output.crop = Self.centerCrop(model: model, aspect: 1) } }
                Divider()
                Button("Reset crop") { model.update("Crop") { $0.config.output.crop = .full } }
            } label: { Label("Crop", systemImage: "crop") }
                .menuStyle(.borderlessButton).fixedSize()
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 64)
        .frame(height: 30)
    }

    static func centerCrop(model: EditorModel, aspect: Double) -> NormRect {
        guard let p = model.project else { return .full }
        let src = Double(p.sourcePixelSize.width / max(p.sourcePixelSize.height, 1))
        if src > aspect {
            let w = aspect / src
            return NormRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
        let h = src / aspect
        return NormRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
    }
}

/// Quick-add tools beside the preview: zooms, loupe, masks, camera layouts.
struct LeftToolbar: View {
    var model: EditorModel

    var body: some View {
        VStack(spacing: 4) {
            Button { model.addZoom() } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(IconButtonStyle()).help("Add zoom at playhead")
            Button {
                model.addZoom()
                if case let .zoom(id)? = model.selection {
                    model.update("Loupe") { d in if let i = d.scene.zooms.firstIndex(where: { $0.id == id }) { d.scene.zooms[i].style = .loupe } }
                }
            } label: { Image(systemName: "circle.circle") }.buttonStyle(IconButtonStyle()).help("Add Glass Loupe at playhead")
            Divider().frame(width: 24)
            Button { model.addMask(kind: .blur) } label: { Image(systemName: "eye.slash") }.buttonStyle(IconButtonStyle()).help("Blur sensitive area")
            Button { model.addMask(kind: .highlight) } label: { Image(systemName: "rectangle.inset.filled") }.buttonStyle(IconButtonStyle()).help("Add highlight")
            if model.hasCamera {
                Divider().frame(width: 24)
                ForEach([CameraLayoutKind.overlay, .split, .cameraOnly, .screenOnly], id: \.self) { kind in
                    Button { addLayout(kind) } label: { Image(systemName: icon(kind)) }.buttonStyle(IconButtonStyle()).help("Switch layout here")
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .padding(.leading, 10)
    }

    func icon(_ k: CameraLayoutKind) -> String {
        switch k {
        case .overlay: return "pip"
        case .split: return "rectangle.split.2x1"
        case .cameraOnly: return "person.crop.rectangle"
        case .screenOnly: return "rectangle"
        case .cutout: return "person.and.background.dotted"
        }
    }

    func addLayout(_ kind: CameraLayoutKind) {
        guard let snap = model.snapshot, let src = snap.timeMap.source(at: OutputTime(model.time)) else { return }
        let start = src.time.seconds
        model.update("Add layout") { d in
            let next = d.scene.layouts.map(\.source.start.seconds).filter { $0 > start }.min() ?? model.recordingDuration
            d.scene.layouts.removeAll { $0.source.contains(SourceTime(start)) }
            d.scene.layouts.append(LayoutRange(source: SourceRange(start, min(next, start + 5)), layout: kind))
            d.scene.layouts.sort { $0.source.start < $1.source.start }
        }
    }
}

struct TransportBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Button { model.splitAtPlayhead() } label: { Image(systemName: "scissors") }.buttonStyle(IconButtonStyle()).help("Split at playhead (C)")
            Spacer()
            Text(timecode(model.time)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText).frame(width: 70, alignment: .trailing)
            Button { model.seek(0) } label: { Image(systemName: "backward.end.fill") }.buttonStyle(IconButtonStyle())
            Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18)) }
                .buttonStyle(IconButtonStyle()).help("Play/Pause (Space)")
            Button { model.seek(model.duration) } label: { Image(systemName: "forward.end.fill") }.buttonStyle(IconButtonStyle())
            Text(timecode(model.duration)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText).frame(width: 70, alignment: .leading)
            Spacer()
            Button { model.loopPlayback.toggle() } label: { Image(systemName: "repeat") }
                .buttonStyle(IconButtonStyle(active: model.loopPlayback)).help("Loop playback")
            Image(systemName: "minus.magnifyingglass").foregroundStyle(Theme.secondaryText)
            Slider(value: $model.timelineZoom, in: 1...20).frame(width: 110).controlSize(.mini).tint(Theme.accent)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }
}

// MARK: - Window

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    private var keyMonitor: Any?
    private let onClose: () -> Void

    init(url: URL, onClose: @escaping () -> Void) {
        model = EditorModel(url: url)
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 880),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = url.deletingPathExtension().lastPathComponent
        window.representedURL = url
        window.minSize = NSSize(width: 1000, height: 680)
        window.backgroundColor = NSColor(Theme.background)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: EditorView(model: model))
        window.center()
        window.setFrameAutosaveName("EditorWindow")
        installKeyMonitor()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            model.close()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            onClose()
        }
    }

    /// Single-key editing shortcuts (Space, C, X, Delete, arrows), ignored while typing in a text field.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let window = self.window, e.window == window else { return e }
            if window.firstResponder is NSTextView { return e }
            if window.attachedSheet != nil { return e }
            let m = self.model
            let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
            if mods == .command, e.charactersIgnoringModifiers == "z" { m.undo(); return nil }
            if mods == [.command, .shift], e.charactersIgnoringModifiers?.lowercased() == "z" { m.redo(); return nil }
            if mods == .command, e.charactersIgnoringModifiers == "c" { self.copyFrame(); return nil }
            if mods == .command, e.charactersIgnoringModifiers == "s" { m.save(); return nil }
            guard mods.isEmpty || mods == .shift else { return e }
            switch e.keyCode {
            case 49: m.togglePlay()                                  // space
            case 123: m.step(mods == .shift ? -1 : -1.0 / 30)        // ←
            case 124: m.step(mods == .shift ? 1 : 1.0 / 30)          // →
            case 51, 117: m.deleteSelection()                        // delete
            case 53: if m.selection != nil { m.selection = nil } else { return e } // esc
            default:
                switch e.charactersIgnoringModifiers?.lowercased() {
                case "c": m.splitAtPlayhead()
                case "x": m.rippleDeleteAtPlayhead()
                case "z": m.addZoom()
                case "m": m.addMask()
                case "l": m.loopPlayback.toggle()
                default: return e
                }
            }
            return nil
        }
    }

    /// ⌘C: copies the current frame as an image.
    func copyFrame() {
        guard let snap = model.snapshot, let ctx = MetalContext.shared, let p = model.project else { return }
        let time = model.time
        Task.detached {
            let size = snap.canvasSize(shortSide: 1080)
            let frame = SceneEvaluator.evaluate(snap, at: OutputTime(time), width: size.width, height: size.height)
            let comp = Compositor(context: ctx)
            comp.setCursorSource(folder: p.bundle.cursorsFolder, infos: p.events.cursors)
            let screen = try? await p.displayURL.asyncMap { try await Media.VideoFrameSource(url: $0) }
            let camera = try? await p.cameraURL.asyncMap { try await Media.VideoFrameSource(url: $0) }
            guard let img = comp.renderImage(frame, screen: (screen ?? nil)?.frame(at: frame.sourceTime.seconds),
                                             camera: (camera ?? nil)?.frame(at: frame.sourceTime.seconds),
                                             cursorSet: snap.document.config.cursor.set) else { return }
            let image = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                NSSound(named: "Pop")?.play()
            }
        }
    }
}

import Media
