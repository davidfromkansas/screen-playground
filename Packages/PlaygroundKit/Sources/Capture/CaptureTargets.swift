import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import PlaygroundCore
@preconcurrency import ScreenCaptureKit

/// What to record.
public enum RecordingTarget: Sendable, Hashable {
    case display(CGDirectDisplayID)
    /// A window; the rect is its frame in global points at selection time.
    case window(CGWindowID)
    /// A region of a display, in global points (top-left origin).
    case area(CGDirectDisplayID, CGRect)
}

public struct DisplayInfo: Sendable, Hashable, Identifiable {
    public var id: CGDirectDisplayID
    public var name: String
    /// Global frame in points (top-left origin).
    public var frame: CGRect
    public var pixelScale: Double
}

public struct WindowInfo: Sendable, Hashable, Identifiable {
    public var id: CGWindowID
    public var title: String
    public var appName: String
    public var bundleID: String?
    public var frame: CGRect
    public var pid: pid_t
}

public struct AVDeviceInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
}

/// Enumerates recordable displays, windows and capture devices.
public enum CaptureCatalog {
    public static func displays() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { id in
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let scale = mode.map { Double($0.pixelWidth) / max(Double($0.width), 1) } ?? 2
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?
                .localizedName ?? "Display \(id)"
            return DisplayInfo(id: id, name: name, frame: bounds, pixelScale: scale)
        }
    }

    /// On-screen, normal-layer windows of other apps, front to back.
    public static func windows(excludingPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let skipOwners: Set<String> = ["Window Server", "Dock", "Control Center", "Notification Center", "Spotlight", "SystemUIServer"]
        return list.compactMap { w in
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != excludingPID,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict), frame.width > 60, frame.height > 40
            else { return nil }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            if skipOwners.contains(owner) { return nil }
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            if alpha < 0.05 { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            return WindowInfo(id: id, title: w[kCGWindowName as String] as? String ?? "", appName: owner,
                              bundleID: app?.bundleIdentifier, frame: frame, pid: pid)
        }
    }

    /// Current frame of a window in global points, or nil if it closed.
    public static func windowFrame(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let dict = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict)
    }

    public static func microphones() -> [AVDeviceInfo] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { AVDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    public static func cameras() -> [AVDeviceInfo] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video,
                                         position: .unspecified)
            .devices.map { AVDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The display containing most of a rect.
    public static func display(containing rect: CGRect) -> DisplayInfo? {
        displays().max { a, b in
            a.frame.intersection(rect).width * a.frame.intersection(rect).height
                < b.frame.intersection(rect).width * b.frame.intersection(rect).height
        }
    }
}
