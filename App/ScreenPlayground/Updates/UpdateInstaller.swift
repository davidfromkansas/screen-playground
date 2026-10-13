import AppKit
import CryptoKit
import Foundation
import Security

/// Downloads, verifies and installs an update. Nothing is installed unless the download's hash matches
/// the feed AND the app inside is validly signed by our Developer ID team (and notarized).
enum UpdateInstaller {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Code requirement for release builds: Apple-anchored Developer ID from our team, our bundle ID.
    static let releaseRequirement =
        #"identifier "dev.screenplayground.app" and anchor apple generic and certificate leaf[subject.OU] = "8FGG5DR669""#

    static var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Playground/Updates", isDirectory: true)
    }

    // MARK: Download

    static func download(_ feed: UpdateFeed, to folder: URL = cacheFolder, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("ScreenPlayground-\(feed.version).dmg")
        if FileManager.default.fileExists(atPath: dest.path), (try? sha256(of: dest)) == feed.sha256.lowercased() {
            progress(1)
            return dest
        }
        if feed.dmg.isFileURL {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: feed.dmg, to: dest)
        } else {
            let (bytes, response) = try await URLSession.shared.bytes(from: feed.dmg)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "The download failed.") }
            let total = max(response.expectedContentLength > 0 ? response.expectedContentLength : feed.size, 1)
            let part = dest.appendingPathExtension("part")
            FileManager.default.createFile(atPath: part.path, contents: nil)
            let handle = try FileHandle(forWritingTo: part)
            var buffer = Data()
            var received: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 256 * 1024 {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress(min(Double(received) / Double(total), 0.99))
                }
            }
            try handle.write(contentsOf: buffer)
            try handle.close()
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: part, to: dest)
        }
        guard try sha256(of: dest) == feed.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: dest)
            throw Failure(message: "The downloaded file didn't match the published checksum.")
        }
        progress(1)
        return dest
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Verify and stage

    /// Mounts the DMG, verifies the app inside and copies it to a staging folder. Returns the staged app.
    static func stage(dmg: URL, expectedVersion: String, requirement: String = releaseRequirement, checkNotarization: Bool = true,
                      into folder: URL = cacheFolder) throws -> URL {
        let mount = try attach(dmg)
        defer { detach(mount) }
        guard let app = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw Failure(message: "The download doesn't contain the app.") }
        try verify(app: app, expectedVersion: expectedVersion, requirement: requirement, checkNotarization: checkNotarization)
        let staging = folder.appendingPathComponent("staged-\(expectedVersion)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent(app.lastPathComponent)
        try run("/usr/bin/ditto", [app.path, staged.path])
        // Verify the copy too: this is exactly what gets installed.
        try verify(app: staged, expectedVersion: expectedVersion, requirement: requirement, checkNotarization: false)
        return staged
    }

    static func verify(app: URL, expectedVersion: String, requirement: String, checkNotarization: Bool) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let version = info["CFBundleShortVersionString"] as? String else { throw Failure(message: "The update's app is incomplete.") }
        guard version == expectedVersion else { throw Failure(message: "The download is version \(version), not \(expectedVersion).") }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure(message: "The update isn't signed.")
        }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else {
            throw Failure(message: "Internal error checking the signature.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess else {
            throw Failure(message: "The update isn't signed by the Screen Playground developer.")
        }
        if checkNotarization {
            let status = try? run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], allowFailure: true)
            guard status == 0 else { throw Failure(message: "The update isn't notarized by Apple.") }
        }
    }

    static func attach(_ dmg: URL) throws -> URL {
        let out = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg.path]
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw Failure(message: "Couldn't open the downloaded disk image.") }
        return URL(fileURLWithPath: mount, isDirectory: true)
    }

    static func detach(_ mount: URL) {
        _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path], allowFailure: true)
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], allowFailure: Bool = false) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        if !allowFailure, p.terminationStatus != 0 { throw Failure(message: "\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(p.terminationStatus)).") }
        return p.terminationStatus
    }

    // MARK: Install

    /// Whether the running app can replace itself (not translocated, folder writable).
    static func canReplace(_ app: URL = Bundle.main.bundleURL) -> Bool {
        guard !app.path.contains("/AppTranslocation/") else { return false }
        let fm = FileManager.default
        return fm.isWritableFile(atPath: app.deletingLastPathComponent().path) && fm.isWritableFile(atPath: app.path)
    }

    /// Starts a helper that waits for this process to quit, moves the old app to the Trash, puts the staged
    /// app in its place and (optionally) reopens it. Call right before quitting.
    static func scheduleSwap(staged: URL, replacing app: URL = Bundle.main.bundleURL, relaunch: Bool) throws {
        let script = """
        #!/bin/sh
        PID="$1"; OLD="$2"; NEW="$3"; RELAUNCH="$4"
        i=0; while kill -0 "$PID" 2>/dev/null && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done
        TRASH="$HOME/.Trash/$(basename "$OLD" .app) (old $(date +%s)).app"
        mv "$OLD" "$TRASH" || exit 1
        if ! mv "$NEW" "$OLD"; then mv "$TRASH" "$OLD"; exit 1; fi
        xattr -dr com.apple.quarantine "$OLD" 2>/dev/null
        if [ "$RELAUNCH" = "1" ]; then open "$OLD"; fi
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("screen-playground-update-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [file.path, String(ProcessInfo.processInfo.processIdentifier), app.path, staged.path, relaunch ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}
