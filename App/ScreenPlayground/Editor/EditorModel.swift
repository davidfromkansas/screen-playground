@preconcurrency import AVFoundation
import AppKit
import Composition
import Export
import Foundation
import Media
import Observation
import PlaygroundCore
import Timeline

enum EditorPanel: String, CaseIterable, Identifiable {
    case background, cursor, camera, audio, animation, shortcuts

    var id: String { rawValue }
    var title: String {
        switch self {
        case .background: return "Background"
        case .cursor: return "Cursor"
        case .camera: return "Camera"
        case .audio: return "Audio"
        case .animation: return "Animations"
        case .shortcuts: return "Keyboard Shortcuts"
        }
    }
    var icon: String {
        switch self {
        case .background: return "photo"
        case .cursor: return "cursorarrow"
        case .camera: return "person.crop.square"
        case .audio: return "speaker.wave.2"
        case .animation: return "point.topleft.down.to.point.bottomright.curvepath"
        case .shortcuts: return "command"
        }
    }
}

enum EditorSelection: Equatable {
    case slice(ItemID), zoom(ItemID), mask(ItemID)
}

/// State of one open project in the editor.
@MainActor @Observable
final class EditorModel {
    let url: URL
    let bundle: ProjectBundle
    private(set) var project: LoadedProject?
    private(set) var loadError: String?
    private(set) var history = EditHistory(initial: ProjectDocument())
    private(set) var snapshot: RenderSnapshot?
    /// Bumped whenever the preview must redraw (document or time change).
    private(set) var renderGeneration = 0

    var panel: EditorPanel = .background
    var selection: EditorSelection?
    var exportPresented = false
    var timelineZoom: Double = 1 // multiplier on fit-to-width

