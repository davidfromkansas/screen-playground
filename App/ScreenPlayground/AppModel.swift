import AppKit
import Capture
import Foundation
import Observation
import PlaygroundCore
import SwiftUI
import Timeline

/// App-wide coordinator: projects, recording and windows.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let recorder = RecorderController()
    private(set) var recents: [URL] = []
    private var editorWindows: [URL: NSWindowController] = [:]
    private var homeWindow: NSWindowController?

    var projectsFolder: URL {
        let url = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Playground/Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var exportsFolder: URL {
        let url = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Playground", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() { reloadRecents() }

    func reloadRecents() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: projectsFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        recents = items.filter { $0.pathExtension == ProjectBundle.fileExtension }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
    }

    // MARK: Windows

    func showHome() {
        if homeWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Screen Playground"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HomeView().environment(self).preferredColorScheme(.dark))
            window.center()
            window.setFrameAutosaveName("HomeWindow")
            homeWindow = NSWindowController(window: window)
        }
        reloadRecents()
        homeWindow?.showWindow(nil)
        homeWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func openProject(_ url: URL) {
        if let existing = editorWindows[url] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let controller = EditorWindowController(url: url) { [weak self] in self?.editorWindows[url] = nil }
        editorWindows[url] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        homeWindow?.close()
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(exportedAs: "dev.screenplayground.project")]
        panel.directoryURL = projectsFolder
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url { openProject(url) }
    }

    /// Creates a project from an existing MP4/MOV (no cursor data).
    func importVideoPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let bundle = try await ProjectFactory.importVideo(url, into: projectsFolder)
                openProject(bundle.url)
            } catch {
                presentError(error)
            }
        }
    }

    func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    // MARK: URL scheme

    func handle(url: URL) {
        guard url.scheme == "screen-playground" else {
            if url.pathExtension == ProjectBundle.fileExtension { openProject(url) }
            return
        }
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ name: String) -> String? { params.first { $0.name == name }?.value }
        switch url.host {
        case "record-display": recorder.quickRecord(mode: .display, countdown: param("countdown").flatMap(Int.init),
                                                    duration: param("duration").flatMap(Double.init))
        case "record-window": recorder.showPicker(mode: .window)
        case "record-area": recorder.showPicker(mode: .area)
        case "new-recording": recorder.showPicker()
        case "finish-recording": recorder.stop()
        case "cancel-recording": recorder.deleteRecording()
        case "restart-recording": recorder.restart()
        case "toggle-pause": recorder.togglePause()
        case "open-projects-folder": NSWorkspace.shared.open(projectsFolder)
        case "open-settings": NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        default: showHome()
        }
    }

    // MARK: Recovery

    func recoverUnfinishedRecordings() {
        let pending = RecoveryScanner.unfinishedBundles(in: projectsFolder)
        guard !pending.isEmpty else { return }
        Task {
            for bundle in pending where await RecoveryScanner.recover(bundle) {
                try? ProjectFactory.finalize(bundle)
                let alert = NSAlert()
                alert.messageText = "Recovered a recording"
                alert.informativeText = "\"\(bundle.url.deletingPathExtension().lastPathComponent)\" didn't finish last time. Everything up to the last couple of seconds was saved."
                alert.addButton(withTitle: "Open")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { openProject(bundle.url) }
            }
            reloadRecents()
        }
    }
}

/// Turns a finished recording into an editable project (slices + auto-zooms).
enum ProjectFactory {
    static func finalize(_ bundle: ProjectBundle, config: ProjectConfig? = nil) throws {
        let manifest = try bundle.loadManifest()
        var doc = (try? bundle.loadDocument()) ?? ProjectDocument()
        if let config { doc.config = config }
        doc.name = bundle.url.deletingPathExtension().lastPathComponent
        if doc.scene.slices.isEmpty || doc.scene.slices.allSatisfy({ $0.source.duration <= 0 }) {
            doc.scene.slices = Edits.initialSlices(duration: manifest.duration)
        }
        let events = bundle.loadEvents()
        let clicks = autoZoomClicks(events: events, manifest: manifest)
        doc.scene = AutoZoom.regenerate(doc.scene, clicks: clicks, duration: manifest.duration, config: doc.config.autoZoom)
        try bundle.saveDocument(doc, keepBackup: false)
    }

    static func autoZoomClicks(events: RecordingEvents, manifest: RecordingManifest) -> [AutoZoom.Click] {
        var gi = 0
        return events.downClicks.filter { $0.button == .left }.map { c in
            var rect = manifest.captureRect
            if !events.geometry.isEmpty {
                while gi + 1 < events.geometry.count, events.geometry[gi + 1].t <= c.t { gi += 1 }
                if events.geometry[gi].t <= c.t { rect = events.geometry[gi].rect }
            }
            return AutoZoom.Click(t: c.t, point: rect.normalize(x: c.x, y: c.y))
        }
    }

    static func importVideo(_ video: URL, into folder: URL) async throws -> ProjectBundle {
        let name = video.deletingPathExtension().lastPathComponent
        let bundle = try ProjectBundle.create(at: ProjectBundle.uniqueURL(in: folder, name: name))
        let dest = bundle.recordingFolder.appendingPathComponent("display.\(video.pathExtension.lowercased())")
        try FileManager.default.copyItem(at: video, to: dest)
        let asset = AVURLAssetLoader(url: dest)
        let (duration, size) = try await asset.info()
        var manifest = RecordingManifest()
        manifest.status = .finished
        manifest.target = .imported
        manifest.targetName = name
        manifest.duration = duration
        manifest.captureRect = ScreenRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2)
        manifest.channels = [ChannelInfo(kind: .display, file: dest.lastPathComponent, pixelWidth: Int(size.width), pixelHeight: Int(size.height))]
        try bundle.saveManifest(manifest)
        var doc = ProjectDocument()
        doc.name = name
        doc.scene.slices = Edits.initialSlices(duration: duration)
        doc.config.cursor.hidden = true
        try bundle.saveDocument(doc, keepBackup: false)
        return bundle
    }
}

import AVFoundation

struct AVURLAssetLoader {
    let url: URL
    func info() async throws -> (Double, CGSize) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let r = CGRect(origin: .zero, size: size).applying(transform)
        return (duration, CGSize(width: abs(r.width), height: abs(r.height)))
    }
}
