import AppKit
import Foundation
import Observation

/// Checks the website's update feed, downloads new versions in the background and installs on restart.
/// Sends nothing about the user: it's a plain request for a public JSON file.
@MainActor @Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case downloading(UpdateFeed, Double)
        /// Downloaded and verified; installs on restart (or quit).
        case ready(UpdateFeed, URL)
        /// Found but couldn't be downloaded or verified; offer the website instead.
        case failed(UpdateFeed?, String)
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: Keys.lastChecked) as? Date
    /// The ready/failed toast is showing on Home.
    var toastVisible = false
    var whatsNewPresented = false
    /// Shown once after an update was installed.
    private(set) var justUpdatedTo: String?

    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.automatic); schedule() }
    }

    enum Keys {
        static let automatic = "update.automatic"
        static let lastChecked = "update.lastChecked"
        static let etag = "update.etag"
        static let skipped = "update.skipped"
        static let snoozed = "update.snoozedUntil"
        static let installing = "update.installingVersion"
        static let feedOverride = "PGUpdateFeed"
    }

    static let interval: TimeInterval = 4 * 60 * 60
    private var timer: Timer?
    private var installOnQuit = false

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    var feedURL: URL {
        UserDefaults.standard.string(forKey: Keys.feedOverride).flatMap(URL.init(string:)) ?? UpdateFeed.defaultURL
    }

    var readyFeed: UpdateFeed? { if case let .ready(feed, _) = state { return feed }; return nil }

    // MARK: Lifecycle

    func start() {
        if let installed = UserDefaults.standard.string(forKey: Keys.installing) {
            UserDefaults.standard.removeObject(forKey: Keys.installing)
            if installed == currentVersion { justUpdatedTo = installed; toastVisible = true }
        }
        #if DEBUG
        if let v = UserDefaults.standard.string(forKey: "PGPreviewUpdateToast") { // QA: show the ready toast
            let feed = UpdateFeed(version: v, dmg: URL(fileURLWithPath: "/dev/null"), size: 7_800_000, sha256: "",
                                  notes: ["Crop by dragging.", "Projects from earlier versions open again."])
            state = .ready(feed, URL(fileURLWithPath: "/dev/null"))
            toastVisible = true
            return
        }
        #endif
        schedule()
        if automatic { Task { await check(manual: false) } }
    }

    private func schedule() {
        timer?.invalidate()
        guard automatic else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let due = (UpdateChecker.shared.lastChecked ?? .distantPast).addingTimeInterval(UpdateChecker.interval) < Date()
                if due { Task { await UpdateChecker.shared.check(manual: false) } }
            }
        }
    }

    /// True while recording, counting down or exporting — never interrupt those.
    var isBusy: Bool { AppModel.shared.recorder.state != .idle || ExportActivity.running > 0 }

    // MARK: Checking

    func check(manual: Bool) async {
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        if isBusy && !manual { return }
        state = .checking
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        if !manual, let etag = UserDefaults.standard.string(forKey: Keys.etag) { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            markChecked()
            let http = response as? HTTPURLResponse
            if http?.statusCode == 304 { state = .idle; return }
            guard http == nil || http?.statusCode == 200 else { state = .idle; return }
            if let etag = http?.value(forHTTPHeaderField: "ETag") { UserDefaults.standard.set(etag, forKey: Keys.etag) }
            let feed = try JSONDecoder().decode(UpdateFeed.self, from: data)
            let d = UserDefaults.standard
            let offer = UpdatePolicy.shouldOffer(feed, current: currentVersion,
                                                 skipped: manual ? nil : d.string(forKey: Keys.skipped),
                                                 snoozedUntil: manual ? nil : d.object(forKey: Keys.snoozed) as? Date, now: Date())
            guard offer else {
                state = .idle
                if manual { upToDateAlert() }
                return
            }
            await download(feed)
        } catch {
            state = .idle
            if manual { failedCheckAlert(error) }
        }
    }

    private func markChecked() {
        lastChecked = Date()
        UserDefaults.standard.set(lastChecked, forKey: Keys.lastChecked)
    }

    private func download(_ feed: UpdateFeed) async {
        // Wait for a quiet moment rather than competing with a recording or export.
        while isBusy { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        state = .downloading(feed, 0)
        do {
            let dmg = try await UpdateInstaller.download(feed) { p in
                Task { @MainActor in
                    if case .downloading = UpdateChecker.shared.state { UpdateChecker.shared.state = .downloading(feed, p) }
                }
            }
            let (requirement, notarized) = Self.verificationPolicy
            let staged = try await Task.detached {
                try UpdateInstaller.stage(dmg: dmg, expectedVersion: feed.version, requirement: requirement, checkNotarization: notarized)
            }.value
            state = .ready(feed, staged)
            toastVisible = true
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-PGAutoRestartUpdate") { restartNow() }
            #endif
        } catch {
            state = .failed(feed, error.localizedDescription)
            toastVisible = true
        }
    }

    /// Release builds only accept our notarized Developer ID builds. Debug builds can be pointed at a
    /// locally signed test release for QA (`-PGUpdateRequirement '<requirement>'`); this never ships.
    static var verificationPolicy: (String, Bool) {
        #if DEBUG
        if let r = UserDefaults.standard.string(forKey: "PGUpdateRequirement") { return (r, false) }
        #endif
        return (UpdateInstaller.releaseRequirement, true)
    }

    // MARK: Actions

    func later() {
        toastVisible = false
        justUpdatedTo = nil
        if readyFeed != nil { installOnQuit = true }
        UserDefaults.standard.set(Date().addingTimeInterval(24 * 60 * 60), forKey: Keys.snoozed)
    }

    func skip(_ feed: UpdateFeed) {
        UserDefaults.standard.set(feed.version, forKey: Keys.skipped)
        installOnQuit = false
        toastVisible = false
        whatsNewPresented = false
        state = .idle
    }

    func dismissJustUpdated() {
        justUpdatedTo = nil
        toastVisible = false
    }

    /// Quits, swaps in the new version and reopens it.
    func restartNow() {
        guard case let .ready(feed, staged) = state, !isBusy else { return }
        guard UpdateInstaller.canReplace() else { openDownloadInstead(feed); return }
        do {
            try UpdateInstaller.scheduleSwap(staged: staged, relaunch: true)
            UserDefaults.standard.set(feed.version, forKey: Keys.installing)
            installOnQuit = false
            NSApp.terminate(nil)
        } catch {
            state = .failed(feed, error.localizedDescription)
        }
    }

    /// Called from applicationWillTerminate: "Later" installs on the next quit.
    func installIfDeferred() {
        guard installOnQuit, case let .ready(feed, staged) = state, UpdateInstaller.canReplace() else { return }
        if (try? UpdateInstaller.scheduleSwap(staged: staged, relaunch: false)) != nil {
            UserDefaults.standard.set(feed.version, forKey: Keys.installing)
        }
    }

    func openDownloadInstead(_ feed: UpdateFeed?) {
        NSWorkspace.shared.open(feed?.notesURL ?? URL(string: "https://www.davidfromkansas.com/screenplayground/")!)
    }

    // MARK: Alerts for manual checks

    private func upToDateAlert() {
        let a = NSAlert()
        a.messageText = "You're up to date"
        a.informativeText = "Screen Playground \(currentVersion) is the latest version."
        a.runModal()
    }

    private func failedCheckAlert(_ error: Error) {
        let a = NSAlert()
        a.messageText = "Couldn't check for updates"
        a.informativeText = "Check your internet connection and try again. (\(error.localizedDescription))"
        a.runModal()
    }
}

/// Exports in progress (the updater waits for them).
@MainActor enum ExportActivity {
    static var running = 0
}
