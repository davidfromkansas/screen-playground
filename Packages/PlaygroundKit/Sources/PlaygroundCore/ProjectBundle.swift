import Foundation

/// File layout of a `Name.screenplayground` package.
public struct ProjectBundle: Sendable, Hashable {
    public static let fileExtension = "screenplayground"
    public static let maxBackups = 10

    public let url: URL

    public init(url: URL) { self.url = url }

    public var projectFile: URL { url.appendingPathComponent("project.json") }
    public var backupsFolder: URL { url.appendingPathComponent("project.backups", isDirectory: true) }
    public var recordingFolder: URL { url.appendingPathComponent("recording", isDirectory: true) }
    public var manifestFile: URL { recordingFolder.appendingPathComponent("manifest.json") }
    public var eventsFolder: URL { recordingFolder.appendingPathComponent("events", isDirectory: true) }
    public var cursorsFolder: URL { recordingFolder.appendingPathComponent("cursors", isDirectory: true) }
    public var derivedFolder: URL { url.appendingPathComponent("derived", isDirectory: true) }

    public var movesFile: URL { eventsFolder.appendingPathComponent("mouse.jsonl") }
    public var clicksFile: URL { eventsFolder.appendingPathComponent("clicks.jsonl") }
    public var keysFile: URL { eventsFolder.appendingPathComponent("keys.jsonl") }
    public var geometryFile: URL { eventsFolder.appendingPathComponent("window-geometry.jsonl") }
    public var cursorsIndexFile: URL { cursorsFolder.appendingPathComponent("cursors.json") }

    public func channelURL(_ info: ChannelInfo) -> URL { recordingFolder.appendingPathComponent(info.file) }

    /// Creates an empty bundle with all folders.
    public static func create(at url: URL) throws -> ProjectBundle {
        let bundle = ProjectBundle(url: url)
        let fm = FileManager.default
        for folder in [bundle.recordingFolder, bundle.eventsFolder, bundle.cursorsFolder, bundle.derivedFolder] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return bundle
    }

    /// Picks a non-existing `<folder>/<name>.screenplayground` URL.
    public static func uniqueURL(in folder: URL, name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        var candidate = folder.appendingPathComponent("\(safe).\(fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(safe) \(n).\(fileExtension)")
            n += 1
        }
        return candidate
    }

    // MARK: Project document

    public func loadDocument() throws -> ProjectDocument {
        let raw = try Data(contentsOf: projectFile)
        let migrated = try ProjectMigrator.migrate(raw)
        return try TolerantJSON.decode(ProjectDocument.self, from: migrated, defaults: ProjectDocument())
    }

    /// Atomically writes the document, keeping the previous version as a rolling backup.
    public func saveDocument(_ doc: ProjectDocument, keepBackup: Bool = true) throws {
        let fm = FileManager.default
        if keepBackup, fm.fileExists(atPath: projectFile.path) {
            try fm.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = backupsFolder.appendingPathComponent("\(stamp).json")
            if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: projectFile, to: backup) }
            pruneBackups()
        }
        try TolerantJSON.encode(doc).write(to: projectFile, options: .atomic)
    }

    func pruneBackups() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: backupsFolder, includingPropertiesForKeys: nil) else { return }
        let sorted = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in sorted.dropLast(Self.maxBackups) { try? fm.removeItem(at: f) }
    }

    // MARK: Recording

    public func loadManifest() throws -> RecordingManifest {
        try TolerantJSON.decode(RecordingManifest.self, from: Data(contentsOf: manifestFile), defaults: RecordingManifest())
    }

    public func saveManifest(_ manifest: RecordingManifest) throws {
        try TolerantJSON.encode(manifest).write(to: manifestFile, options: .atomic)
    }

    public func loadEvents() -> RecordingEvents {
        var events = RecordingEvents()
        events.moves = JSONLines.read(MouseMove.self, from: movesFile).sorted { $0.t < $1.t }
        events.clicks = JSONLines.read(MouseClick.self, from: clicksFile).sorted { $0.t < $1.t }
        events.keys = JSONLines.read(KeyStroke.self, from: keysFile).sorted { $0.t < $1.t }
        events.geometry = JSONLines.read(GeometrySample.self, from: geometryFile).sorted { $0.t < $1.t }
        if let data = try? Data(contentsOf: cursorsIndexFile),
           let list = try? JSONDecoder().decode([CursorImageInfo].self, from: data) {
            events.cursors = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        return events
    }
}

/// Newline-delimited JSON helpers. Reading tolerates a truncated last line (crash recovery).
public enum JSONLines {
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var out: [T] = []
        out.reserveCapacity(text.count / 60)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let value = try? decoder.decode(T.self, from: Data(line.utf8)) { out.append(value) }
        }
        return out
    }

    public static func write<T: Encodable>(_ values: [T], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for v in values {
            data.append(try encoder.encode(v))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }
}

/// Appends JSON lines to a file, flushing periodically. Not thread-safe: confine to one queue.
public final class JSONLinesWriter<T: Encodable> {
    private let handle: FileHandle
    private let encoder = JSONEncoder()
    private var buffer = Data()
    private var lastFlush = Date()

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        encoder.outputFormatting = [.sortedKeys]
    }

    public func append(_ value: T) {
        guard let data = try? encoder.encode(value) else { return }
        buffer.append(data)
        buffer.append(0x0A)
        if Date().timeIntervalSince(lastFlush) > 1 { flush() }
    }

    public func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(buffer)
        try? handle.synchronize()
        buffer.removeAll(keepingCapacity: true)
        lastFlush = Date()
    }

    public func close() {
        flush()
        try? handle.close()
    }
}
