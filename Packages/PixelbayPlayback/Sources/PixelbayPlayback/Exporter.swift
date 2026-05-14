#if canImport(AVFoundation)
import AVFoundation
import Foundation
import OSLog
import Observation
import PixelbayCore

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "Exporter")

// Drives AVAssetExportSession against the same PreviewComposition the post-
// capture preview surface uses. Per HANDOFF §6.6: one render path for
// preview and export, never fork.
//
// Phase 1 ships a single preset — "High 1080p H.264 MP4". AVAssetExport's
// `AVAssetExportPreset1920x1080` produces ~10Mbps H.264 at 1080p, which is
// the spec from HANDOFF §4.10. Phase 4 adds the preset matrix.
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

    // Start an export. `outputURL` should not exist (AVAssetExportSession
    // refuses to overwrite). The composition + videoComposition come from
    // PreviewCompositionBuilder — pass the SAME instances you fed to the
    // PreviewPlayer.
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
        if FileManager.default.fileExists(atPath: outputURL.path) {
            do {
                try FileManager.default.removeItem(at: outputURL)
            } catch {
                status = .failed(message: "Could not overwrite existing file: \(error.localizedDescription)")
                return
            }
        }
        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPreset1920x1080
        ) else {
            status = .failed(message: "AVAssetExportSession could not be created with the 1080p preset")
            return
        }
        session.outputURL = outputURL
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
            try await session.export(to: outputURL, as: .mp4)
            stopProgressMonitor()
            status = .finished(outputURL)
            log.info("export complete url=\(outputURL.path, privacy: .public)")
        } catch {
            stopProgressMonitor()
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
