import Foundation

public struct ProjectMeta: Hashable, Codable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion = ProjectMeta.currentFormatVersion
    public var minReaderVersion = 1
    public var appVersion = "0.1.0"
    public var createdAt = Date()
    public init() {}
}

/// Editor UI state persisted with the project.
public struct EditorState: Hashable, Codable, Sendable {
    public var playheadSource: Double = 0
    public var openPanel: String = "background"
    public init() {}
}

/// Everything in `project.json`. Value type: undo stores whole snapshots.
public struct ProjectDocument: Hashable, Codable, Sendable {
    public var meta = ProjectMeta()
    public var name: String = "Untitled"
    public var config = ProjectConfig()
    public var scenes: [Scene] = [Scene()]
    public var editor = EditorState()

    public init() {}

    /// The first (and for now only) scene.
    public var scene: Scene {
        get { scenes.first ?? Scene() }
        set {
            if scenes.isEmpty { scenes = [newValue] } else { scenes[0] = newValue }
        }
    }
}

/// Decodes `T` leniently: keys missing in `data` take their values from `defaults`.
/// This keeps old project files loadable when new settings are added.
public enum TolerantJSON {
    public static func decode<T: Codable>(_ type: T.Type, from data: Data, defaults: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let defaultObject = try JSONSerialization.jsonObject(with: encoder.encode(defaults))
        let loaded = try JSONSerialization.jsonObject(with: data)
        let merged = merge(defaultObject, loaded)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    /// Deep-merges dictionaries; `overlay` wins. Arrays and scalars are taken from `overlay` wholesale.
    static func merge(_ base: Any, _ overlay: Any) -> Any {
        guard let b = base as? [String: Any], let o = overlay as? [String: Any] else { return overlay }
        var out = b
        for (k, v) in o { out[k] = b[k].map { merge($0, v) } ?? v }
        return out
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

/// Upgrades raw project JSON from older format versions before typed decoding.
public enum ProjectMigrator {
    public enum MigrationError: Error, LocalizedError {
        case tooNew(Int)
        public var errorDescription: String? {
            if case let .tooNew(v) = self { return "This project needs a newer version of Screen Playground (format \(v))." }
            return nil
        }
    }

    /// Ordered migrations keyed by the version they upgrade *from*.
    static let steps: [Int: @Sendable ([String: Any]) -> [String: Any]] = [:]

    public static func migrate(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        let meta = object["meta"] as? [String: Any]
        let minReader = meta?["minReaderVersion"] as? Int ?? 1
        if minReader > ProjectMeta.currentFormatVersion { throw MigrationError.tooNew(minReader) }
        var version = meta?["formatVersion"] as? Int ?? 1
        while version < ProjectMeta.currentFormatVersion {
            if let step = steps[version] { object = step(object) }
            version += 1
        }
        if var m = object["meta"] as? [String: Any] {
            m["formatVersion"] = ProjectMeta.currentFormatVersion
            object["meta"] = m
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
