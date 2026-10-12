import AppKit
import Capture
import SwiftUI

/// Borderless panel that floats above everything and never steals app activation.
final class OverlayPanel: NSPanel {
    init(frame: NSRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none // never appear in screen captures
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { AppModel.shared.recorder.cancelPicker() }
    }
}

/// The recording picker: one selection overlay per screen plus the floating toolbar.
@MainActor
final class PickerWindows {
    let controller: RecorderController
    private var overlays: [OverlayPanel] = []
    private var toolbar: OverlayPanel?

    init(controller: RecorderController) { self.controller = controller }

    func show() {
        hide()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            let panel = OverlayPanel(frame: screen.frame, level: .init(rawValue: NSWindow.Level.screenSaver.rawValue - 1))
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            // Global CG origin of this screen's top-left corner.
            let origin = CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
            panel.contentView = NSHostingView(rootView: SelectionOverlay(controller: controller, displayID: displayID,
                                                                         origin: origin, size: screen.frame.size))
            panel.orderFrontRegardless()
            overlays.append(panel)
        }
        let main = NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 640, height: 64)
        let frame = NSRect(x: main.frame.midX - size.width / 2, y: main.frame.minY + 110, width: size.width, height: size.height)
        let bar = OverlayPanel(frame: frame, level: .screenSaver)
        bar.contentView = NSHostingView(rootView: PickerToolbar(controller: controller).preferredColorScheme(.light))
        bar.hasShadow = true
        bar.isMovableByWindowBackground = true
        bar.makeKeyAndOrderFront(nil)
        toolbar = bar
    }

    func hide() {
        overlays.forEach { $0.close() }
        overlays.removeAll()
        toolbar?.close()
        toolbar = nil
    }
}

// MARK: - Toolbar

struct PickerToolbar: View {
    @Bindable var controller: RecorderController

    var body: some View {
        HStack(spacing: 6) {
            Button { controller.cancelPicker() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle())
                .help("Close (Esc)")
            Divider().frame(height: 26)
            ForEach(CaptureMode.allCases) { m in
                Button {
                    controller.mode = m
                    if m == .window { controller.refreshWindows() }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: m.icon).font(.system(size: 15))
                        Text(m.title).font(.system(size: 10, weight: .medium))
                    }
                    .frame(width: 62, height: 44)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(controller.mode == m ? Color.white : .clear)
                        .shadow(color: .black.opacity(controller.mode == m ? 0.12 : 0), radius: 3, y: 1))
                    .foregroundStyle(controller.mode == m ? Theme.accentSoft : Theme.text)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 26)
            deviceMenu(icon: "video", none: "No camera", devices: controller.cameras, selection: $controller.cameraID)
            deviceMenu(icon: "mic", none: "No microphone", devices: controller.microphones, selection: $controller.microphoneID)
            Button { controller.captureSystemAudio.toggle() } label: {
                Image(systemName: controller.captureSystemAudio ? "speaker.wave.2.fill" : "speaker.slash")
            }
            .buttonStyle(IconButtonStyle(active: controller.captureSystemAudio))
            .help(controller.captureSystemAudio ? "Recording system audio" : "System audio off")
            Menu {
                Picker("Countdown", selection: $controller.countdownSeconds) {
                    Text("No countdown").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                Toggle("Hide desktop icons", isOn: $controller.hideDesktopIcons)
            } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 32)
            Spacer(minLength: 4)
            Button { controller.start() } label: {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text("Record")
                }
            }
            .recordGlassButton()
            .disabled(!controller.canStart)
            .opacity(controller.canStart ? 1 : 0.5)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glass()
        .padding(4)
    }

    func deviceMenu(icon: String, none: String, devices: [AVDeviceInfo], selection: Binding<String?>) -> some View {
        Menu {
            Picker(selection: selection) {
                Text(none).tag(String?.none)
                ForEach(devices) { d in Text(d.name).tag(Optional(d.id)) }
            } label: { EmptyView() }
                .pickerStyle(.inline)
        } label: {
            Image(systemName: selection.wrappedValue == nil ? "\(icon).slash" : "\(icon).fill")
                .foregroundStyle(selection.wrappedValue == nil ? Theme.secondaryText : Theme.accentSoft)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34)
        .help(devices.first { $0.id == selection.wrappedValue }?.name ?? none)
    }
}

// MARK: - Selection overlay

