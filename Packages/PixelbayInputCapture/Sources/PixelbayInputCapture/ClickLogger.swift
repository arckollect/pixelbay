import CoreGraphics
import Foundation
import OSLog

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "ClickLogger")

// Owns the ClickEventSource lifecycle and accumulates the events into an
// array we hand back when the recording stops. Single-use per recording —
// caller constructs a fresh instance each time, mirroring CaptureSession.
//
// Concurrency: actor — the source's callback closure is `@Sendable` and
// can fire on whatever queue the live impl uses (CFRunLoopGetMain in
// production). We hop into the actor via Task to record the event.
public actor ClickLogger {
    public enum LoggerError: Error {
        case invalidState(String)
    }

    public struct Recording: Sendable, Equatable {
        public var clicks: [ClickEvent]
        public var moves: [MouseMove]
        public var marks: [ZoomMark]

        public init(clicks: [ClickEvent], moves: [MouseMove], marks: [ZoomMark] = []) {
            self.clicks = clicks
            self.moves = moves
            self.marks = marks
        }
    }

    private enum Phase: Equatable {
        case idle
        case running
        case stopped
    }

    private enum PendingEvent: Sendable {
        case click(ClickEvent)
        case move(MouseMove)
    }

    private let source: ClickEventSource
    private let pendingEvents = PendingEventBuffer<PendingEvent>()
    /// Minimum host-clock seconds between consecutive emitted moves.
    /// Default 1/120 s — slightly above the 60 fps preview / export
    /// frame rate so every rendered frame has at least one fresh sample
    /// inside its Catmull-Rom interpolation window. Older builds used
    /// 1/30 s, which left ~half the rendered frames interpolating across
    /// a 33 ms gap and read as a choppy cursor at the default sprite
    /// scale. Sidecar size grows ~4× at native rates but is still
    /// negligible (text JSON, ~50 bytes/sample).
    private let moveDecimationInterval: TimeInterval
    /// Recorded display's **bounds in global points** (origin + size in the
    /// same coordinate space `CGEvent.location` reports). When set, the logger
    /// normalises every recorded x/y to `[0…1]` against this rect by first
    /// subtracting the origin and then dividing by the size, clamping out-of-
    /// bounds samples (clicks on adjacent displays in a multi-monitor setup)
    /// to the edge. The origin is essential: secondary displays positioned
    /// to the left of / above the main display have negative global coords,
    /// and dividing by size alone collapses them to 0. Sidecars written this
    /// way carry `ClicksSidecar.version >= 3`. Nil for tests + the legacy
    /// capture path that wrote raw global points (v1 / v2 sidecars), which
    /// `AutoZoomService` still tolerates by dividing by the recording's pixel
    /// size.
    private let displayPointsBounds: CGRect?
    /// Optional alternative to the ⌃⌘Z hotkey: drawing a small circle with
    /// the cursor during a recording also emits a `ZoomMark` (slice #11.e).
    /// Operates on already-normalised coords (post-`displayPointsBounds`
    /// normalisation) so the thresholds are in `[0…1]` units across all
    /// displays. Nil disables the gesture path entirely (used by tests that
    /// want deterministic mark counts and by callers that don't want the
    /// auto-trigger).
    private var gestureDetector: CircleGestureDetector?
    /// Second optional motion gesture: rapid back-and-forth shake / wiggle
    /// also emits a `ZoomMark` — parallels macOS's "shake to find cursor"
    /// pattern. Like `gestureDetector`, runs on post-normalisation coords
    /// so thresholds are in `[0…1]` units. Nil disables the shake path.
    private var shakeDetector: ShakeGestureDetector?
    private var phase: Phase = .idle
    private var clicks: [ClickEvent] = []
    private var moves: [MouseMove] = []
    private var marks: [ZoomMark] = []
    private var lastEmittedMoveTimestamp: Double?

    public init(
        source: ClickEventSource = .live,
        moveDecimationInterval: TimeInterval = 1.0 / 120.0,
        displayPointsBounds: CGRect? = nil,
        gestureDetector: CircleGestureDetector? = nil,
        shakeDetector: ShakeGestureDetector? = nil
    ) {
        self.source = source
        self.moveDecimationInterval = moveDecimationInterval
        self.displayPointsBounds = displayPointsBounds
        self.gestureDetector = gestureDetector
        self.shakeDetector = shakeDetector
    }

    public func start() throws {
        guard phase == .idle else {
            throw LoggerError.invalidState("ClickLogger is single-use; start() called twice")
        }
        let pendingEvents = self.pendingEvents
        try source.start(
            { [weak self] click in
                guard let self else { return }
                if pendingEvents.append(.click(click)) {
                    Task { await self.drainPendingEvents() }
                }
            },
            { [weak self] move in
                guard let self else { return }
                if pendingEvents.append(.move(move)) {
                    Task { await self.drainPendingEvents() }
                }
            }
        )
        phase = .running
        log.info("ClickLogger started (move decimation \(self.moveDecimationInterval, format: .fixed(precision: 4))s)")
    }

    public func stop() -> Recording {
        guard phase == .running else {
            return Recording(clicks: clicks, moves: moves, marks: marks)
        }
        source.stop()
        drainPendingEvents()
        phase = .stopped
        log.info("ClickLogger stopped — clicks=\(self.clicks.count) moves=\(self.moves.count) marks=\(self.marks.count)")
        return Recording(clicks: clicks, moves: moves, marks: marks)
    }

    public var collectedClicks: [ClickEvent] { clicks }
    public var collectedMoves: [MouseMove] { moves }
    public var collectedMarks: [ZoomMark] { marks }

    /// Append a user-stated zoom anchor at the given host-clock timestamp +
    /// cursor position (in the same global-points space as `CGEvent.location`).
    /// Normalised against `displayPointsBounds` on the way in, mirroring the
    /// click/move path. Best-effort: silently no-ops when the logger isn't
    /// running so a hotkey press outside the recording session can't crash.
    public func recordMark(at timestamp: Double, x: Double, y: Double) {
        guard phase == .running else { return }
        marks.append(normalize(ZoomMark(timestamp: timestamp, x: x, y: y, source: .hotkey)))
    }

    private func recordClick(_ event: ClickEvent) {
        guard phase == .running else { return }
        clicks.append(normalize(event))
    }

    private func drainPendingEvents() {
        while let event = pendingEvents.pop() {
            switch event {
            case .click(let click):
                recordClick(click)
            case .move(let move):
                recordMove(move)
            }
        }
        if pendingEvents.finishDraining() {
            drainPendingEvents()
        }
    }

    private func recordMove(_ move: MouseMove) {
        guard phase == .running else { return }
        if let last = lastEmittedMoveTimestamp,
           move.timestamp - last < moveDecimationInterval {
            return
        }
        lastEmittedMoveTimestamp = move.timestamp
        let normalised = normalize(move)
        moves.append(normalised)
        feedGestureDetector(normalised)
        feedShakeDetector(normalised)
    }

    private func feedShakeDetector(_ move: MouseMove) {
        guard var detector = shakeDetector else { return }
        let detection = detector.ingest(
            ShakeGestureDetector.Sample(
                timestamp: move.timestamp,
                x: move.x,
                y: move.y
            )
        )
        shakeDetector = detector
        guard let detection else { return }
        marks.append(
            ZoomMark(
                timestamp: detection.timestamp,
                x: detection.x,
                y: detection.y,
                source: .shakeGesture
            )
        )
        log.info("shake gesture mark logged at (\(detection.x, format: .fixed(precision: 3)), \(detection.y, format: .fixed(precision: 3))) reversals=\(detection.reversals)")
    }

    private func feedGestureDetector(_ move: MouseMove) {
        guard var detector = gestureDetector else { return }
        let detection = detector.ingest(
            CircleGestureDetector.Sample(
                timestamp: move.timestamp,
                x: move.x,
                y: move.y
            )
        )
        gestureDetector = detector
        guard let detection else { return }
        // Coords already live in normalised [0…1] space because we feed the
        // detector AFTER the normaliser — skip the recordMark normalise hop
        // and append directly. (Going through recordMark would re-divide by
        // displayPointsBounds, producing a sliver-near-zero value.)
        marks.append(
            ZoomMark(
                timestamp: detection.timestamp,
                x: detection.x,
                y: detection.y,
                source: .circleGesture
            )
        )
        log.info("circle gesture mark logged at (\(detection.x, format: .fixed(precision: 3)), \(detection.y, format: .fixed(precision: 3))) r=\(detection.radius, format: .fixed(precision: 3))")
    }

    private func normalize(_ event: ClickEvent) -> ClickEvent {
        guard let bounds = displayPointsBounds,
              bounds.size.width > 0,
              bounds.size.height > 0 else {
            return event
        }
        return ClickEvent(
            timestamp: event.timestamp,
            x: clamp01((event.x - Double(bounds.origin.x)) / Double(bounds.size.width)),
            y: clamp01((event.y - Double(bounds.origin.y)) / Double(bounds.size.height)),
            button: event.button
        )
    }

    private func normalize(_ move: MouseMove) -> MouseMove {
        guard let bounds = displayPointsBounds,
              bounds.size.width > 0,
              bounds.size.height > 0 else {
            return move
        }
        return MouseMove(
            timestamp: move.timestamp,
            x: clamp01((move.x - Double(bounds.origin.x)) / Double(bounds.size.width)),
            y: clamp01((move.y - Double(bounds.origin.y)) / Double(bounds.size.height))
        )
    }

    private func normalize(_ mark: ZoomMark) -> ZoomMark {
        guard let bounds = displayPointsBounds,
              bounds.size.width > 0,
              bounds.size.height > 0 else {
            return mark
        }
        return ZoomMark(
            timestamp: mark.timestamp,
            x: clamp01((mark.x - Double(bounds.origin.x)) / Double(bounds.size.width)),
            y: clamp01((mark.y - Double(bounds.origin.y)) / Double(bounds.size.height)),
            source: mark.source
        )
    }
}

