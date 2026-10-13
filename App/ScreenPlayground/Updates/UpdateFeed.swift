import Foundation

/// `updates/latest.json` on the website, written by `scripts/release.sh` for every release.
struct UpdateFeed: Codable, Equatable, Sendable {
    var version: String
    var released: String?
    /// The notarized DMG on GitHub Releases.
    var dmg: URL
    var size: Int64
    /// Hex SHA-256 of the DMG.
    var sha256: String
    /// A few short "what's new" lines.
    var notes: [String]?
    var notesURL: URL?
    var minimumSystem: String?

    static let defaultURL = URL(string: "https://davidfromkansas.github.io/screen-playground/updates/latest.json")!
}

/// Semantic-version comparison ("0.10.0" > "0.9.9"; "1.0.0-beta" counts as a pre-release).
enum SemVer {
    static func parts(_ v: String) -> [Int] {
        let core = v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: "-").first ?? ""
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func isPrerelease(_ v: String) -> Bool { v.contains("-") }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Whether to offer a feed's version (pure; unit-tested).
enum UpdatePolicy {
    static func shouldOffer(_ feed: UpdateFeed, current: String, skipped: String?, snoozedUntil: Date?, now: Date,
                            systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        guard !SemVer.isPrerelease(feed.version), SemVer.isNewer(feed.version, than: current) else { return false }
        if skipped == feed.version { return false }
        if let snoozedUntil, now < snoozedUntil { return false }
        if let minimum = feed.minimumSystem {
            let need = SemVer.parts(minimum)
            let have = [systemVersion.majorVersion, systemVersion.minorVersion, systemVersion.patchVersion]
            for i in 0..<min(need.count, 3) where have[i] != need[i] { return have[i] > need[i] }
        }
        return true
    }
}
