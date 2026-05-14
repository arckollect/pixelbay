import Foundation
@testable import PixelbayInputCapture
import XCTest

final class ClickLoggerTests: XCTestCase {
    func test_logger_collectsEvents_emittedByFakeSource() async throws {
        let driver = FakeSource.Driver()
        let logger = ClickLogger(source: driver.source)
        try await logger.start()

        driver.fireClick(.init(timestamp: 1.0, x: 100, y: 200, button: .left))
        driver.fireClick(.init(timestamp: 1.5, x: 110, y: 210, button: .right))
        driver.fireClick(.init(timestamp: 2.0, x: 200, y: 300, button: .left))

        // Allow the actor's record task to drain — small sleep keeps the
        // test deterministic without exposing scheduling internals.
        try await Task.sleep(nanoseconds: 50_000_000)

        let recording = await logger.stop()
        // Sort by timestamp before asserting — the fake source delivers via
        // unstructured `Task { ... }` callbacks which Swift may reorder
        // relative to spawn order. The logger preserves the order moves
        // arrive in, so for a deterministic spec we re-key on the
        // monotonically-increasing host-clock timestamp the test fixture
        // assigns.
        let sortedClicks = recording.clicks.sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(sortedClicks.count, 3)
        XCTAssertEqual(sortedClicks[0].button, .left)
        XCTAssertEqual(sortedClicks[1].button, .right)
        XCTAssertEqual(sortedClicks[2].x, 200)
        XCTAssertTrue(recording.moves.isEmpty)
    }

    func test_logger_rejectsDoubleStart() async throws {
        let driver = FakeSource.Driver()
        let logger = ClickLogger(source: driver.source)
        try await logger.start()
        do {
            try await logger.start()
            XCTFail("Expected invalidState")
        } catch ClickLogger.LoggerError.invalidState {
            // expected
        }
        _ = await logger.stop()
    }

    func test_logger_dropsEventsAfterStop() async throws {
        let driver = FakeSource.Driver()
        let logger = ClickLogger(source: driver.source)
        try await logger.start()
        driver.fireClick(.init(timestamp: 1, x: 0, y: 0, button: .left))
        try await Task.sleep(nanoseconds: 30_000_000)
        let beforeStop = await logger.stop()
        XCTAssertEqual(beforeStop.clicks.count, 1)
        // Fire after stop — should be discarded.
        driver.fireClick(.init(timestamp: 2, x: 0, y: 0, button: .left))
        try await Task.sleep(nanoseconds: 30_000_000)
        let afterStop = await logger.collectedClicks
        XCTAssertEqual(afterStop.count, 1)
    }

    func test_logger_collectsMoves_decimatesUnderInterval() async throws {
        let driver = FakeSource.Driver()
        // Decimate to 100ms intervals for a deterministic test.
        let logger = ClickLogger(source: driver.source, moveDecimationInterval: 0.1)
        try await logger.start()

        // Five moves: t=1.00 kept (first), t=1.04 dropped (40ms < 100ms),
        // t=1.10 kept (100ms ≥ threshold), t=1.15 dropped, t=1.21 kept.
        driver.fireMove(.init(timestamp: 1.00, x: 10, y: 10))
        driver.fireMove(.init(timestamp: 1.04, x: 11, y: 11))
        driver.fireMove(.init(timestamp: 1.10, x: 20, y: 20))
        driver.fireMove(.init(timestamp: 1.15, x: 21, y: 21))
        driver.fireMove(.init(timestamp: 1.21, x: 30, y: 30))

        try await Task.sleep(nanoseconds: 100_000_000)

        let recording = await logger.stop()
        XCTAssertEqual(recording.moves.count, 3)
        XCTAssertEqual(recording.moves[0].x, 10)
        XCTAssertEqual(recording.moves[1].x, 20)
        XCTAssertEqual(recording.moves[2].x, 30)
        XCTAssertTrue(recording.clicks.isEmpty)
    }

    func test_logger_dropsMovesAfterStop() async throws {
        let driver = FakeSource.Driver()
        let logger = ClickLogger(source: driver.source, moveDecimationInterval: 0.0)
        try await logger.start()
        driver.fireMove(.init(timestamp: 0.5, x: 1, y: 1))
        try await Task.sleep(nanoseconds: 30_000_000)
        let beforeStop = await logger.stop()
        XCTAssertEqual(beforeStop.moves.count, 1)
        driver.fireMove(.init(timestamp: 0.6, x: 2, y: 2))
        try await Task.sleep(nanoseconds: 30_000_000)
        let after = await logger.collectedMoves
        XCTAssertEqual(after.count, 1)
    }