private final class PendingEventBuffer<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Event] = []
    private var head = 0
    private var isDraining = false

    /// Appends in callback order. Returns true when the caller should schedule
    /// a drain task; false means a drain is already active and will pick this
    /// event up.
    func append(_ event: Event) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
        guard !isDraining else { return false }
        isDraining = true
        return true
    }

    func pop() -> Event? {
        lock.lock()
        defer { lock.unlock() }
        guard head < events.count else { return nil }
        let event = events[head]
        head += 1
        if head > 256, head * 2 > events.count {
            events.removeFirst(head)
            head = 0
        }
        return event
    }

    /// Marks the current drain pass complete. Returns true if more events were
    /// appended between the final pop and this call, so the actor should keep
    /// draining without waiting for another callback to schedule it.
    func finishDraining() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if head >= events.count {
            events.removeAll(keepingCapacity: true)
            head = 0
            isDraining = false
            return false
        }
        return true
    }
}

private func clamp01(_ value: Double) -> Double {
    if value.isNaN { return 0.5 }
    return min(max(value, 0), 1)
}

// On-disk shape: `media/clicks-<sessionID>.json` per HANDOFF §2.4. Atomic
// write via temp + rename so a crash mid-write leaves the previous file
// intact.
public enum ClicksSidecarStore {
    public static func filename(for sessionID: String) -> String {
        "clicks-\(sessionID).json"
    }

    public static func write(_ sidecar: ClicksSidecar, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sidecar)
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    public static func read(from url: URL) throws -> ClicksSidecar {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ClicksSidecar.self, from: data)
    }
}
