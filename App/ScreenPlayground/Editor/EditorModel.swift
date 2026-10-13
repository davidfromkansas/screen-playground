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
    case slice(ItemID), zoom(ItemID), mask(ItemID), caption(ItemID)
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
    /// Source frame inside each zoom, for the manual-target picker.
    private(set) var zoomFrames: [ItemID: NSImage] = [:]

    // Playback
    private(set) var time: Double = 0
    private(set) var isPlaying = false
    var loopPlayback = false
    private var playStartHost: Double = 0
    private var playStartTime: Double = 0
    private var displayTimer: Timer?
    private var audioPlayer: AVPlayer?
    private var audioDirty = true
    private var audioStarted = false
    private var lastCoalescedEdit: Double = 0
    private var audioTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        bundle = ProjectBundle(url: url)
        Task { await load() }
    }

    var doc: ProjectDocument { history.current }
    var sourceAspect: Double {
        guard let p = project, p.sourcePixelSize.height > 0 else { return 16.0 / 9 }
        return Double(p.sourcePixelSize.width / p.sourcePixelSize.height)
    }
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
            if UserDefaults.standard.bool(forKey: "PGOpenExport") { exportPresented = true } // debug/screenshot hook
            if UserDefaults.standard.bool(forKey: "PGOpenCrop") { beginCrop() } // debug/screenshot hook
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
        let editedZoom = zoomBeingEdited(old: history.current, new: d)
        // Merge into the previous step only during one continuous drag (rapid successive changes).
        let now = HostClock.now()
        let continuous = coalesce && now - lastCoalescedEdit < 0.6
        lastCoalescedEdit = coalesce ? now : 0
        history.commit(d, name: name, coalesce: continuous)
        if let editedZoom { showZoom(editedZoom) }
        if slicesChanged {
            audioDirty = true
            refreshAudioIfPlaying()
        }
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

    /// The zoom whose look (level, target, mode, style) just changed, if any.
    private func zoomBeingEdited(old: ProjectDocument, new: ProjectDocument) -> ItemID? {
        for z in new.scene.zooms {
            guard let before = old.scene.zooms.first(where: { $0.id == z.id }) else { continue }
            if before.level != z.level || before.manualTarget != z.manualTarget || before.mode != z.mode || before.style != z.style {
                return z.id
            }
        }
        return nil
    }

    /// Moves the playhead to where a zoom has fully settled, so the preview shows its real result.
    func showZoom(_ id: ItemID) {
        guard !isPlaying, let z = doc.scene.zooms.first(where: { $0.id == id }) else { return }
        let ranges = TimeMap(slices: doc.scene.slices).outputRanges(for: z.source)
        guard let r = ranges.first else { return }
        let settled = r.start.seconds + min(max(r.duration * 0.6, 0), 1.0)
        let fullySettled = time >= r.start.seconds + min(r.duration * 0.6, 1.0) && time < r.end.seconds
        if !fullySettled { seek(settled) }
    }

    /// Loads the recorded frame in the middle of a zoom for its target picker.
    // MARK: Crop mode

    /// The crop being edited (normalized to the full recording); non-nil while crop mode is on.
    var cropDraft: NormRect?
    /// The full, uncropped frame at the playhead, shown while cropping.
    private(set) var cropFrame: NSImage?
    var isCropping: Bool { cropDraft != nil }

    func beginCrop() {
        if isPlaying { togglePlay() }
        selection = nil
        cropDraft = doc.config.output.crop
        cropFrame = nil
        guard let p = project, let url = p.displayURL else { return }
        let source = snapshot?.timeMap.source(at: OutputTime(time))?.time.seconds ?? 0
        Task {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.maximumSize = CGSize(width: 2400, height: 2400)
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
            if let (cg, _) = try? await gen.image(at: CMTime(seconds: source, preferredTimescale: 600)), isCropping {
                cropFrame = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }

    func commitCrop() {
        guard let draft = cropDraft else { return }
        if draft != doc.config.output.crop { update("Crop") { $0.config.output.crop = draft } }
        cropDraft = nil
        cropFrame = nil
    }

    func cancelCrop() {
        cropDraft = nil
        cropFrame = nil
    }

    func loadZoomFrame(_ id: ItemID) async {
        guard zoomFrames[id] == nil, let p = project, let url = p.displayURL,
              let z = doc.scene.zooms.first(where: { $0.id == id }) else { return }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let mid = (z.source.start.seconds + z.source.end.seconds) / 2
        if let (cg, _) = try? await gen.image(at: CMTime(seconds: mid, preferredTimescale: 600)) {
            zoomFrames[id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }

    /// Clears the selection if its item no longer exists (deleted, undone).
    private func validateSelection() {
        switch selection {
        case let .slice(id)?: if !doc.scene.slices.contains(where: { $0.id == id }) { selection = nil }
        case let .zoom(id)?: if !doc.scene.zooms.contains(where: { $0.id == id }) { selection = nil }
        case let .mask(id)?: if !doc.scene.masks.contains(where: { $0.id == id }) { selection = nil }
        case let .caption(id)?: if !doc.scene.captions.contains(where: { $0.id == id }) { selection = nil }
        case nil: break
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
        validateSelection()
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
        audioTask?.cancel()
        audioTask = Task {
            await prepareAudio()
            guard isPlaying else { return }
            syncAudio(force: true)
            audioPlayer?.play()
        }
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
        // Once audio is actually running it is the master clock; before that (and with no audio) use host time.
        var t: Double
        if let player = audioPlayer, player.rate > 0, player.currentItem?.status == .readyToPlay, audioStarted {
            t = player.currentTime().seconds
        } else {
            t = playStartTime + (HostClock.now() - playStartHost)
            if let player = audioPlayer, player.rate > 0, abs(player.currentTime().seconds - t) < 0.15 { audioStarted = true }
        }
        if t >= duration {
            if loopPlayback {
                t = 0
                playStartTime = 0
                playStartHost = HostClock.now()
                audioStarted = false
                syncAudio(force: true)
            } else {
                time = duration
                pause()
                return
            }
        }
        time = t
        renderGeneration += 1
    }

    private func prepareAudio() async {
        guard audioDirty, let project else { return }
        audioDirty = false
        let music = LoadedProject.backgroundMusicURL(for: doc)
        let result: AudioCompositionBuilder.Result
        do {
            result = try await AudioCompositionBuilder.build(document: doc, sources: project.audioSources, backgroundMusic: music)
        } catch {
            NSLog("Screen Playground: audio preview unavailable: \(error)")
            audioPlayer = nil
            return
        }
        guard result.hasAudio else {
            audioPlayer = nil
            return
        }
        let item = AVPlayerItem(asset: result.composition)
        item.audioMix = result.audioMix
        item.audioTimePitchAlgorithm = .spectral
        if let player = audioPlayer { player.replaceCurrentItem(with: item) } else { audioPlayer = AVPlayer(playerItem: item) }
        audioPlayer?.automaticallyWaitsToMinimizeStalling = false
    }

    /// Seeks the audio to the video time. Called on play, seek and loop only (never every frame:
    /// constant re-seeking makes audio choppy).
    private func syncAudio(force: Bool) {
        guard let player = audioPlayer else { return }
        if force {
            audioStarted = false
            player.seek(to: CMTime(seconds: time, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if isPlaying, player.rate == 0 { player.play() }
    }

    /// Rebuilds the audio mix after an edit; if playing, picks up seamlessly at the current time.
    private func refreshAudioIfPlaying() {
        guard isPlaying else { return }
        audioTask?.cancel()
        audioTask = Task {
            await prepareAudio()
            guard !Task.isCancelled, isPlaying else { return }
            syncAudio(force: true)
            audioPlayer?.play()
        }
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
        case let .caption(id): update("Remove caption") { $0.scene = Edits.removeCaption($0.scene, id: id) }
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

    func addCaption(at t: Double? = nil) {
        guard let snap = snapshot, let src = snap.timeMap.source(at: OutputTime(t ?? time)) else { return }
        let range = SourceRange(src.time.seconds, min(src.time.seconds + 3, recordingDuration))
        guard range.duration > 0.3 else { NSSound.beep(); return }
        var newID: ItemID?
        update("Add caption") { doc in
            let (scene, id) = Edits.addCaption(doc.scene, source: range, text: "Caption")
            doc.scene = scene
            newID = id
        }
        if let newID { selection = .caption(newID) }
    }

    /// Moves or resizes a zoom (output times). Zooms stay side by side: the result is clamped between
    /// the neighbouring zooms, and a whole-block move keeps its length.
    func moveZoom(_ id: ItemID, outputStart start0: Double, outputEnd end0: Double) {
        let map = TimeMap(slices: doc.scene.slices)
        guard let zoom = doc.scene.zooms.first(where: { $0.id == id }),
              let first = map.outputRanges(for: zoom.source).first, let last = map.outputRanges(for: zoom.source).last else { return }
        let others = doc.scene.zooms.filter { $0.id != id }.compactMap { z -> (Double, Double)? in
            let r = map.outputRanges(for: z.source)
            guard let a = r.first, let b = r.last else { return nil }
            return (a.start.seconds, b.end.seconds)
        }
        let lo = others.filter { $0.1 <= first.start.seconds + 0.001 }.map(\.1).max() ?? 0
        let hi = others.filter { $0.0 >= last.end.seconds - 0.001 }.map(\.0).min() ?? map.duration
        let len = end0 - start0
        let movingWhole = abs(len - (last.end.seconds - first.start.seconds)) < 0.0001
        var start = max(start0, lo), end = min(end0, hi)
        if movingWhole {
            start = min(max(start0, lo), max(hi - len, lo))
            end = min(start + len, hi)
        }
        update("Move zoom", coalesce: true) { doc in
            guard let i = doc.scene.zooms.firstIndex(where: { $0.id == id }),
                  let s = map.source(at: OutputTime(start))?.time, let e = map.source(at: OutputTime(end))?.time,
                  e.seconds - s.seconds >= Edits.minimumZoomDuration else { return }
            doc.scene.zooms[i].source = SourceRange(s, e)
        }
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
