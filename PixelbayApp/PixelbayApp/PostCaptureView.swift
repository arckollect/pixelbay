import AppKit
import CoreMedia
import Foundation
import PixelbayCapture
import PixelbayCore
import PixelbayPlayback
import SwiftUI

// Post-capture screen. Builds a Project from the .pixelbay bundle's
// project.json, loads it into a PreviewPlayer (via PreviewCompositionBuilder),
// and renders the play surface + scrub. Reveal in Finder / Open / New
// Recording stay available; the per-track stats panel becomes a collapsible
// "Recording details" section so the preview gets the visual focus.
//
// Per HANDOFF §6.6 the same composition drives the export sheet — we never
// fork preview vs export.
struct PostCaptureView: View {
    let result: RecordingService.Result
    var onNewRecording: () -> Void
    var onEditProject: (URL) -> Void

    @State private var player = PreviewPlayer()
    @State private var showsDetails: Bool = false
    @State private var showsExport: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerRow
            if !result.writerErrors.isEmpty {
                writerErrorsPanel
            }
            previewSurface
            actionsRow
            DisclosureGroup("Recording details", isExpanded: $showsDetails) {
                fileList.padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(minWidth: 720, minHeight: 540)
        .task(id: result.bundleURL) {
            await loadIntoPlayer()
        }
        .onDisappear {
            player.dispose()
        }
        .sheet(isPresented: $showsExport) {
            ExportSheet(result: result) {
                showsExport = false
            }
        }
    }

    @ViewBuilder
    private var previewSurface: some View {
        switch player.status {
        case .idle, .loading:
            previewPlaceholder("Preparing preview…", isLoading: true)
        case .failed(let message):
            previewPlaceholder("Preview unavailable: \(message)", isLoading: false)
        case .ready:
            VStack(spacing: 8) {
                PreviewPlayerView(player: player)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 6))
                    .frame(minHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                playbackControls
            }
        }
    }

    private func previewPlaceholder(_ text: String, isLoading: Bool) -> some View {
        HStack(spacing: 12) {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .center)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 24, height: 18)
            }
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            Text(formatTime(player.currentTime.seconds))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Slider(
                value: Binding<Double>(
                    get: {
                        guard player.duration.seconds > 0 else { return 0 }
                        return player.currentTime.seconds / player.duration.seconds
                    },
                    set: { player.seekFraction($0) }
                ),
                in: 0...1
            )
            Text(formatTime(player.duration.seconds))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func loadIntoPlayer() async {
        let store = ProjectBundleStore()
        let bundle = ProjectBundle(url: result.bundleURL)
        do {
            let project = try store.loadProject(from: bundle)
            let cursorTrajectory = await CursorTrajectoryLoader.load(
                for: project,
                bundleURL: bundle.url
            )
            await player.load(
                project: project,
                bundleURL: bundle.url,
                wallpaperSource: .live,
                cursorTrajectory: cursorTrajectory
            )
        } catch {
            await MainActor.run {
                // PreviewPlayer's own status will surface a more informative
                // error if the load itself fails; this catch handles the
                // rare project.json read miss.
            }
        }
    }

    private var hasWriterErrors: Bool { !result.writerErrors.isEmpty }
    private var isHealthy: Bool { !result.markerStillExists && !hasWriterErrors }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isHealthy ? .green : .orange)
                .font(.system(size: 28))
            VStack(alignment: .leading, spacing: 2) {
                Text(headlineMessage())
                    .font(.title3.bold())
                Text("Wall-clock duration: \(formatSeconds(result.durationSeconds))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var writerErrorsPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Writer errors:")
                .font(.caption.bold())
                .foregroundStyle(.red)
            ForEach(Array(result.writerErrors.enumerated()), id: \.offset) { _, msg in
                Text(msg)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Files")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                fileRow(
                    label: "screen.mov",
                    url: result.screenURL,
                    duration: result.screenDurationSeconds,
                    tracks: [(.screenVideo, "video")]
                )
                if let sysURL = result.sysAudioURL {
                    fileRow(
                        label: "sysaudio.caf",
                        url: sysURL,
                        duration: result.sysAudioDurationSeconds,
                        tracks: [(.screenAudio, "audio")]
                    )
                }
                if let camURL = result.camURL {
                    fileRow(
                        label: "cam.mov",
                        url: camURL,
                        duration: result.camDurationSeconds,
                        tracks: [(.camVideo, "video")]
                    )
                }
                if let micURL = result.micURL {
                    fileRow(
                        label: "mic.caf",
                        url: micURL,
                        duration: result.micDurationSeconds,
                        tracks: [(.micAudio, "audio")]
                    )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 12) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([result.bundleURL])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            Button {
                showsExport = true
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .disabled(player.status != .ready)
            Button {
                onEditProject(result.bundleURL)
            } label: {
                Label("Edit Project", systemImage: "pencil")
            }
            Spacer()
            Button {
                onNewRecording()
            } label: {
                Label("New Recording", systemImage: "plus.circle")
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private struct TrackStatRow: Identifiable {
        let id: String
        let prefix: String
        let stats: TrackStats?
    }

    private func fileRow(label: String, url: URL, duration: Double?, tracks: [(CaptureTrack, String)]) -> some View {
        let rows: [TrackStatRow] = tracks.map { track, prefix in
            TrackStatRow(id: "\(track)", prefix: prefix, stats: result.trackStats[track])
        }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(.body, design: .monospaced))
                .frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(durationLabel(seconds: duration, exists: fileExistsAndNonEmpty(url)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(rows) { row in
                    if let s = row.stats {
                        Text("\(row.prefix): appended \(s.appendedCount) · failed \(s.appendFailedCount) · dropped(notReady) \(s.droppedNotReadyCount) · buffered→appended \(s.bufferedThenAppendedCount)")
                            .font(.caption2)
                            .foregroundStyle(s.appendFailedCount > 0 ? .red : .secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func headlineMessage() -> String {
        if result.markerStillExists && hasWriterErrors {
            return "Stopped with writer errors"
        }
        if hasWriterErrors {
            return "Recording incomplete (writer errors)"
        }
        if result.markerStillExists {
            return "Stopped — but `.recording-in-progress` marker remains"
        }
        return "Recording complete"
    }

    private func formatSeconds(_ s: Double) -> String {
        let total = max(0, s)
        let minutes = Int(total) / 60
        let seconds = total - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, seconds)
    }

    private func durationLabel(seconds: Double?, exists: Bool) -> String {
        let sizeNote = exists ? "" : " — file missing or empty!"
        if let seconds {
            return "\(formatSeconds(seconds))\(sizeNote)"
        }
        return "no duration reported\(sizeNote)"
    }

    private func fileExistsAndNonEmpty(_ url: URL) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        return size > 0
    }
}
