import AppKit
import Capture
import Export
import PlaygroundCore
import SwiftUI

@main
struct ScreenPlaygroundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some SwiftUI.Scene {
        Settings {
            SettingsView().environment(AppModel.shared).preferredColorScheme(.light)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording…") { AppModel.shared.recorder.showPicker() }
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                Button("Open Project…") { AppModel.shared.openProjectPanel() }.keyboardShortcut("o")
                Button("Create Project from Video…") { AppModel.shared.importVideoPanel() }
                Button("Show Projects") { AppModel.shared.showHome() }.keyboardShortcut("0", modifiers: [.command, .shift])
            }
            CommandMenu("Record") {
                Button("Record Display") { AppModel.shared.recorder.showPicker(mode: .display) }
                Button("Record Window") { AppModel.shared.recorder.showPicker(mode: .window) }
                Button("Record Area") { AppModel.shared.recorder.showPicker(mode: .area) }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    /// True when the app is only hosting unit tests: skip all UI and system setup.
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isHostingTests { return }
        MainActor.assumeIsolated {
            NSApp.appearance = NSAppearance(named: .aqua)
            statusItem = StatusItemController()
            HotKeys.shared.register()
            AppModel.shared.recoverUnfinishedRecordings()
            ControlServer.shared.start()
            if !ProcessInfo.processInfo.arguments.contains("-PGNoHome") { AppModel.shared.showHome() }
            ComponentGallery.showIfRequested()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach { AppModel.shared.handle(url: $0) } }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppModel.shared.showHome() } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        if !Self.isHostingTests { ControlServer.shared.stop() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard AppModel.shared.recorder.isRecording else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "A recording is in progress"
            alert.informativeText = "Finish the recording before quitting, or quit and discard it."
            alert.addButton(withTitle: "Finish Recording")
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                AppModel.shared.recorder.stop()
                return .terminateCancel
            case .alertSecondButtonReturn: return .terminateNow
            default: return .terminateCancel
            }
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        StatusItemController.makeMenu(includeQuit: false)
    }
}

/// Menu-bar icon: shows recording time while recording; click to stop.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?

    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Screen Playground")
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let r = AppModel.shared.recorder
        if r.isRecording {
            let s = Int(r.elapsed)
            item.button?.image = NSImage(systemSymbolName: r.isPaused ? "pause.circle.fill" : "stop.circle.fill", accessibilityDescription: "Stop")
            item.button?.contentTintColor = .systemRed
            item.button?.title = String(format: " %d:%02d", s / 60, s % 60)
        } else {
            item.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Screen Playground")
            item.button?.contentTintColor = nil
            item.button?.title = ""
        }
    }

    @objc private func clicked() {
        let r = AppModel.shared.recorder
        if r.isRecording {
            r.stop()
            return
        }
        item.menu = Self.makeMenu(includeQuit: true)
        item.button?.performClick(nil)
        item.menu = nil
    }

    static func makeMenu(includeQuit: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionItem("New Recording…", key: "\r", modifiers: [.command, .option]) { AppModel.shared.recorder.showPicker() })
        menu.addItem(ActionItem("Record Display") { AppModel.shared.recorder.showPicker(mode: .display) })
        menu.addItem(ActionItem("Record Window") { AppModel.shared.recorder.showPicker(mode: .window) })
        menu.addItem(ActionItem("Record Area") { AppModel.shared.recorder.showPicker(mode: .area) })
        menu.addItem(.separator())
        let recents = AppModel.shared.recents.prefix(6)
        if !recents.isEmpty {
            for url in recents {
                menu.addItem(ActionItem(url.deletingPathExtension().lastPathComponent) { AppModel.shared.openProject(url) })
            }
            menu.addItem(.separator())
        }
        menu.addItem(ActionItem("Show Projects") { AppModel.shared.showHome() })
        menu.addItem(ActionItem("Open Clipboard Exports") { NSWorkspace.shared.open(ClipboardExport.folder) })
        if includeQuit {
            menu.addItem(.separator())
            menu.addItem(ActionItem("Settings…", key: ",") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil); NSApp.activate() })
            menu.addItem(ActionItem("Quit Screen Playground", key: "q") { NSApp.terminate(nil) })
        }
        return menu
    }
}

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("rec.countdown") private var countdown = 3
    @AppStorage("rec.hideIcons") private var hideIcons = false

    var body: some View {
        Form {
            Section("Recording") {
                Picker("Countdown", selection: $countdown) {
                    Text("None").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                Toggle("Hide desktop icons while recording", isOn: $hideIcons)
                LabeledContent("Projects folder") {
                    Button(app.projectsFolder.path) { NSWorkspace.shared.open(app.projectsFolder) }.buttonStyle(.link)
                }
            }
            Section("Shortcuts") {
                LabeledContent("Start / stop recording", value: "⌥⌘↩")
                LabeledContent("Pause / resume", value: "⌥⌘P")
                LabeledContent("Add recording flag", value: "⌃⌥⌘F")
                LabeledContent("Editor", value: "Space play · C split · X ripple delete · Z zoom · M mask · ⌘C copy frame")
            }
            Section("Permissions") {
                ForEach(Permission.allCases) { p in
                    LabeledContent(p.title) {
                        if PermissionCenter.isGranted(p) { Text("Allowed").foregroundStyle(.green) }
                        else { Button("Open System Settings") { NSWorkspace.shared.open(p.settingsURL) } }
                    }
                }
            }
            Section("About") {
                Text("Screen Playground is free for everyone. No accounts, no watermarks, no tracking.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
    }
}