/// Covers one screen. Shows hover/selection highlights and handles area dragging.
struct SelectionOverlay: View {
    @Bindable var controller: RecorderController
    let displayID: CGDirectDisplayID
    /// Global CG position of this screen's top-left corner.
    let origin: CGPoint
    let size: CGSize
    @State private var dragStart: CGPoint?

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch controller.mode {
            case .display: displayLayer
            case .window: windowLayer
            case .area: areaLayer
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard case let .active(p) = phase else { return }
            let global = CGPoint(x: origin.x + p.x, y: origin.y + p.y)
            switch controller.mode {
            case .display: controller.hoveredDisplay = displayID
            case .window: controller.hoveredWindow = controller.windows.first { $0.frame.contains(global) }
            case .area: break
            }
        }
    }

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }

    // Display: dim others, show a Record button centered on the hovered display.
    @ViewBuilder var displayLayer: some View {
        let active = (controller.selectedDisplay ?? controller.hoveredDisplay) == displayID
        Rectangle().fill(Color.black.opacity(active ? 0.0 : 0.45))
        Color.clear.contentShape(Rectangle()).onTapGesture {
            controller.selectedDisplay = displayID
            controller.start()
        }
        if active {
            RoundedRectangle(cornerRadius: 4).stroke(Theme.accent, lineWidth: 4).allowsHitTesting(false)
            recordButton.position(x: size.width / 2, y: size.height / 2)
        }
    }

    // Window: highlight the window under the cursor; click to select.
    @ViewBuilder var windowLayer: some View {
        let target = controller.selectedWindow ?? controller.hoveredWindow
        let rect = target.map { local($0.frame) }
        Canvas { ctx, s in
            var path = Path(CGRect(origin: .zero, size: s))
            if let rect { path.addRoundedRect(in: rect, cornerSize: CGSize(width: 10, height: 10)) }
            ctx.fill(path, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
            if let rect { ctx.stroke(Path(roundedRect: rect, cornerRadius: 10), with: .color(Theme.accent), lineWidth: 3) }
        }
        .allowsHitTesting(false)
        Color.clear.contentShape(Rectangle()).onTapGesture { _ in
            if let w = controller.hoveredWindow { controller.selectedWindow = w }
        }
        if let rect, let target, rect.intersects(CGRect(origin: .zero, size: size)) {
            VStack(spacing: 8) {
                Text(target.appName).font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .glass()
                if controller.selectedWindow != nil { recordButton }
            }
            .position(x: rect.midX, y: min(rect.maxY - 40, rect.midY))
        }
    }

    // Area: drag to draw; record button below the rect.
    @ViewBuilder var areaLayer: some View {
        let rect = controller.area.map(local)
        Canvas { ctx, s in
            var path = Path(CGRect(origin: .zero, size: s))
            if let rect { path.addRect(rect) }
            ctx.fill(path, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
            if let rect {
                ctx.stroke(Path(rect), with: .color(Theme.accent), lineWidth: 2)
                // Rule-of-thirds style guides at 25/50/75%.
                for f in [0.25, 0.5, 0.75] {
                    var g = Path()
                    g.move(to: CGPoint(x: rect.minX + rect.width * f, y: rect.minY))
                    g.addLine(to: CGPoint(x: rect.minX + rect.width * f, y: rect.maxY))
                    g.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * f))
                    g.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * f))
                    ctx.stroke(g, with: .color(.white.opacity(0.18)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
        Color.clear.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                let a = CGPoint(x: origin.x + v.startLocation.x, y: origin.y + v.startLocation.y)
                let b = CGPoint(x: origin.x + v.location.x, y: origin.y + v.location.y)
                controller.area = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).integral
            })
        if let rect, rect.intersects(CGRect(origin: .zero, size: size)) {
            HStack(spacing: 8) {
                Text("\(Int(rect.width)) × \(Int(rect.height))").font(.system(size: 12).monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glass()
                if controller.canStart { recordButton }
            }
            .position(x: rect.midX, y: min(rect.maxY + 34, size.height - 30))
        } else {
            Text("Drag to select an area").font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glass()
                .position(x: size.width / 2, y: size.height / 2)
                .allowsHitTesting(false)
        }
    }

    var recordButton: some View {
        Button { controller.start() } label: {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text("Start recording")
            }
        }
        .recordGlassButton()
    }
}
