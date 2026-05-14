import Foundation
#if canImport(CoreGraphics) && canImport(ApplicationServices)
import ApplicationServices
import CoreGraphics
#endif

// Sendable shim over CGEventTap, same shape as PermissionProbe in
// PixelbayPermissions and ShareableContentLookup in PixelbayCapture
// (HANDOFF §6.1's canonical pattern). The live impl creates a real
// system-level event tap; tests build a programmable fake whose
// `start` synchronously fires synthetic events.
//
// CGEventTap requires the Accessibility permission. The app layer is
// responsible for gating the picker's "Log clicks" toggle on the
// PermissionCoordinator's accessibility status.
//
// The tap emits two streams: discrete clicks (left/right mouse-down) and
// continuous mouse-move samples (covers .mouseMoved + .leftMouseDragged +
// .rightMouseDragged). Both share one underlying CGEventTap so we only pay
// one mask-evaluation pass per event in the live impl.
public struct ClickEventSource: Sendable {
    public var start: @Sendable (
        @escaping @Sendable (ClickEvent) -> Void,
        @escaping @Sendable (MouseMove) -> Void
    ) throws -> Void
    public var stop: @Sendable () -> Void

    public init(
        start: @escaping @Sendable (
            @escaping @Sendable (ClickEvent) -> Void,
            @escaping @Sendable (MouseMove) -> Void
        ) throws -> Void,
        stop: @escaping @Sendable () -> Void
    ) {
        self.start = start
        self.stop = stop
    }
}

#if canImport(CoreGraphics) && canImport(ApplicationServices)

public extension ClickEventSource {
    static let live: ClickEventSource = {
        let storage = LiveTapStorage()
        return ClickEventSource(
            start: { onClick, onMove in
                try storage.start(onClick: onClick, onMove: onMove)
            },
            stop: {
                storage.stop()
            }
        )
    }()
}

public enum ClickEventSourceError: Error, LocalizedError {
    case alreadyRunning
    case tapCreationFailed
    case runLoopSourceUnavailable
    case accessibilityNotTrusted

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "ClickEventSource is already running."
        case .tapCreationFailed: return "Could not create the system-wide event tap."
        case .runLoopSourceUnavailable: return "Could not register the event tap with the run loop."
        case .accessibilityNotTrusted: return "Accessibility permission not granted; click logging requires it."
        }
    }
}

// CGEventTap is C-level — the callback is a function pointer that gets a
// raw pointer back. We park the per-tap state in an Unmanaged-bridged
// reference so the callback can find its way back to Swift. The class
// itself is final + @unchecked Sendable; mutation is serialised by the
// fact that start/stop are called from a single thread (the main actor).
private final class LiveTapStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onClick: (@Sendable (ClickEvent) -> Void)?
    private var onMove: (@Sendable (MouseMove) -> Void)?
    private var runLoop: CFRunLoop?

    func start(
        onClick: @escaping @Sendable (ClickEvent) -> Void,
        onMove: @escaping @Sendable (MouseMove) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        if port != nil {
            throw ClickEventSourceError.alreadyRunning
        }
        guard AXIsProcessTrusted() else {
            throw ClickEventSourceError.accessibilityNotTrusted
        }

        self.onClick = onClick
        self.onMove = onMove

        let mask = (1 << CGEventType.leftMouseDown.rawValue)
                 | (1 << CGEventType.rightMouseDown.rawValue)
                 | (1 << CGEventType.mouseMoved.rawValue)
                 | (1 << CGEventType.leftMouseDragged.rawValue)
                 | (1 << CGEventType.rightMouseDragged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let storage = Unmanaged<LiveTapStorage>.fromOpaque(userInfo).takeUnretainedValue()
                storage.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            self.onClick = nil
            self.onMove = nil
            throw ClickEventSourceError.tapCreationFailed
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.onClick = nil
            self.onMove = nil
            throw ClickEventSourceError.runLoopSourceUnavailable
        }
        let runLoop = CFRunLoopGetMain()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.port = tap
        self.runLoopSource = source
        self.runLoop = runLoop
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let source = runLoopSource, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        if let tap = port {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        port = nil
        runLoopSource = nil
        runLoop = nil
        onClick = nil
        onMove = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        let onClick: (@Sendable (ClickEvent) -> Void)?
        let onMove: (@Sendable (MouseMove) -> Void)?
        lock.lock()
        onClick = self.onClick
        onMove = self.onMove
        lock.unlock()
        let location = event.location
        let timestamp = Double(event.timestamp) / 1_000_000_000.0
        switch type {
        case .leftMouseDown:
            onClick?(ClickEvent(timestamp: timestamp, x: Double(location.x), y: Double(location.y), button: .left))
        case .rightMouseDown:
            onClick?(ClickEvent(timestamp: timestamp, x: Double(location.x), y: Double(location.y), button: .right))
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            onMove?(MouseMove(timestamp: timestamp, x: Double(location.x), y: Double(location.y)))
        default:
            return
        }
    }
}

#else

public extension ClickEventSource {
    static let live: ClickEventSource = ClickEventSource(
        start: { _, _ in throw NSError(domain: "PixelbayInputCapture", code: 0, userInfo: [NSLocalizedDescriptionKey: "ClickEventSource.live unavailable on this platform"]) },
        stop: {}
    )
}

#endif
