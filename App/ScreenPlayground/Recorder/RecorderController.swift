import AppKit
import AVFoundation
import Capture
import Foundation
import Observation
import PlaygroundCore

enum CaptureMode: String, CaseIterable, Identifiable {
    case display, window, area
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .display: return "display"
        case .window: return "macwindow"
        case .area: return "rectangle.dashed"
        }
    }
}

/// Drives the recording flow: picker → countdown → recording → editor.
@MainActor @Observable
final class RecorderController {
    enum State: Equatable { case idle, picking, countdown(Int), recording, finishing }

    private(set) var state: State = .idle
    var mode: CaptureMode = .display
    var selectedDisplay: CGDirectDisplayID?
    var selectedWindow: WindowInfo?
    /// Area in global CG points.
    var area: CGRect?
    var hoveredDisplay: CGDirectDisplayID?
    var hoveredWindow: WindowInfo?
    var windows: [WindowInfo] = []

    var microphones: [AVDeviceInfo] = []
    var cameras: [AVDeviceInfo] = []
    var microphoneID: String? { didSet { UserDefaults.standard.set(microphoneID, forKey: "rec.mic") } }
    var cameraID: String? { didSet { UserDefaults.standard.set(cameraID, forKey: "rec.camera") } }
    var captureSystemAudio = UserDefaults.standard.object(forKey: "rec.sysaudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(captureSystemAudio, forKey: "rec.sysaudio") }
    }
    var countdownSeconds = UserDefaults.standard.object(forKey: "rec.countdown") as? Int ?? 3 {
        didSet { UserDefaults.standard.set(countdownSeconds, forKey: "rec.countdown") }
    }
    var hideDesktopIcons = UserDefaults.standard.bool(forKey: "rec.hideIcons") {
        didSet { UserDefaults.standard.set(hideDesktopIcons, forKey: "rec.hideIcons") }
    }

    private(set) var session: RecordingSession?
    private(set) var elapsed: Double = 0
    private(set) var micLevel: Float = 0
    private(set) var isPaused = false
    var lastError: String?

    private var picker: PickerWindows?
    private var widget: ControlWidgetWindow?
    private var countdownWindow: CountdownWindow?
    private var tick: Timer?
    private var autoStopAt: Double?
    /// Annotations dropped by agents while recording; written next to the events on stop.
    private var marks: [RecordingMark] = []
    /// Set while an agent (not a person) owns the current recording.
    private(set) var automation: AutomationOptions?

    /// How an agent wants a recording made (see `ControlServer`).
    struct AutomationOptions {
        var microphoneID: String?
        var systemAudio = false
        var countdown = 0
        var maxDuration: Double?
        var name: String?
        var openEditor = false
        /// Where to save the project (defaults to the projects folder).
        var folder: URL?
        /// Cut stretches with no input longer than this when finishing.
        var cutIdle: Double?
    }

    init() {
        microphoneID = UserDefaults.standard.string(forKey: "rec.mic")
        cameraID = UserDefaults.standard.string(forKey: "rec.camera")
    }

    var isRecording: Bool { state == .recording }

    // MARK: Picker

    func showPicker(mode: CaptureMode? = nil) {
        guard state == .idle || state == .picking else { return }
        if !PermissionCenter.isGranted(.screenRecording) {
            Task { await PermissionCenter.request(.screenRecording) }
            AppModel.shared.showHome()
            return
        }
        if let mode { self.mode = mode }
        microphones = CaptureCatalog.microphones()
        cameras = CaptureCatalog.cameras()
        if let id = microphoneID, !microphones.contains(where: { $0.id == id }) { microphoneID = nil }
        if let id = cameraID, !cameras.contains(where: { $0.id == id }) { cameraID = nil }
        refreshWindows()
        let displays = CaptureCatalog.displays()
        if displays.count == 1 { selectedDisplay = displays[0].id }
        state = .picking
        if picker == nil { picker = PickerWindows(controller: self) }
        picker?.show()
        NSApp.activate()
    }

    func refreshWindows() { windows = CaptureCatalog.windows() }

    func cancelPicker() {
        picker?.hide()
        state = .idle
        selectedWindow = nil
        area = nil
    }

    var canStart: Bool {
        switch mode {
        case .display: return selectedDisplay != nil || hoveredDisplay != nil
        case .window: return selectedWindow != nil
        case .area: return (area?.width ?? 0) > 20 && (area?.height ?? 0) > 20
        }
    }

