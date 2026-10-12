import AppKit
import SwiftUI

/// Floating recording controls: time, pause/resume, stop, restart, delete. Never captured.
@MainActor
final class ControlWidgetWindow {
    private let panel: OverlayPanel

    init(controller: RecorderController) {
        let main = NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 300, height: 46)
        panel = OverlayPanel(frame: NSRect(x: main.frame.midX - size.width / 2, y: main.frame.minY + 40, width: size.width, height: size.height),
                             level: .floating)
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: ControlWidget(controller: controller).preferredColorScheme(.dark))
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.close() }
}

struct ControlWidget: View {
    var controller: RecorderController

    var body: some View {
        HStack(spacing: 4) {
            Button { controller.stop() } label: {
                RoundedRectangle(cornerRadius: 3).fill(.red).frame(width: 12, height: 12)
            }
            .buttonStyle(IconButtonStyle())
            .help("Finish recording (⌥⌘↩)")
            Text(timeString(controller.elapsed))
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .frame(width: 64, alignment: .leading)
                .foregroundStyle(controller.isPaused ? Theme.secondaryText : .primary)
            MicMeter(level: controller.micLevel).frame(width: 34, height: 14)
            Spacer()
            Button { controller.togglePause() } label: { Image(systemName: controller.isPaused ? "play.fill" : "pause.fill") }
                .buttonStyle(IconButtonStyle(active: controller.isPaused))
                .help(controller.isPaused ? "Resume (⌥⌘P)" : "Pause (⌥⌘P)")
            Button { controller.addFlag() } label: { Image(systemName: "flag") }
                .buttonStyle(IconButtonStyle()).help("Add flag (⌃⌥⌘F)")
            Button { controller.restart() } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(IconButtonStyle()).help("Restart")
            Button { controller.deleteRecording() } label: { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle()).help("Delete recording")
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
    }

    func timeString(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct MicMeter: View {
    var level: Float
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { i in
                    let on = Float(i) / 6 < level
                    RoundedRectangle(cornerRadius: 1)
                        .fill(on ? Color.green : Color.white.opacity(0.15))
                        .frame(height: g.size.height * (0.4 + 0.6 * CGFloat(i) / 5))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// Big translucent countdown number in the middle of the screen being recorded.
@MainActor
final class CountdownWindow {
    private let panel: OverlayPanel
    private let model = CountdownModel()

    init(frame: NSRect) {
        let size = NSSize(width: 220, height: 220)
        panel = OverlayPanel(frame: NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                             level: .screenSaver)
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
    }

    func show(number: Int) {
        model.number = number
        panel.orderFrontRegardless()
    }

    func close() { panel.close() }
}

@MainActor @Observable final class CountdownModel { var number = 3 }

struct CountdownView: View {
    var model: CountdownModel
    var body: some View {
        Text("\(model.number)")
            .font(.system(size: 110, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 200, height: 200)
            .background(Circle().fill(.black.opacity(0.55)))
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: model.number)
    }
}
