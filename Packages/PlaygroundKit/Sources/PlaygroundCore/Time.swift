import Foundation

/// Marker for time measured on the original recording ("source") clock.
public enum SourceDomain: Sendable {}
/// Marker for time measured on the edited, exported ("output") clock.
public enum OutputDomain: Sendable {}

/// A time value in seconds tagged with the clock it belongs to, so source and
/// output time can never be mixed by accident.
public struct Time<Domain>: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var seconds: Double

    public init(_ seconds: Double) { self.seconds = seconds }
    public init(ms: Double) { self.seconds = ms / 1000 }

    public static var zero: Time { Time(0) }

    public static func < (a: Time, b: Time) -> Bool { a.seconds < b.seconds }
    public static func + (a: Time, b: Double) -> Time { Time(a.seconds + b) }
    public static func - (a: Time, b: Double) -> Time { Time(a.seconds - b) }
    public static func - (a: Time, b: Time) -> Double { a.seconds - b.seconds }

    public init(from decoder: Decoder) throws {
        seconds = try decoder.singleValueContainer().decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(seconds)
    }

    public var description: String { String(format: "%.3fs", seconds) }
}

public typealias SourceTime = Time<SourceDomain>
public typealias OutputTime = Time<OutputDomain>

/// A half-open time range on one clock.
public struct TimeRange<Domain>: Hashable, Codable, Sendable {
    public var start: Time<Domain>
    public var end: Time<Domain>

    public init(_ start: Time<Domain>, _ end: Time<Domain>) {
        self.start = start
        self.end = end
    }

    public init(_ start: Double, _ end: Double) {
        self.start = Time(start)
        self.end = Time(end)
    }

    public var duration: Double { end.seconds - start.seconds }
    public func contains(_ t: Time<Domain>) -> Bool { t >= start && t < end }
    public func overlaps(_ other: TimeRange) -> Bool { start < other.end && other.start < end }
}

public typealias SourceRange = TimeRange<SourceDomain>
public typealias OutputRange = TimeRange<OutputDomain>

/// Converts `mach_absolute_time` ticks to seconds. Every capture stream is
/// mapped onto this host clock at the moment data arrives.
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func seconds(fromMachTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    public static func now() -> Double { seconds(fromMachTicks: mach_absolute_time()) }
}