    // Playback
    private(set) var time: Double = 0
    private(set) var isPlaying = false
    var loopPlayback = false
    private var playStartHost: Double = 0
    private var playStartTime: Double = 0
    private var displayTimer: Timer?
    private var audioPlayer: AVPlayer?
    private var audioDirty = true
    private var saveTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        bundle = ProjectBundle(url: url)
        Task { await load() }
    }

    var doc: ProjectDocument { history.current }
    var duration: Double { snapshot?.duration ?? 0 }
    var hasCamera: Bool { project?.cameraURL != nil }
    var hasKeystrokes: Bool { !(project?.events.keys.isEmpty ?? true) }
    var recordingDuration: Double { project?.manifest.duration ?? 0 }

    func load() async {
        do {
            let p = try await LoadedProject.load(bundle)
            project = p
            history.reset(p.document)
            snapshot = p.snapshot()
            time = min(p.document.editor.playheadSource, snapshot?.duration ?? 0)
            renderGeneration += 1
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Editing

    /// Applies a change as one undoable step. Slider drags pass `coalesce: true`.
    func update(_ name: String, coalesce: Bool = false, _ change: (inout ProjectDocument) -> Void) {
        var d = history.current
        change(&d)
        guard d != history.current else { return }
        let slicesChanged = d.scene.slices != history.current.scene.slices || d.config.audio != history.current.config.audio
        history.commit(d, name: name, coalesce: coalesce)
        if slicesChanged { audioDirty = true }
        documentChanged()
    }

    /// Runs a throwing scene edit; failures (too short, out of range) are ignored with a beep.
    func edit(_ name: String, coalesce: Bool = false, _ change: (Scene) throws -> Scene) {
        do {
            let s = try change(doc.scene)
            update(name, coalesce: coalesce) { $0.scene = s }
        } catch {
            NSSound.beep()
        }
    }

    func undo() {
        guard history.undo() != nil else { return }
        audioDirty = true
        documentChanged()
    }

    func redo() {
        guard history.redo() != nil else { return }
        audioDirty = true
        documentChanged()
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    private func documentChanged() {
        guard let project, let current = snapshot else { return }
        let d = doc
        // Rebuild motion off the main thread; latest edit wins.
        snapshotTask?.cancel()
        snapshotTask = Task { [events = project.events] in
            let next = await Task.detached(priority: .userInitiated) { current.updating(document: d, events: events) }.value
            guard !Task.isCancelled else { return }
            self.snapshot = next
            self.time = min(self.time, next.duration)
            self.renderGeneration += 1
        }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func save() {
        var d = doc
        if let src = snapshot?.timeMap.source(at: OutputTime(time)) { d.editor.playheadSource = src.time.seconds }
        d.editor.openPanel = panel.rawValue
        try? bundle.saveDocument(d)
    }

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update("Rename") { $0.name = trimmed }
    }

    // MARK: Playback

    func seek(_ t: Double) {
        time = min(max(t, 0), duration)
        renderGeneration += 1
        if isPlaying {
            playStartTime = time
            playStartHost = HostClock.now()
            syncAudio(force: true)
        }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard duration > 0 else { return }
        if time >= duration - 0.01 { time = 0 }
        isPlaying = true
        playStartTime = time
        playStartHost = HostClock.now()
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        RunLoop.main.add(displayTimer!, forMode: .common)
        Task { await prepareAudio(); syncAudio(force: true); audioPlayer?.play() }
    }

    func pause() {
        isPlaying = false
        displayTimer?.invalidate()
        displayTimer = nil
        audioPlayer?.pause()
        renderGeneration += 1
    }

    private func advance() {
        guard isPlaying else { return }
        var t = playStartTime + (HostClock.now() - playStartHost)
        if t >= duration {
            if loopPlayback {
                t = 0
                playStartTime = 0
                playStartHost = HostClock.now()
                syncAudio(force: true)
            } else {
                time = duration
                pause()
                return
            }
        }
        time = t
        renderGeneration += 1
        syncAudio(force: false)
    }

    private func prepareAudio() async {
        guard audioDirty, let project else { return }
        audioDirty = false
        guard let result = try? await AudioCompositionBuilder.build(document: doc, sources: project.audioSources,
                                                                    backgroundMusic: LoadedProject.backgroundMusicURL(for: doc)),
              result.hasAudio else {
            audioPlayer = nil
            return
        }
        let item = AVPlayerItem(asset: result.composition)
        item.audioMix = result.audioMix
        item.audioTimePitchAlgorithm = .spectral
        if let player = audioPlayer { player.replaceCurrentItem(with: item) } else { audioPlayer = AVPlayer(playerItem: item) }
    }

    private func syncAudio(force: Bool) {
        guard let player = audioPlayer else { return }
        let current = player.currentTime().seconds
        if force || abs(current - time) > 0.08 {
            player.seek(to: CMTime(seconds: time, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if isPlaying, player.rate == 0 { player.play() }
    }

    func step(_ delta: Double) { seek(time + delta) }

    // MARK: Convenience edits

    func splitAtPlayhead() { edit("Split") { try Edits.split($0, at: OutputTime(time)) } }
    func rippleDeleteAtPlayhead() { edit("Delete") { try Edits.rippleDelete($0, at: OutputTime(time)) } }

    func deleteSelection() {
        switch selection {
        case let .slice(id): edit("Delete clip") { try Edits.remove($0, sliceID: id) }
        case let .zoom(id): update("Remove zoom") { $0.scene = Edits.removeZoom($0.scene, id: id) }
        case let .mask(id): update("Remove mask") { $0.scene.masks.removeAll { $0.id == id } }
        case nil: return
        }
        selection = nil
    }

    func addZoom(at t: Double? = nil) {
        do {
            let (scene, id) = try Edits.addZoom(doc.scene, at: OutputTime(t ?? time), level: doc.config.autoZoom.defaultLevel)
            update("Add zoom") { $0.scene = scene }
            selection = .zoom(id)
        } catch { NSSound.beep() }
    }

    func addMask(at t: Double? = nil, kind: MaskKind = .blur) {
        guard let snap = snapshot, let src = snap.timeMap.source(at: OutputTime(t ?? time)) else { return }
        let mask = MaskRange(source: SourceRange(src.time.seconds, min(src.time.seconds + 3, recordingDuration)), kind: kind)
        update("Add mask") { $0.scene.masks.append(mask) }
        selection = .mask(mask.id)
    }

    func regenerateAutoZooms() {
        guard let project else { return }
        let clicks = ProjectFactory.autoZoomClicks(events: project.events, manifest: project.manifest)
        update("Regenerate zooms") {
            $0.scene = AutoZoom.regenerate($0.scene, clicks: clicks, duration: project.manifest.duration, config: $0.config.autoZoom)
        }
    }

    func removeAllZooms() { update("Remove all zooms") { $0.scene.zooms.removeAll() } }

    func close() {
        pause()
        save()
        PresetStore.rememberLast(doc.config)
        audioPlayer = nil
    }
}
