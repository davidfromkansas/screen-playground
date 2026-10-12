import ApplicationServices
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// The macOS privacy permissions the recorder uses.
public enum Permission: String, CaseIterable, Sendable, Identifiable {
    case screenRecording, microphone, camera, accessibility, inputMonitoring

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    public var purpose: String {
        switch self {
        case .screenRecording: return "Required to record your screen and system audio."
        case .microphone: return "Record your voice."
        case .camera: return "Show your webcam in recordings."
        case .accessibility: return "Focus and resize the window you record."
        case .inputMonitoring: return "Show keyboard shortcuts in your videos."
        }
    }

    public var isRequired: Bool { self == .screenRecording }

    /// Deep link to the matching System Settings privacy pane.
    public var settingsURL: URL {
        let anchor: String
        switch self {
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .microphone: anchor = "Privacy_Microphone"
        case .camera: anchor = "Privacy_Camera"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum PermissionCenter {
    public static func isGranted(_ p: Permission) -> Bool {
        switch p {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .camera: return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .accessibility: return AXIsProcessTrusted()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        }
    }

    /// Triggers the system prompt (or returns immediately if already decided).
    @discardableResult
    public static func request(_ p: Permission) async -> Bool {
        switch p {
        case .screenRecording: return CGRequestScreenCaptureAccess()
        case .microphone: return await AVCaptureDevice.requestAccess(for: .audio)
        case .camera: return await AVCaptureDevice.requestAccess(for: .video)
        case .accessibility:
            let key = "AXTrustedCheckOptionPrompt" as CFString
            return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .inputMonitoring: return CGRequestListenEventAccess()
        }
    }
}