    var currentTarget: RecordingTarget? {
        switch mode {
        case .display: return (selectedDisplay ?? hoveredDisplay).map { .display($0) }
        case .window: return selectedWindow.map { .window($0.id) }
        case .area:
            guard let area, let d = CaptureCatalog.display(containing: area) else { return nil }
            return .area(d.id, area)
        }
    }

    // MARK: Recording

    func start() {
        guard let target = currentTarget else { return }
        picker?.hide()
        if case let .window(id) = target, let w = windows.first(where: { $0.id == id }) {
            NSRunningApplication(processIdentifier: w.pid)?.activate()
        }
        begin(target: target, countdown: countdownSeconds)
    }

    /// Records the main display immediately (URL scheme / automation).
    func quickRecord(mode: CaptureMode, countdown: Int?, duration: Double?) {
        guard state == .idle, mode == .display, let display = CaptureCatalog.displays().first else {
            showPicker(mode: mode)
            return
        }
        autoStopAt = duration
        begin(target: .display(display.id), countdown: countdown ?? countdownSeconds)
    }

    private func begin(target: RecordingTarget, countdown: Int) {
        Task {
            if countdown > 0 {
                let screenFrame = Self.nsFrame(for: target)
                countdownWindow = CountdownWindow(frame: screenFrame)
                for n in stride(from: countdown, through: 1, by: -1) {
                    state = .countdown(n)
                    countdownWindow?.show(number: n)
                    NSSound(named: "Tink")?.play()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                countdownWindow?.close()
                countdownWindow = nil
            }
            await startSession(target: target)
        }
    }

    private func startSession(target: RecordingTarget) async {
        do {
            _ = try await startSessionThrowing(target: target)
        } catch {
            AppModel.shared.presentError(error)
        }
    }

    private func startSessionThrowing(target: RecordingTarget) async throws -> URL {
        var options = RecordingOptions(target: target)
        if let automation {
            // Agents get exactly what they asked for, never the person's mic/camera defaults.
            options.microphoneID = automation.microphoneID
            options.cameraID = nil
            options.captureSystemAudio = automation.systemAudio
        } else {
            options.microphoneID = microphoneID
            options.cameraID = cameraID
            options.captureSystemAudio = captureSystemAudio
        }
        options.hideDesktopIcons = hideDesktopIcons
        if windows.isEmpty { refreshWindows() }
        let name = automation?.name ?? Self.recordingName(for: target, windows: windows)
        if automation?.folder == nil { try AppModel.shared.ensureStorage() }
        let url = ProjectBundle.uniqueURL(in: automation?.folder ?? AppModel.shared.projectsFolder, name: name)
        marks = []
        do {
            let session = try RecordingSession(options: options, bundleURL: url)
            session.onUnexpectedStop = { [weak self] _ in Task { @MainActor in self?.stop() } }
            try await session.start()
            self.session = session
            state = .recording
            isPaused = false
            widget = ControlWidgetWindow(controller: self)
            widget?.show()
            tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTick() }
            }
            return url
        } catch {
            state = .idle
            automation = nil
            lastError = error.localizedDescription
            throw error
        }
    }

    // MARK: Automation (agents)

    /// Starts recording immediately for an agent and returns the project URL once frames are flowing.
    func startAutomated(target: RecordingTarget, options: AutomationOptions) async throws -> URL {
        guard state == .idle else {
            throw ControlError("busy", "A recording is already in progress.", fix: "Run `pgctl record stop` or `pgctl record cancel` first.")
        }
        guard PermissionCenter.isGranted(.screenRecording) else {
            throw ControlError("permission", "Screen Recording permission is not granted.",
                               fix: "Open Screen Playground and allow Screen Recording in System Settings › Privacy & Security, then reopen the app.")
        }
        automation = options
        autoStopAt = options.maxDuration
        if case let .window(id) = target, let pid = CaptureCatalog.windows().first(where: { $0.id == id })?.pid {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        if options.countdown > 0 {
            let screenFrame = Self.nsFrame(for: target)
            countdownWindow = CountdownWindow(frame: screenFrame)
            for n in stride(from: options.countdown, through: 1, by: -1) {
                state = .countdown(n)
                countdownWindow?.show(number: n)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            countdownWindow?.close()
            countdownWindow = nil
        }
        return try await startSessionThrowing(target: target)
    }

    /// Adds an annotation at the current recording time; returns that time.
    @discardableResult
    func addMark(_ kind: RecordingMark.Kind, text: String? = nil, value: Double? = nil) throws -> Double {
        guard let session, state == .recording else {
            throw ControlError("not-recording", "Nothing is being recorded.", fix: "Start one with `pgctl record start`.")
        }
        let t = session.elapsed
        marks.append(RecordingMark(t: t, kind: kind, text: text, value: value))
        return t
    }

    /// Stops, finalizes and returns the project. Opens the editor only when asked.
    func finish(openEditor: Bool) async throws -> ProjectBundle {
        guard state == .recording, let session else {
            throw ControlError("not-recording", "Nothing is being recorded.")
        }
        state = .finishing
        tick?.invalidate()
        widget?.close()
        widget = nil
        defer {
            self.session = nil
            state = .idle
            automation = nil
            autoStopAt = nil
        }
        let bundle = try await session.stop()
        if !marks.isEmpty { try JSONLines.write(marks, to: bundle.marksFile) }
        try ProjectFactory.finalize(bundle, config: PresetStore.configForNewRecordings, cutIdle: automation?.cutIdle)
        AppModel.shared.reloadRecents()
        if openEditor { AppModel.shared.openProject(bundle.url) }
        return bundle
    }

    private func updateTick() {
        guard let session else { return }
        elapsed = session.elapsed
        micLevel = session.micLevel
        if let stopAt = autoStopAt, elapsed >= stopAt { autoStopAt = nil; stop() }
    }

    func togglePause() {
        guard let session, state == .recording else { return }
        if session.isPaused { session.resume() } else { session.pause() }
        isPaused = session.isPaused
    }

    func addFlag() { session?.addFlag() }

    /// Stop from the UI, hotkey or auto-stop. An agent's recording is finished by the agent's own
    /// `record stop` when possible; if a person stops it, it still finalizes (without the editor).
    func stop() {
        guard state == .recording, session != nil else { return }
        let openEditor = automation.map { $0.openEditor } ?? true
        Task {
            do {
                let bundle = try await finish(openEditor: openEditor)
                lastFinished = bundle.url
            } catch {
                AppModel.shared.presentError(error)
            }
        }
    }

    /// The most recent project finished by `stop()` (lets an agent find a recording a person stopped).
    private(set) var lastFinished: URL?

    func deleteRecording() {
        guard let session else { return }
        tick?.invalidate()
        widget?.close()
        widget = nil
        state = .finishing
        Task {
            await session.cancel()
            self.session = nil
            state = .idle
            automation = nil
            autoStopAt = nil
        }
    }

    func restart() {
        guard let session else { return }
        let target = session.options.target
        tick?.invalidate()
        widget?.close()
        widget = nil
        state = .finishing
        Task {
            await session.cancel()
            self.session = nil
            state = .idle
            begin(target: target, countdown: countdownSeconds)
        }
    }

    // MARK: Helpers

    static func recordingName(for target: RecordingTarget, windows: [WindowInfo]) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = f.string(from: Date())
        switch target {
        case let .display(id): return "\(CaptureCatalog.displays().first { $0.id == id }?.name ?? "Display") \(stamp)"
        case let .window(id): return "\(windows.first { $0.id == id }?.appName ?? "Window") \(stamp)"
        case .area: return "Area \(stamp)"
        }
    }

    /// AppKit frame (bottom-left origin) of the screen showing a target.
    static func nsFrame(for target: RecordingTarget) -> NSRect {
        let id: CGDirectDisplayID?
        switch target {
        case let .display(d), let .area(d, _): id = d
        case let .window(w): id = CaptureCatalog.windowFrame(w).flatMap { CaptureCatalog.display(containing: $0)?.id }
        }
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
        return (screen ?? NSScreen.main)?.frame ?? .zero
    }
}

/// Global hotkeys via Carbon (no third-party dependency).
import Carbon.HIToolbox

@MainActor
final class HotKeys {
    static let shared = HotKeys()
    private var refs: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]

    func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.actions[key]?() } }
            return noErr
        }, 1, &spec, nil, nil)

        // ⌥⌘↩ — open the picker, or stop if recording.
        add(id: 1, keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey | optionKey)) {
            let r = AppModel.shared.recorder
            if r.isRecording { r.stop() } else if r.state == .picking { r.start() } else { r.showPicker() }
        }
        // ⌃⌥⌘F — recording flag.
        add(id: 2, keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | optionKey | controlKey)) {
            AppModel.shared.recorder.addFlag()
        }
        // ⌥⌘P — pause / resume.
        add(id: 3, keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey)) {
            AppModel.shared.recorder.togglePause()
        }
    }

    private func add(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5350_4C47), id: id) // 'SPLG'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
        actions[id] = action
    }
}
