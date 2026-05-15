import AppKit
import AVFoundation
import Foundation
import PixelbayCore
import PixelbayPlayback
import SwiftUI
import UniformTypeIdentifiers

// §4.10 export sheet: single preset (1080p H.264 MP4), NSSavePanel for
// destination, progress + cancel. Per HANDOFF §6.6 the export uses the same
// AVMutableComposition + PixelbayVideoCompositor that drives the preview.

struct ExportSheet: View {
    let result: RecordingService.Result
    var onDone: () -> Void

    @State private var exporter = Exporter()
    @State private var pendingDestination: URL?
    @State private var pickedDestination: Bool = false
    /// Surfaces errors that happen BEFORE we hand off to AVAssetExportSession
    /// (e.g. project.json read miss, asset file gone). When non-nil this
    /// short-circuits the exporter status display so the user sees what
    /// actually went wrong instead of a stuck "Preparing…".
    @State private var preExportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Recording")
                    .font(.title2.bold())
                Text("High — 1080p H.264 MP4. Single preset for v0.1; the preset matrix lands in Phase 4.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statusPanel

            HStack {
                Spacer()
                trailingButtons
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 200)
        .task {
            if !pickedDestination {
                pickedDestination = true
                await pickDestinationAndExport()
            }
        }
    }

    @ViewBuilder
    private var statusPanel: some View {
        if let preExportError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(preExportError).font(.callout)
            }
        } else {
            exporterStatusPanel
        }
    }

    @ViewBuilder
    private var exporterStatusPanel: some View {
        switch exporter.status {
        case .idle:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Choose where to save…").foregroundStyle(.secondary)
            }
        case .preparing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Preparing…").foregroundStyle(.secondary)
            }
        case .exporting(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        case .finished(let url):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exported")
                    Text(url.lastPathComponent)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(message)
                    .font(.callout)
            }
        case .cancelled:
            HStack(spacing: 10) {
                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                Text("Export cancelled").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var trailingButtons: some View {
        if let _ = preExportError {
            Button("Try Again") {
                Task {
                    preExportError = nil
                    await pickDestinationAndExport()
                }
            }
            Button("Close") { onDone() }
        } else {
            exporterTrailingButtons
        }
    }

    @ViewBuilder
    private var exporterTrailingButtons: some View {
        switch exporter.status {
        case .idle, .preparing:
            Button("Cancel") { onDone() }
        case .exporting:
            Button("Cancel") { exporter.cancel() }
        case .finished(let url):
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("Done") {
                exporter.acknowledge()
                onDone()
            }
            .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Try Again") {
                Task {
                    exporter.acknowledge()
                    await pickDestinationAndExport()
                }
            }
            Button("Close") {
                exporter.acknowledge()
                onDone()
            }
        case .cancelled:
            Button("Close") {
                exporter.acknowledge()
                onDone()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func pickDestinationAndExport() async {
        let panel = NSSavePanel()
        panel.title = "Export Recording"
        panel.allowedContentTypes = [UTType.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFilename()
        let response = await panel.beginSheetModalAsync(for: keyWindow())
        guard response == .OK, let outputURL = panel.url else {
            onDone()
            return
        }
        pendingDestination = outputURL
        await runExport(to: outputURL)
    }

    private func runExport(to url: URL) async {
        preExportError = nil
        let bundle = ProjectBundle(url: result.bundleURL)
        do {
            let project = try ProjectBundleStore().loadProject(from: bundle)
            let cursorTrajectory = await CursorTrajectoryLoader.load(
                for: project,
                bundleURL: bundle.url
            )
            let preview = try await PreviewCompositionBuilder.build(
                project: project,
                bundleURL: bundle.url,
                wallpaperSource: .live,
                cursorTrajectory: cursorTrajectory,
                cursorSprite: SystemCursorSprite.make()
            )
            await exporter.export(
                composition: preview.composition,
                videoComposition: preview.videoComposition,
                audioMix: preview.audioMix,
                to: url
            )
        } catch {
            // Composition build failed before we ever handed off to
            // AVAssetExportSession — surface via local state so the UI
            // shows the actual cause instead of stuck "Preparing…". The
            // exporter itself is still .idle, no acknowledge() needed.
            preExportError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func defaultFilename() -> String {
        let stem = result.bundleURL.deletingPathExtension().lastPathComponent
        return "\(stem).mp4"
    }

    private func keyWindow() -> NSWindow {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.canBecomeKey } ?? NSWindow()
    }
}

// NSSavePanel.beginSheetModal is callback-based; bridge it to async/await.
private extension NSSavePanel {
    func beginSheetModalAsync(for window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            self.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