    func test_logger_clicksAndMoves_interleave() async throws {
        let driver = FakeSource.Driver()
        let logger = ClickLogger(source: driver.source, moveDecimationInterval: 0.0)
        try await logger.start()
        driver.fireMove(.init(timestamp: 1.0, x: 5, y: 5))
        driver.fireClick(.init(timestamp: 1.1, x: 5, y: 5, button: .left))
        driver.fireMove(.init(timestamp: 1.2, x: 6, y: 5))
        try await Task.sleep(nanoseconds: 100_000_000)
        let recording = await logger.stop()
        XCTAssertEqual(recording.clicks.count, 1)
        XCTAssertEqual(recording.moves.count, 2)
    }

    func test_sidecar_roundTripsThroughJSON_withMoves() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicks-roundtrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sidecar = ClicksSidecar(
            sessionID: "abcd1234",
            captureStart: 12345.6789,
            events: [
                ClickEvent(timestamp: 12350.1, x: 800, y: 600, button: .left),
                ClickEvent(timestamp: 12352.5, x: 50, y: 50, button: .right)
            ],
            moves: [
                MouseMove(timestamp: 12350.0, x: 810, y: 605),
                MouseMove(timestamp: 12350.1, x: 800, y: 600)
            ]
        )
        try ClicksSidecarStore.write(sidecar, to: tmp)

