import Foundation
import OSLog
import Observation
import PixelbayCore
import PixelbayDesignSystem
import PixelbayRecording
import SwiftUI

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "OrphanRecovery")

// On launch, surfaces .pixelbay bundles in the recordings directory whose
// state suggests an interrupted recording: missing/malformed project.json
// (caught by ProjectBundleStore.scanForOrphanedBundles) OR a leftover
// `media/.recording-in-progress` marker file. The marker case is the common
// kill-9 outcome: project.json was written upfront, but AssetWriterPipeline
// crashed before clean-up. Per HANDOFF §4.10 + §4.11.

@MainActor
@Observable
final class OrphanRecoveryModel {
    struct OrphanBundle: Identifiable, Hashable {
        var id: URL { url }
        var url: URL
        var modifiedAt: Date?
        var hasMarker: Bool
    }

    var orphans: [OrphanBundle] = []
    var isPresented: Bool = false

    /// Supplies the bundle URLs currently owned by an in-flight recording.
    /// Wired from `ContentView` to `RecordingService.activeBundleURLs` so the
    /// scan never treats the live recording's bundle as an orphan — its
    /// in-progress marker is expected mid-recording, and discarding it would
    /// delete the capture out from under the writer pipeline. Evaluated lazily
    /// at scan/discard time so it always reflects the current recording state.
    var activeBundleURLs: () -> Set<URL> = { [] }

    func scan() {
        let url = OrphanRecoveryModel.recordingsDirectory()
        guard FileManager.default.fileExists(atPath: url.path) else {
            orphans = []
            isPresented = false
            return
        }
        let store = ProjectBundleStore()
        var found: [URL: OrphanBundle] = [:]

        // Pass 1: Core's own scan catches missing/malformed project.json.
        for bundleURL in store.scanForOrphanedBundles(in: url) {
            found[bundleURL] = OrphanBundle(
                url: bundleURL,
                modifiedAt: modifiedAt(of: bundleURL),
                hasMarker: markerExists(in: bundleURL)
            )
        }

        // Pass 2: marker-file based detection. project.json is valid (we
        // wrote it at bundle creation) but the writer pipeline didn't get
        // to clean up — the kill-9 case.
        if let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for bundleURL in contents where bundleURL.pathExtension == "pixelbay" {
                if found[bundleURL] != nil { continue }
                if markerExists(in: bundleURL) {
                    found[bundleURL] = OrphanBundle(
                        url: bundleURL,
                        modifiedAt: modifiedAt(of: bundleURL),
                        hasMarker: true
                    )
                }
            }
        }

        // Never surface the bundle that's actively being recorded. Its
        // in-progress marker (Pass 2) legitimately matches the orphan
        // heuristic while recording is live; discarding it would delete the
        // capture mid-flight (project.json vanishes → stop() throws).
        let activePaths = Set(activeBundleURLs().map { $0.standardizedFileURL.path })
        if !activePaths.isEmpty {
            for url in found.keys where activePaths.contains(url.standardizedFileURL.path) {
                found[url] = nil
            }
        }

        orphans = found.values.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        isPresented = !orphans.isEmpty
        log.info("orphan scan found=\(self.orphans.count)")
    }

    func reveal(_ orphan: OrphanBundle) {
        NSWorkspace.shared.activateFileViewerSelecting([orphan.url])
    }

    func discard(_ orphan: OrphanBundle) {
        // Safety net: refuse to delete a bundle that's actively recording,
        // even if it somehow slipped into the list. Deleting the live bundle
        // destroys the in-flight capture.
        let activePaths = Set(activeBundleURLs().map { $0.standardizedFileURL.path })
        if activePaths.contains(orphan.url.standardizedFileURL.path) {
            log.error("refusing to discard active recording bundle url=\(orphan.url.path, privacy: .public)")
            orphans.removeAll(where: { $0.id == orphan.id })
            if orphans.isEmpty { isPresented = false }
            return
        }
        do {
            try FileManager.default.removeItem(at: orphan.url)
            orphans.removeAll(where: { $0.id == orphan.id })
            if orphans.isEmpty { isPresented = false }
            log.info("orphan discarded url=\(orphan.url.path, privacy: .public)")
        } catch {
            log.error("orphan discard failed: \(String(describing: error), privacy: .public)")
        }
    }

    func dismiss() {
        isPresented = false
    }

    static func recordingsDirectory() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Pixelbay/Recordings", isDirectory: true)
    }

    private func markerExists(in bundleURL: URL) -> Bool {
        let marker = bundleURL
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(AssetWriterPipeline.recordingMarkerFilename)
        return FileManager.default.fileExists(atPath: marker.path)
    }

    private func modifiedAt(of url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }
}

struct OrphanRecoverySheet: View {
    @Bindable var model: OrphanRecoveryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unfinished recordings found")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("These recordings ended unexpectedly. Inspect them in Finder, or discard.")
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            ForEach(model.orphans) { orphan in
                row(orphan: orphan)
            }
            HStack {
                Spacer()
                Button("Skip") { model.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520)
        .background(Theme.Color.bgBase)
        .tint(Theme.Color.accent)
    }

    private func row(orphan: OrphanRecoveryModel.OrphanBundle) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Color.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(orphan.url.lastPathComponent)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let date = orphan.modifiedAt {
                    Text("Modified \(formatted(date))")
                        .font(.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
            Spacer()
            Button("Reveal") { model.reveal(orphan) }
            Button("Discard") { model.discard(orphan) }
        }
        .padding(10)
        .background(Theme.Color.bgElevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
