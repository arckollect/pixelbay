#if canImport(AVFoundation)
import AVFoundation
import Foundation
import OSLog
import Observation
import PixelbayCore

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "Exporter")

enum ExportFileCommitter {
    static func temporaryURL(for outputURL: URL) -> URL {
        let directory = outputURL.deletingLastPathComponent()
        let basename = outputURL.deletingPathExtension().lastPathComponent
        let ext = outputURL.pathExtension.isEmpty ? "mp4" : outputURL.pathExtension
        return directory.appendingPathComponent(".\(basename)-\(UUID().uuidString).tmp.\(ext)")
    }

    static func commit(tempURL: URL, to outputURL: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: outputURL)
        }
    }

    static func discard(_ tempURL: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: tempURL.path) else { return }
        try? fileManager.removeItem(at: tempURL)
    }
}

// Drives AVAssetExportSession against the same PreviewComposition the post-
// capture preview surface uses. Per HANDOFF §6.6: one render path for
// preview and export, never fork.
//
// Single export path for now: highest-quality MP4 from the preview
// composition. The render size comes from PreviewCompositionBuilder, so this
// preserves UHD output when the source recording has enough detail.
@MainActor
@Observable
public final class Exporter {
    public enum Status: Equatable {
        case idle
        case preparing
        case exporting(progress: Double)
        case finished(URL)
        case failed(message: String)
        case cancelled
    }

    public private(set) var status: Status = .idle

    private var session: AVAssetExportSession?
    private var progressTask: Task<Void, Never>?

    public init() {}

    // Start an export. AVAssetExportSession refuses to overwrite, so export
    // to a sibling temp file first and only replace the requested destination
    // after the new export succeeds. This preserves an existing MP4 if the
    // replacement export fails or is cancelled.
    public func export(
        composition: AVComposition,
        videoComposition: AVVideoComposition?,
        audioMix: AVAudioMix?,
        to outputURL: URL
    ) async {
        guard isStartable else {
            log.notice("export() called in non-idle status=\(String(describing: self.status), privacy: .public)")
            return
        }
        status = .preparing
        let tempURL = ExportFileCommitter.temporaryURL(for: outputURL)
        ExportFileCommitter.discard(tempURL)
        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            status = .failed(message: "AVAssetExportSession could not be created with the highest-quality preset")
            return
        }
        session.outputURL = tempURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        if let videoComposition {
            session.videoComposition = videoComposition
        }
        if let audioMix {
            session.audioMix = audioMix
        }
        self.session = session

        startProgressMonitor()
        do {
            try await session.export(to: tempURL, as: .mp4)
            try ExportFileCommitter.commit(tempURL: tempURL, to: outputURL)
            stopProgressMonitor()
            status = .finished(outputURL)
            log.info("export complete url=\(outputURL.path, privacy: .public)")
        } catch {
            stopProgressMonitor()
            ExportFileCommitter.discard(tempURL)
            if Task.isCancelled || isCancellation(error) {
                status = .cancelled
            } else {
                status = .failed(message: error.localizedDescription)
            }
            log.error("export failed: \(String(describing: error), privacy: .public)")
        }
        self.session = nil
    }

    public func cancel() {
        // cancelExport() interrupts the in-flight async export(to:as:);
        // the catch block above maps the resulting error via
        // isCancellation(_:) to status = .cancelled. (Swift 6 prevents us
        // from also wiring this through `withTaskCancellationHandler`
        // because AVAssetExportSession isn't Sendable; for v0.1 the
        // single-path cancel via cancelExport() is sufficient.)
        session?.cancelExport()
    }

    public func acknowledge() {
        if case .finished = status {
            status = .idle
        } else if case .failed = status {
            status = .idle
        } else if status == .cancelled {
            status = .idle
        }
    }

    // MARK: - Helpers

    private var isStartable: Bool {
        switch status {
        case .idle, .finished, .failed, .cancelled: return true
        default: return false
        }
    }

    private func startProgressMonitor() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                guard let session = self.session else { return }
                let progress = Double(session.progress)
                if case .preparing = self.status {
                    self.status = .exporting(progress: progress)
                } else if case .exporting = self.status {
                    self.status = .exporting(progress: progress)
                }
            }
        }
    }

    private func stopProgressMonitor() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
            || nsError.domain == AVFoundationErrorDomain && nsError.code == AVError.exportFailed.rawValue && session?.status == .cancelled
    }
}
#endif
