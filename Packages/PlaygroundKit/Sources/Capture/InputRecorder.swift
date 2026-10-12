import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PlaygroundCore
import UniformTypeIdentifiers

/// Records mouse moves, clicks and keystrokes with a listen-only CGEventTap on its own thread.
/// Keyboard events need Input Monitoring; without it only mouse events are captured.
final class InputRecorder: @unchecked Sendable {
    private let clock: RecordingClock
    private let lock = NSLock()
    private var moves: JSONLinesWriter<MouseMove>
    private var clicks: JSONLinesWriter<MouseClick>
    private var keys: JSONLinesWriter<KeyStroke>
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var lastMove: Double = -1
    private(set) var capturesKeys = false
    /// Current cursor id, updated by `CursorRecorder`.
    var cursorID: String? {
        get { lock.withLock { _cursorID } }
        set { lock.withLock { _cursorID = newValue } }
    }
    private var _cursorID: String?
    /// Called on the tap thread for every mouse-down (used by the recording widget, flags, etc.).
    var onClick: (@Sendable (Double) -> Void)?

    init(bundle: ProjectBundle, clock: RecordingClock) throws {
        self.clock = clock
        moves = try JSONLinesWriter(url: bundle.movesFile)
        clicks = try JSONLinesWriter(url: bundle.clicksFile)
        keys = try JSONLinesWriter(url: bundle.keysFile)
    }

    func start() {
        let mouseMask: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        let keyMask: [CGEventType] = [.keyDown]
        @Sendable func mask(_ types: [CGEventType]) -> CGEventMask { types.reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) } }

        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let info = Unmanaged.passUnretained(self).toOpaque()
            var port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                         eventsOfInterest: mask(mouseMask + keyMask), callback: inputTapCallback, userInfo: info)
            if port != nil && CGPreflightListenEventAccess() {
                self.capturesKeys = true
            } else {
                if let p = port { CFMachPortInvalidate(p) }
                port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                         eventsOfInterest: mask(mouseMask), callback: inputTapCallback, userInfo: info)
            }
            guard let port else { ready.signal(); return }
            self.tap = port
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "ScreenPlayground.InputTap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
    }

    func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard let t = clock.sourceTime(host: HostClock.now()) else { return }
        let loc = event.location
        let mods = Self.modifiers(event.flags)
        lock.lock()
        defer { lock.unlock() }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // Coalesce to at most 240 Hz.
            guard t - lastMove >= 1.0 / 240 else { return }
            lastMove = t
            moves.append(MouseMove(t: t, x: loc.x, y: loc.y, cursor: _cursorID))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            let button: MouseButton = (type == .leftMouseDown || type == .leftMouseUp) ? .left
                : (type == .rightMouseDown || type == .rightMouseUp) ? .right : .other
            clicks.append(MouseClick(t: t, x: loc.x, y: loc.y, phase: down ? .down : .up, button: button, modifiers: mods))
            moves.append(MouseMove(t: t, x: loc.x, y: loc.y, cursor: _cursorID))
            if down { onClick?(t) }
        case .keyDown:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let chars = Self.unicode(event)
            var plain = chars
            if let copy = event.copy() {
                copy.flags = []
                plain = Self.unicode(copy)
            }
            keys.append(KeyStroke(t: t, keyCode: code, characters: chars, charactersIgnoringModifiers: plain,
                                  modifiers: mods, isRepeat: isRepeat))
        default:
            break
        }
    }

    static func unicode(_ event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }

    static func modifiers(_ f: CGEventFlags) -> Modifiers {
        var m: Modifiers = []
        if f.contains(.maskShift) { m.insert(.shift) }
        if f.contains(.maskControl) { m.insert(.control) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        if f.contains(.maskCommand) { m.insert(.command) }
        if f.contains(.maskSecondaryFn) { m.insert(.function) }
        if f.contains(.maskAlphaShift) { m.insert(.capsLock) }
        return m
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        lock.withLock {
            moves.close()
            clicks.close()
            keys.close()
        }
    }
}

private func inputTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<InputRecorder>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}

/// Samples the system cursor image ~30×/s on the main thread, saving each distinct image once.
@MainActor
final class CursorRecorder {
    private let bundle: ProjectBundle
    private weak var input: InputRecorder?
    private var timer: Timer?
    private var known: [String: CursorImageInfo] = [:]
    private var lastImage: NSImage?
    private var systemHashes: [String: String] = [:]

    init(bundle: ProjectBundle, input: InputRecorder) {
        self.bundle = bundle
        self.input = input
        // Fingerprints of standard cursors so we can render vector art later.
        let named: [(String, NSCursor)] = [
            ("arrow", .arrow), ("iBeam", .iBeam), ("pointingHand", .pointingHand), ("openHand", .openHand),
            ("closedHand", .closedHand), ("crosshair", .crosshair), ("resizeLeftRight", .resizeLeftRight),
            ("resizeUpDown", .resizeUpDown), ("operationNotAllowed", .operationNotAllowed), ("dragCopy", .dragCopy),
            ("contextualMenu", .contextualMenu), ("resizeLeft", .resizeLeft), ("resizeRight", .resizeRight),
            ("resizeUp", .resizeUp), ("resizeDown", .resizeDown),
        ]
        for (name, c) in named { if let h = Self.fingerprint(c) { systemHashes[h] = name } }
    }

    func start() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func sample() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        if image === lastImage, input?.cursorID != nil { return }
        lastImage = image
        guard let hash = Self.fingerprint(cursor) else { return }
        let id = String(hash.prefix(12))
        if known[id] == nil {
            let file = "\(id).png"
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let dest = CGImageDestinationCreateWithURL(bundle.cursorsFolder.appendingPathComponent(file) as CFURL,
                                                          UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil)
                CGImageDestinationFinalize(dest)
            }
            known[id] = CursorImageInfo(id: id, file: file, hotSpotX: cursor.hotSpot.x, hotSpotY: cursor.hotSpot.y,
                                        width: image.size.width, height: image.size.height, systemMatch: systemHashes[hash])
            writeIndex()
        }
        input?.cursorID = id
    }

    private func writeIndex() {
        if let data = try? TolerantJSON.encode(Array(known.values)) { try? data.write(to: bundle.cursorsIndexFile, options: .atomic) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        writeIndex()
    }

    /// Hash of the cursor's 1x bitmap plus hotspot.
    static func fingerprint(_ cursor: NSCursor) -> String? {
        let size = cursor.image.size
        guard size.width > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        cursor.image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data(bytes: data, count: rep.bytesPerRow * rep.pixelsHigh))
        hasher.update(data: Data("\(cursor.hotSpot.x),\(cursor.hotSpot.y)".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