        let loaded = try ClicksSidecarStore.read(from: tmp)
        XCTAssertEqual(loaded, sidecar)
        XCTAssertEqual(loaded.version, ClicksSidecar.currentVersion)
        XCTAssertEqual(loaded.moves.count, 2)
    }

    func test_sidecar_decodesV1File_withoutMovesKey() throws {
        // A pre-v2 file written before the schema bump has no `moves` key.
        let v1JSON = """
        {
            "version": 1,
            "sessionID": "v1session",
            "captureStart": 100.0,
            "events": [
                {"timestamp": 101.0, "x": 5.0, "y": 6.0, "button": "left"}
            ]
        }
        """
        let data = v1JSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ClicksSidecar.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.events.count, 1)
        XCTAssertEqual(decoded.moves, [])
    }

    func test_sidecar_filename_isSessionScoped() {
        XCTAssertEqual(ClicksSidecarStore.filename(for: "abcd1234"), "clicks-abcd1234.json")
    }

    func test_write_isAtomic_replacesExistingFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicks-atomic-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let first = ClicksSidecar(sessionID: "v1", captureStart: 0, events: [])
        try ClicksSidecarStore.write(first, to: tmp)
        let second = ClicksSidecar(sessionID: "v2", captureStart: 1, events: [
            ClickEvent(timestamp: 1.5, x: 1, y: 2, button: .left)
        ])
        try ClicksSidecarStore.write(second, to: tmp)

        let loaded = try ClicksSidecarStore.read(from: tmp)
        XCTAssertEqual(loaded.sessionID, "v2")
        XCTAssertEqual(loaded.events.count, 1)

        // No leftover .tmp-* sibling.
        let parent = tmp.deletingLastPathComponent()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.hasPrefix(".\(tmp.lastPathComponent).tmp-") }
        XCTAssertEqual(leftovers, [], "Atomic write left temp debris")
    }

    func test_clickEvent_codable_roundTrip() throws {
        let event = ClickEvent(timestamp: 12.5, x: 800.5, y: 600.25, button: .right)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ClickEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }

    func test_mouseMove_codable_roundTrip() throws {
        let move = MouseMove(timestamp: 12.5, x: 800.5, y: 600.25)
        let data = try JSONEncoder().encode(move)
        let decoded = try JSONDecoder().decode(MouseMove.self, from: data)
        XCTAssertEqual(decoded, move)
    }

    func test_zoomMark_codable_roundTrip() throws {
        let mark = ZoomMark(timestamp: 42.0, x: 0.25, y: 0.75)
        let data = try JSONEncoder().encode(mark)
        let decoded = try JSONDecoder().decode(ZoomMark.self, from: data)
        XCTAssertEqual(decoded, mark)
    }

    func test_sidecar_v4_marksRoundTripThroughJSON() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicks-marks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sidecar = ClicksSidecar(
            sessionID: "marks-session",
            captureStart: 100.0,
            events: [ClickEvent(timestamp: 101.0, x: 0.5, y: 0.5, button: .left)],
            moves: [MouseMove(timestamp: 100.5, x: 0.4, y: 0.4)],
            marks: [
                ZoomMark(timestamp: 102.5, x: 0.6, y: 0.7),
                ZoomMark(timestamp: 105.0, x: 0.2, y: 0.3)
            ]
        )
        try ClicksSidecarStore.write(sidecar, to: tmp)
        let loaded = try ClicksSidecarStore.read(from: tmp)
        XCTAssertEqual(loaded, sidecar)
        XCTAssertEqual(loaded.version, 4)
        XCTAssertEqual(loaded.marks.count, 2)
    }

    func test_sidecar_v3_decodesWithEmptyMarks() throws {
        // Pre-v4 file written before the marks bump has no `marks` key.
        // Must decode cleanly with `marks == []`.
        let v3JSON = """
        {
            "version": 3,
            "sessionID": "v3session",
            "captureStart": 100.0,
            "events": [{"timestamp": 101.0, "x": 0.5, "y": 0.5, "button": "left"}],
            "moves": [{"timestamp": 100.5, "x": 0.4, "y": 0.4}]
        }
        """
        let decoded = try JSONDecoder().decode(ClicksSidecar.self, from: Data(v3JSON.utf8))
        XCTAssertEqual(decoded.version, 3)
        XCTAssertEqual(decoded.marks, [])
    }

    // MARK: - Manual zoom marks (slice #11.d)

    func test_logger_recordMark_normalisesAndIncludesInRecording() async throws {
        let driver = FakeSource.Driver()
        let logger = ClickLogger(
            source: driver.source,
            displayPointsBounds: CGRect(x: 0, y: 0, width: 1512, height: 982)
        )
        try await logger.start()

        // Mark at the centre of the screen → (0.5, 0.5).
        await logger.recordMark(at: 42.0, x: 756, y: 491)
        await logger.recordMark(at: 43.0, x: 1512, y: 982)

        let recording = await logger.stop()
        XCTAssertEqual(recording.marks.count, 2)
        XCTAssertEqual(recording.marks[0].timestamp, 42.0, accuracy: 0.0001)
        XCTAssertEqual(recording.marks[0].x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(recording.marks[0].y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(recording.marks[1].x, 1.0, accuracy: 0.0001)
        XCTAssertEqual(recording.marks[1].y, 1.0, accuracy: 0.0001)
    }

    func test_logger_recordMark_droppedBeforeStartAndAfterStop() async throws {
        let driver = FakeSource.Driver()
        let logger = ClickLogger(source: driver.source)

        // Before start → silently ignored.
        await logger.recordMark(at: 1.0, x: 100, y: 100)

        try await logger.start()
        await logger.recordMark(at: 2.0, x: 200, y: 200)
        let recording = await logger.stop()
        XCTAssertEqual(recording.marks.count, 1)

        // After stop → silently ignored, doesn't grow the array.
        await logger.recordMark(at: 3.0, x: 300, y: 300)
        let collected = await logger.collectedMarks
        XCTAssertEqual(collected.count, 1)
    }

    // MARK: - Coordinate normalisation (v3 sidecar fix)

    func test_logger_normalisesClicks_whenDisplayBoundsProvided() async throws {
        let driver = FakeSource.Driver()
        // 14" MacBook Pro points at origin (0, 0): 1512 × 982. Cursor at exact
        // centre of the screen should normalise to (0.5, 0.5).
        let logger = ClickLogger(
            source: driver.source,
            displayPointsBounds: CGRect(x: 0, y: 0, width: 1512, height: 982)
        )
        try await logger.start()

        driver.fireClick(.init(timestamp: 1.0, x: 756, y: 491, button: .left))
        driver.fireClick(.init(timestamp: 2.0, x: 1512, y: 982, button: .left))
        driver.fireClick(.init(timestamp: 3.0, x: 0, y: 0, button: .left))

        try await Task.sleep(nanoseconds: 50_000_000)

        let recording = await logger.stop()
        // Sort by timestamp — fakeSource fires via Task { ... } so the order
        // events land in the actor isn't guaranteed (same race the
        // collectsEvents test works around).
        let sorted = recording.clicks.sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(sorted.count, 3)
        XCTAssertEqual(sorted[0].x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(sorted[0].y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(sorted[1].x, 1.0, accuracy: 0.0001)
        XCTAssertEqual(sorted[1].y, 1.0, accuracy: 0.0001)
        XCTAssertEqual(sorted[2].x, 0.0, accuracy: 0.0001)
        XCTAssertEqual(sorted[2].y, 0.0, accuracy: 0.0001)
    }

    func test_logger_normalisesAgainstDisplayOrigin_forSecondaryDisplay() async throws {
        let driver = FakeSource.Driver()
        // Secondary display positioned to the LEFT of the main display:
        // its frame in global points is (-1920, 0, 1920, 1080). Without the
        // origin subtraction every event's x would clamp to 0 (the bug that
        // produced the all-x=0 sidecar on 2026-05-13).
        let logger = ClickLogger(
            source: driver.source,
            moveDecimationInterval: 0.0,
            displayPointsBounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        )
        try await logger.start()

        // Cursor at centre of the secondary display: global (-960, 540).
        driver.fireClick(.init(timestamp: 1.0, x: -960, y: 540, button: .left))
        // Right edge of the secondary display: global (-1, 540) — normalises
        // to (~1.0, 0.5) (we subtract the origin first, then divide).
        driver.fireMove(.init(timestamp: 1.5, x: -1, y: 540))

        try await Task.sleep(nanoseconds: 50_000_000)

        let recording = await logger.stop()
        XCTAssertEqual(recording.clicks.count, 1)
        XCTAssertEqual(recording.clicks[0].x, 0.5, accuracy: 0.001)
        XCTAssertEqual(recording.clicks[0].y, 0.5, accuracy: 0.001)
        XCTAssertEqual(recording.moves.count, 1)
        XCTAssertEqual(recording.moves[0].x, (1920.0 - 1.0) / 1920.0, accuracy: 0.001)
        XCTAssertEqual(recording.moves[0].y, 0.5, accuracy: 0.001)
    }

    func test_logger_clampsOutOfBoundsCoordinates_whenNormalising() async throws {
        let driver = FakeSource.Driver()
        let logger = ClickLogger(
            source: driver.source,
            moveDecimationInterval: 0.0,
            displayPointsBounds: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        try await logger.start()

        // A click on an adjacent display in a multi-monitor setup lands well
        // outside the recorded display's bounds — must clamp to the edge,
        // not propagate negative / >1 values into the keyframe centre.
        driver.fireClick(.init(timestamp: 1.0, x: -50, y: 900, button: .left))
        driver.fireMove(.init(timestamp: 1.5, x: 1500, y: -10))

        try await Task.sleep(nanoseconds: 50_000_000)

        let recording = await logger.stop()
        XCTAssertEqual(recording.clicks.count, 1)
        XCTAssertEqual(recording.clicks[0].x, 0.0, accuracy: 0.0001)
        XCTAssertEqual(recording.clicks[0].y, 1.0, accuracy: 0.0001)
        XCTAssertEqual(recording.moves.count, 1)
        XCTAssertEqual(recording.moves[0].x, 1.0, accuracy: 0.0001)
        XCTAssertEqual(recording.moves[0].y, 0.0, accuracy: 0.0001)
    }

    func test_logger_passesRawCoordinatesThrough_whenDisplayBoundsNil() async throws {
        let driver = FakeSource.Driver()
        // Default init keeps displayPointsBounds nil (legacy behaviour).
        let logger = ClickLogger(source: driver.source)
        try await logger.start()
        driver.fireClick(.init(timestamp: 1.0, x: 800, y: 600, button: .left))
        try await Task.sleep(nanoseconds: 50_000_000)
        let recording = await logger.stop()
        XCTAssertEqual(recording.clicks[0].x, 800)
        XCTAssertEqual(recording.clicks[0].y, 600)
    }

    func test_logger_skipsNormalisation_whenDisplayBoundsDegenerate() async throws {
        let driver = FakeSource.Driver()
        let logger = ClickLogger(
            source: driver.source,
            displayPointsBounds: CGRect(x: 0, y: 0, width: 0, height: 0)
        )
        try await logger.start()
        driver.fireClick(.init(timestamp: 1.0, x: 800, y: 600, button: .left))
        try await Task.sleep(nanoseconds: 50_000_000)
        let recording = await logger.stop()
        // Degenerate size short-circuits the normaliser — passes raw points
        // through rather than producing NaN. The editor's v2-style divide
        // path will catch this on read.
        XCTAssertEqual(recording.clicks[0].x, 800)
        XCTAssertEqual(recording.clicks[0].y, 600)
    }
}

// Programmable test double — mirrors the shape used by FakeCaptureBackend
// in PixelbayCaptureTests. Driver is a class so the test can call `.fire`
// even after handing the source to the logger by value.
private enum FakeSource {
    final class Driver: @unchecked Sendable {
        private let lock = NSLock()
        private var clickSink: (@Sendable (ClickEvent) -> Void)?
        private var moveSink: (@Sendable (MouseMove) -> Void)?

        var source: ClickEventSource {
            ClickEventSource(
                start: { [weak self] onClick, onMove in
                    self?.lock.lock()
                    self?.clickSink = onClick
                    self?.moveSink = onMove
                    self?.lock.unlock()
                },
                stop: { [weak self] in
                    self?.lock.lock()
                    self?.clickSink = nil
                    self?.moveSink = nil
                    self?.lock.unlock()
                }
            )
        }

        func fireClick(_ event: ClickEvent) {
            lock.lock()
            let sink = self.clickSink
            lock.unlock()
            sink?(event)
        }

        func fireMove(_ move: MouseMove) {
            lock.lock()
            let sink = self.moveSink
            lock.unlock()
            sink?(move)
        }
    }
}
