import AVFoundation
import Foundation
import PixelbayCore
import PixelbayEditor
import PixelbayInputCapture

// App-target glue: load the cursor trajectory from a project's clicks
// sidecar so PreviewCompositionBuilder.build / PreviewPlayer.load can
// re-slice each zoom keyframe's trajectory against its CURRENT timeline
// range at composition build time. Without re-slicing, dragging a zoom
// keyframe's right edge to extend the hold window doesn't extend cursor-
// follow — the slice stored on the keyframe only covers samples in the
// originally-generated range, and the evaluator clamps to the last
// stored sample.
//
// Three call sites use this (ProjectView's .task, PostCaptureView's load
// path, ExportSheet.runExport) so it lives here rather than being
// inlined three times.

enum CursorTrajectoryLoader {

    /// Returns the master cursor trajectory for `project`, or nil when
    /// there's no screen asset, no sidecar, or the sidecar carries no
    /// mouse-move samples. Silent on errors: any I/O failure returns nil
    /// so the preview still loads — cursor-follow simply falls back to
    /// the per-keyframe stored slice (or, when that's nil/empty, the
    /// static centre).
    static func load(
        for project: Project,
        bundleURL: URL
    ) async -> [MouseTrajectorySample]? {
        guard let asset = AutoZoomService.screenAsset(in: project) else { return nil }
        guard let sidecarURL = AutoZoomService.clicksSidecarURL(
            forScreenAsset: asset,
            in: bundleURL
        ) else { return nil }
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return nil }
        do {
            let sidecar = try ClicksSidecarStore.read(from: sidecarURL)
            guard !sidecar.moves.isEmpty else { return nil }
            let assetURL = bundleURL.appendingPathComponent(asset.relativePath)
            let avAsset = AVURLAsset(url: assetURL)
            let videoTracks = try await avAsset.loadTracks(withMediaType: .video)
            let naturalSize: CGSize
            if let track = videoTracks.first {
                naturalSize = try await track.load(.naturalSize)
            } else {
                naturalSize = .zero
            }
            let master = AutoZoomService.mouseTrajectory(
                from: sidecar,
                screenPixelSize: naturalSize
            )
            return master.isEmpty ? nil : master
        } catch {
            return nil
        }
    }
}
