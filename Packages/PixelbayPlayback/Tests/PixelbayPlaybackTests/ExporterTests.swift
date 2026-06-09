import Foundation
@testable import PixelbayPlayback
import XCTest

final class ExporterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixelbay-exporter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testCommit_replacesExistingDestinationWithTempFile() throws {
        let output = tempDir.appendingPathComponent("movie.mp4")
        let temp = tempDir.appendingPathComponent("movie.tmp.mp4")
        try Data("old".utf8).write(to: output)
        try Data("new".utf8).write(to: temp)

        try ExportFileCommitter.commit(tempURL: temp, to: output)

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    func testCommit_movesTempFileWhenDestinationDoesNotExist() throws {
        let output = tempDir.appendingPathComponent("movie.mp4")
        let temp = tempDir.appendingPathComponent("movie.tmp.mp4")
        try Data("new".utf8).write(to: temp)

        try ExportFileCommitter.commit(tempURL: temp, to: output)

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    func testCommitFailure_preservesExistingDestination() throws {
        let output = tempDir.appendingPathComponent("movie.mp4")
        let missingTemp = tempDir.appendingPathComponent("missing.tmp.mp4")
        try Data("old".utf8).write(to: output)

        XCTAssertThrowsError(try ExportFileCommitter.commit(tempURL: missingTemp, to: output))

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "old")
    }
}
