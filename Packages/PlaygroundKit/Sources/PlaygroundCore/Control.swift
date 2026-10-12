import Darwin
import Foundation

/// Local control channel between `pgctl` (and agents) and the running app.
///
/// One JSON object per line over a Unix domain socket that only the current user can open.
/// Requests are `{"cmd": "...", "args": {...}}`; responses are `{"ok": true, "result": ...}` or
/// `{"ok": false, "error": {"code", "message", "fix"}}`.
public enum Control {
    public static let releaseBundleID = "dev.screenplayground.app"

    /// The socket a client connects to: `PG_CONTROL_SOCKET` when set, otherwise the release app's socket.
    public static var socketURL: URL {
        if let override = ProcessInfo.processInfo.environment["PG_CONTROL_SOCKET"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return socketURL(forBundleID: releaseBundleID)
    }

    /// `~/Library/Application Support/Screen Playground/control.sock` for the release app; other builds
    /// (QA, debug copies) get their own socket so they never answer for the installed app.
    public static func socketURL(forBundleID bundleID: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let suffix = bundleID.split(separator: ".").last.map(String.init) ?? "dev"
        let name = bundleID == releaseBundleID ? "control.sock" : "control-\(suffix).sock"
        let preferred = support.appendingPathComponent("Screen Playground/\(name)")
        // Unix socket paths are limited to 103 bytes; very long home paths fall back to the per-user temp folder.
        if preferred.path.utf8.count <= maxPathLength { return preferred }
        return FileManager.default.temporaryDirectory.appendingPathComponent("screen-playground-\(name)")
    }

    static let maxPathLength = 103
}

/// Any JSON value, so requests and results stay schemaless on the wire.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case let .string(s) = self { return s }; return nil }
    public var number: Double? { if case let .number(n) = self { return n }; return nil }
    public var int: Int? { number.map { Int($0) } }
    public var bool: Bool? { if case let .bool(b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case let .array(a) = self { return a }; return nil }

    /// Converts any Encodable value (round-trips through JSON).
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// Decodes this value as `T`.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
}

public struct ControlRequest: Codable, Sendable {
    public var cmd: String
    public var args: JSONValue

    public init(cmd: String, args: JSONValue = [:]) {
        self.cmd = cmd
        self.args = args
    }
}

/// A failure with a stable code an agent can branch on and a human-readable fix.
public struct ControlError: Error, Codable, Sendable, LocalizedError {
    public var code: String
    public var message: String
    public var fix: String?

    public init(_ code: String, _ message: String, fix: String? = nil) {
        self.code = code
        self.message = message
        self.fix = fix
    }

    public var errorDescription: String? { message }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var result: JSONValue?
    public var error: ControlError?

    public static func success(_ result: JSONValue) -> ControlResponse { ControlResponse(ok: true, result: result, error: nil) }
    public static func failure(_ error: ControlError) -> ControlResponse { ControlResponse(ok: false, result: nil, error: error) }
}

/// Minimal blocking line I/O over a Unix domain socket (used by both ends).
public struct LineSocket: Sendable {
    public let fd: Int32

    public init(fd: Int32) { self.fd = fd }

    /// Connects to a listening socket; nil if nothing is listening.
    public static func connect(to url: URL) -> LineSocket? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un.make(path: url.path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { Darwin.close(fd); return nil }
        return LineSocket(fd: fd)
    }

    /// Creates a listening socket readable/writable only by the current user.
    public static func listen(at url: URL) throws -> LineSocket {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard url.path.utf8.count <= Control.maxPathLength else {
            throw ControlError("socket", "Socket path is too long: \(url.path)")
        }
        unlink(url.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError("socket", "Could not create the control socket.") }
        var addr = sockaddr_un.make(path: url.path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { Darwin.close(fd); throw ControlError("socket", "Could not bind \(url.path) (errno \(errno)).") }
        guard chmod(url.path, 0o600) == 0 else {
            Darwin.close(fd)
            throw ControlError("socket", "Could not restrict the control socket to this user.")
        }
        guard Darwin.listen(fd, 8) == 0 else { Darwin.close(fd); throw ControlError("socket", "Could not listen on the control socket.") }
        return LineSocket(fd: fd)
    }

    public func accept() -> LineSocket? {
        let client = Darwin.accept(fd, nil, nil)
        return client >= 0 ? LineSocket(fd: client) : nil
    }

    /// Reads one newline-terminated line (without the newline); nil at end of stream.
    public func readLine() -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return data.isEmpty ? nil : data }
            if byte == 0x0A { return data }
            data.append(byte)
        }
    }

    public func writeLine(_ data: Data) {
        var payload = data
        payload.append(0x0A)
        payload.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    public func close() { Darwin.close(fd) }
}

extension sockaddr_un {
    static func make(path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }
}
