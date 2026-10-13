import Foundation
import PlaygroundCore
@testable import Screen_Playground
import Testing

@MainActor
@Suite struct StorageTests {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

    @Test func newUserIsAsked() {
        #expect(StorageLocation.resolve(saved: nil, savedLayout: nil, home: home) { _ in false } == .needsChoice)
    }

    @Test func existingDefaultFolderSkipsTheQuestion() {
        let r = StorageLocation.resolve(saved: nil, savedLayout: nil, home: home) { $0.path == "/Users/test/ScreenPlayground" }
        #expect(r == .ready(StorageLocation(root: home.appendingPathComponent("ScreenPlayground"), layout: .standard)))
    }

    @Test func savedChoiceWinsEvenWithoutTheDefaultFolder() {
        let r = StorageLocation.resolve(saved: "/Volumes/Work/ScreenPlayground", savedLayout: "standard", home: home) { _ in false }
        guard case let .ready(loc) = r else { Issue.record("asked again"); return }
        #expect(loc.root.path == "/Volumes/Work/ScreenPlayground")
        #expect(loc.projects.path == "/Volumes/Work/ScreenPlayground/Projects")
        #expect(loc.exports.path == "/Volumes/Work/ScreenPlayground/Exports")
    }

    @Test func earlierVersionsKeepTheirMoviesFolder() {
        let r = StorageLocation.resolve(saved: nil, savedLayout: nil, home: home) { $0.path == "/Users/test/Movies/Screen Playground/Projects" }
        guard case let .ready(loc) = r else { Issue.record("asked again"); return }
        #expect(loc.layout == .legacy)
        #expect(loc.projects.path == "/Users/test/Movies/Screen Playground/Projects")
        #expect(loc.exports.path == "/Users/test/Movies/Screen Playground")
    }

    @Test func pickedFolderGetsAScreenPlaygroundFolder() {
        #expect(StorageLocation.root(inside: URL(fileURLWithPath: "/Users/test/Dropbox")).path == "/Users/test/Dropbox/ScreenPlayground")
        #expect(StorageLocation.root(inside: URL(fileURLWithPath: "/x/ScreenPlayground")).path == "/x/ScreenPlayground")
    }

    @Test func cloudFoldersAreRecognised() {
        #expect(StorageLocation.cloudService(for: URL(fileURLWithPath: "/Users/t/Library/Mobile Documents/com~apple~CloudDocs/Rec")) == "iCloud Drive")
        #expect(StorageLocation.cloudService(for: URL(fileURLWithPath: "/Users/t/Library/CloudStorage/Dropbox-Personal/Rec")) == "Dropbox")
        #expect(StorageLocation.cloudService(for: URL(fileURLWithPath: "/Users/t/ScreenPlayground")) == nil)
    }

    @Test func movingCarriesProjectsAndSkipsClashes() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("pg-storage-\(UUID().uuidString)")
        let old = StorageLocation(root: base.appendingPathComponent("A/ScreenPlayground"), layout: .standard)
        let new = StorageLocation(root: base.appendingPathComponent("B/ScreenPlayground"), layout: .standard)
        for f in [old.projects, old.exports, old.presets] { try fm.createDirectory(at: f, withIntermediateDirectories: true) }
        try fm.createDirectory(at: old.projects.appendingPathComponent("One.screenplayground"), withIntermediateDirectories: true)
        try Data([1]).write(to: old.exports.appendingPathComponent("clip.mp4"))
        // Moving changes the saved location: restore it afterwards.
        let saved = UserDefaults.standard.string(forKey: StorageLocation.defaultsKey)
        let savedLayout = UserDefaults.standard.string(forKey: StorageLocation.layoutKey)
        defer {
            UserDefaults.standard.set(saved, forKey: StorageLocation.defaultsKey)
            UserDefaults.standard.set(savedLayout, forKey: StorageLocation.layoutKey)
            try? fm.removeItem(at: base)
        }
        #expect(try StorageLocation.move(from: old, to: new) == 1)
        #expect(fm.fileExists(atPath: new.projects.appendingPathComponent("One.screenplayground").path))
        #expect(fm.fileExists(atPath: new.exports.appendingPathComponent("clip.mp4").path))
        #expect(!fm.fileExists(atPath: old.projects.appendingPathComponent("One.screenplayground").path))
    }
}
