import AppKit
import Composition
import Export
import Media
import PlaygroundCore
import SwiftUI

/// Export dialog: format, size, fps, quality → file or clipboard, with progress.
struct ExportSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ExportSheet.loadSettings()
    @State private var progress: Double?
    @State private var cancel = CancelToken()
    @State private var result: URL?
    @State private var copied = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Export").font(.system(size: 20, weight: .bold))
                Spacer()
                if let size = model.snapshot?.canvasSize(shortSide: settings.resolution.rawValue) {
                    Text("\(size.width) × \(size.height) · \(durationLabel(model.duration))")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                }
            }
            if let result {
                done(result)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            } else if let progress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress).tint(Theme.accent)
                    HStack {
                        Text("Rendering… \(Int(progress * 100))%").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Button("Cancel") { cancel.cancel() }.buttonStyle(SmallButtonStyle())
                    }
                }
                .transition(.opacity)
            } else {
                form.transition(.opacity)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
        }
        .animation(Anim.easeOut(0.25), value: phase)
        .padding(24)
        .frame(width: 480)
        .preferredColorScheme(.light)
    }

    @ViewBuilder var form: some View {
        row("Format") {
            PillPicker(options: [ExportFormat.mp4, .gif, .prores], selection: $settings.format, label: { $0.label })
        }
        row("Size") {
            PillPicker(options: settings.format == .gif ? [.p720, .p1080] : ResolutionPreset.allCases, selection: $settings.resolution,
                       label: { $0.label })
        }
        row("Frame rate") {
            PillPicker(options: settings.format == .gif ? [15, 24, 30] : [24, 30, 60], selection: $settings.fps, label: { "\($0) fps" })
        }
        if settings.format == .mp4 {
            row("Quality") {
                PillPicker(options: ExportQuality.allCases, selection: $settings.quality, label: { $0.label })
            }
            row("Codec") {
                PillPicker(options: VideoCodec.allCases, selection: $settings.codec, label: { $0 == .h264 ? "H.264 (most compatible)" : "HEVC (smaller)" })
            }
        }
        if settings.format == .gif {
            row("Loop") {
                PillPicker(options: [0, 1], selection: $settings.gifLoopCount, label: { $0 == 0 ? "Forever" : "Once" })
            }
        }
        HStack {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            Button { run(toClipboard: true) } label: { Label("Copy to Clipboard", systemImage: "doc.on.clipboard") }
                .glassButton()
            Button { run(toClipboard: false) } label: { Label("Export to File", systemImage: "square.and.arrow.down") }
                .primaryGlassButton()
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 6)
    }

    func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
            content()
        }
    }

    /// Which of form / rendering / done is showing (drives the crossfade).
    var phase: Int { result != nil ? 2 : (progress != nil ? 1 : 0) }

    @ViewBuilder func done(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(copied ? "Copied to clipboard — paste it into Messages, Slack or Mail." : "Exported \(url.lastPathComponent)",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: url)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + " · " + url.deletingLastPathComponent().path)
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(2)
            }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Open") { NSWorkspace.shared.open(url) }
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                Spacer()
                Button("Done") { dismiss() }.primaryGlassButton().keyboardShortcut(.defaultAction)
            }
        }
    }

    func run(toClipboard: Bool) {
        guard let project = model.project else { return }
        ExportSheet.saveSettings(settings)
        let base = model.doc.name.replacingOccurrences(of: "/", with: "-")
        let url: URL
        if toClipboard {
            ClipboardExport.cleanUp()
            url = ClipboardExport.folder.appendingPathComponent("\(base).\(settings.format.fileExtension)")
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(base).\(settings.format.fileExtension)"
            panel.directoryURL = AppModel.shared.exportsFolder
            panel.allowedContentTypes = [settings.format == .gif ? .gif : (settings.format == .prores ? .quickTimeMovie : .mpeg4Movie)]
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        error = nil
        progress = 0
        cancel = CancelToken()
        let exporter = Exporter(project: project, document: model.doc, settings: settings)
        let token = cancel
        ExportActivity.running += 1
        Task {
            defer { ExportActivity.running -= 1 }
            do {
                try await exporter.run(to: url, cancel: token) { p in
                    Task { @MainActor in progress = p.fraction }
                }
                if toClipboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                    copied = true
                }
                result = url
                NSSound(named: "Glass")?.play()
            } catch ExportError.cancelled {
                progress = nil
            } catch {
                progress = nil
                self.error = error.localizedDescription
            }
        }
    }

    static func loadSettings() -> ExportSettings {
        guard let data = UserDefaults.standard.data(forKey: "export.settings"),
              let s = try? JSONDecoder().decode(ExportSettings.self, from: data) else { return ExportSettings() }
        return s
    }

    static func saveSettings(_ s: ExportSettings) {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: "export.settings") }
    }
}
