import AppKit
import SwiftUI

/// Debug-only: launch with `-PGComponentGallery YES` to see the floating recorder components
/// (picker toolbar, recording widget, countdown) over a colourful backdrop, without recording.
@MainActor
enum ComponentGallery {
    static func showIfRequested() {
        guard UserDefaults.standard.bool(forKey: "PGComponentGallery") else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Component Gallery"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GalleryView().preferredColorScheme(.light))
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct GalleryView: View {
    let countdown = CountdownModel()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.75, green: 0.83, blue: 1), Color(red: 1, green: 0.83, blue: 0.9)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 30) {
                PickerToolbar(controller: AppModel.shared.recorder).frame(width: 640, height: 68)
                HStack(spacing: 40) {
                    ControlWidget(controller: AppModel.shared.recorder).frame(width: 300, height: 50)
                    CountdownView(model: countdown)
                }
            }
        }
        .frame(width: 900, height: 560)
    }
}
