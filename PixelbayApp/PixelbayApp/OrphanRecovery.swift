import Foundation
import OSLog
import Observation
import PixelbayCore
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

        orphans = found.values.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        isPresented = !orphans.isEmpty
        log.info("orphan scan found=\(self.orphans.count)")
    }

    func reveal(_ orphan: OrphanBundle) {
        NSWorkspace.shared.activateFileViewerSelecting([orphan.url])
    }

    func discard(_ orphan: OrphanBundle) {
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
                Text("These recordings ended unexpectedly. Inspect them in Finder, or discard.")
                    .foregroundStyle(.secondary)
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
    }

    private func row(orphan: OrphanRecoveryModel.OrphanBundle) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(orphan.url.lastPathComponent)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let date = orphan.modifiedAt {
                    Text("Modified \(formatted(date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Reveal") { model.reveal(orphan) }
            Button("Discard") { model.discard(orphan) }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
