import Foundation
@testable import Screen_Playground
import Testing

@Suite struct UpdatePolicyTests {
    func feed(_ v: String, minimumSystem: String? = nil) -> UpdateFeed {
        UpdateFeed(version: v, dmg: URL(string: "https://example.com/x.dmg")!, size: 1, sha256: "00", minimumSystem: minimumSystem)
    }

    @Test func semanticVersions() {
        #expect(SemVer.isNewer("0.10.0", than: "0.9.9"))
        #expect(SemVer.isNewer("1.0", than: "0.99.99"))
        #expect(SemVer.isNewer("0.3.1", than: "0.3.0"))
        #expect(!SemVer.isNewer("0.3.0", than: "0.3.0"))
        #expect(!SemVer.isNewer("0.2.9", than: "0.3.0"))
        #expect(SemVer.isNewer("v0.4.0", than: "0.3.0"))
    }

    @Test func offerRules() {
        let now = Date()
        let v15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 2, patchVersion: 0)
        #expect(UpdatePolicy.shouldOffer(feed("0.4.0"), current: "0.3.0", skipped: nil, snoozedUntil: nil, now: now, systemVersion: v15))
        #expect(!UpdatePolicy.shouldOffer(feed("0.3.0"), current: "0.3.0", skipped: nil, snoozedUntil: nil, now: now, systemVersion: v15))
        #expect(!UpdatePolicy.shouldOffer(feed("0.4.0-beta"), current: "0.3.0", skipped: nil, snoozedUntil: nil, now: now, systemVersion: v15), "pre-releases ignored")
        #expect(!UpdatePolicy.shouldOffer(feed("0.4.0"), current: "0.3.0", skipped: "0.4.0", snoozedUntil: nil, now: now, systemVersion: v15), "skipped")
        #expect(UpdatePolicy.shouldOffer(feed("0.4.1"), current: "0.3.0", skipped: "0.4.0", snoozedUntil: nil, now: now, systemVersion: v15), "a newer one after a skip")
        #expect(!UpdatePolicy.shouldOffer(feed("0.4.0"), current: "0.3.0", skipped: nil, snoozedUntil: now.addingTimeInterval(60), now: now, systemVersion: v15), "snoozed")
        #expect(UpdatePolicy.shouldOffer(feed("0.4.0"), current: "0.3.0", skipped: nil, snoozedUntil: now.addingTimeInterval(-60), now: now, systemVersion: v15))
        #expect(!UpdatePolicy.shouldOffer(feed("0.4.0", minimumSystem: "26.0"), current: "0.3.0", skipped: nil, snoozedUntil: nil, now: now, systemVersion: v15), "needs a newer macOS")
        #expect(UpdatePolicy.shouldOffer(feed("0.4.0", minimumSystem: "15.0"), current: "0.3.0", skipped: nil, snoozedUntil: nil, now: now, systemVersion: v15))
    }

    @Test func feedDecodes() throws {
        let json = #"{"version":"0.4.0","released":"Nov 3, 2026","dmg":"https://github.com/x/y.dmg","size":5400000,"sha256":"ab","notes":["One","Two"],"minimumSystem":"15.0"}"#
        let f = try JSONDecoder().decode(UpdateFeed.self, from: Data(json.utf8))
        #expect(f.version == "0.4.0" && f.notes?.count == 2 && f.notesURL == nil)
    }
}

/// Builds fake releases (a tiny app in a DMG) and checks the installer only accepts properly signed ones.
@Suite(.serialized) struct UpdateInstallerTests {
    /// Our local signing identity stands in for the Developer ID in tests.
    static let devRequirement = #"identifier "dev.screenplayground.app" and certificate leaf[subject.CN] = "Screen Playground Dev""#

    enum Signing { case dev, adHoc, none }

    static func run(_ tool: String, _ args: [String]) throws {
        try UpdateInstaller.run(tool, args)
    }

    /// Returns (dmg, folder) for a fake "Screen Playground.app" of `version`.
    static func makeRelease(version: String, signing: Signing) throws -> (URL, URL) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pg-update-\(UUID().uuidString)", isDirectory: true)
        let app = dir.appendingPathComponent("src/Screen Playground.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Screen Playground").path)
        let info: [String: Any] = ["CFBundleIdentifier": "dev.screenplayground.app", "CFBundleShortVersionString": version,
                                   "CFBundleVersion": "1", "CFBundleExecutable": "Screen Playground", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        // /usr/bin/true carries Apple's signature: strip it so each case controls the signing.
        try run("/usr/bin/codesign", ["--remove-signature", app.appendingPathComponent("Contents/MacOS/Screen Playground").path])
        switch signing {
        case .dev: try run("/usr/bin/codesign", ["--force", "--sign", "Screen Playground Dev", app.path])
        case .adHoc: try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        case .none: break
        }
        let dmg = dir.appendingPathComponent("release.dmg")
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-fs", "HFS+", "-volname", "Screen Playground", "-srcfolder",
                                     app.deletingLastPathComponent().path, "-format", "UDZO", dmg.path])
        return (dmg, dir)
    }

    static func feed(_ dmg: URL, version: String, sha: String? = nil) throws -> UpdateFeed {
        UpdateFeed(version: version, dmg: dmg, size: 1, sha256: try sha ?? UpdateInstaller.sha256(of: dmg))
    }

    @Test func validReleaseIsDownloadedVerifiedAndStaged() async throws {
        let (dmg, dir) = try Self.makeRelease(version: "9.9.9", signing: .dev)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("cache")
        let local = try await UpdateInstaller.download(try Self.feed(dmg, version: "9.9.9"), to: cache) { _ in }
        let staged = try UpdateInstaller.stage(dmg: local, expectedVersion: "9.9.9", requirement: Self.devRequirement,
                                               checkNotarization: false, into: cache)
        #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/Info.plist").path))
        #expect(staged.lastPathComponent == "Screen Playground.app")
    }

    @Test func checksumMismatchIsRejected() async throws {
        let (dmg, dir) = try Self.makeRelease(version: "9.9.9", signing: .dev)
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: UpdateInstaller.Failure.self) {
            _ = try await UpdateInstaller.download(try Self.feed(dmg, version: "9.9.9", sha: String(repeating: "0", count: 64)),
                                                   to: dir.appendingPathComponent("cache")) { _ in }
        }
    }

    @Test func adHocUnsignedAndWrongTeamAreRejected() throws {
        for signing in [Signing.adHoc, .none] {
            let (dmg, dir) = try Self.makeRelease(version: "9.9.9", signing: signing)
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(throws: UpdateInstaller.Failure.self, "\(signing) must be rejected") {
                _ = try UpdateInstaller.stage(dmg: dmg, expectedVersion: "9.9.9", requirement: Self.devRequirement,
                                              checkNotarization: false, into: dir.appendingPathComponent("cache"))
            }
        }
        // Signed, but not by our Developer ID team.
        let (dmg, dir) = try Self.makeRelease(version: "9.9.9", signing: .dev)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: UpdateInstaller.Failure.self) {
            _ = try UpdateInstaller.stage(dmg: dmg, expectedVersion: "9.9.9", checkNotarization: false, into: dir.appendingPathComponent("cache"))
        }
    }

    @Test func versionMismatchIsRejected() throws {
        let (dmg, dir) = try Self.makeRelease(version: "9.9.8", signing: .dev)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: UpdateInstaller.Failure.self) {
            _ = try UpdateInstaller.stage(dmg: dmg, expectedVersion: "9.9.9", requirement: Self.devRequirement,
                                          checkNotarization: false, into: dir.appendingPathComponent("cache"))
        }
    }
}
