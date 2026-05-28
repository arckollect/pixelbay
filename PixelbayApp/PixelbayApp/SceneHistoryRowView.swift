import AppKit
import Foundation
import PixelbayCore
import SwiftUI

// Slice A.2 — read-only-ish row for previously-merged scenes in the editor's
// project. Reconstructed from clips' `extras["sceneID"]` by
// `ScenesSessionModel.discoverHistoryRows`. The user can edit the
// description (writes through to every clip in the group via
// `SetClipExtraCommand` on the editor's command pipeline) and drag-reorder
// (`MoveClipsByGroupCommand`); deletion and re-recording are NOT exposed
// here per the locked design — those happen in the timeline editor.

struct SceneHistoryRowView: View {

    @Bindable var model: ScenesSessionModel
    let row: ScenesSessionModel.HistoryRow
    let historyIndex: Int

    @State private var draftDescription: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 6) {
                header
                descriptionField
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.background.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .onAppear {
            draftDescription = row.description
        }
        .onChange(of: row.description) { _, newValue in
            if newValue != draftDescription {
                draftDescription = newValue
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Scene \(historyIndex + 1)")
                .font(.headline)
            Text("merged")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
            Spacer()
            Text(durationLabel(row.durationSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var descriptionField: some View {
        TextField("Describe this scene…", text: $draftDescription, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .font(.callout)
            // Commit on Enter or focus-loss. Each commit dispatches one
            // SetClipExtraCommand per clip in the group through the
            // editor's command pipeline — the editor's revision bumps and
            // any open preview rebuilds.
            .onSubmit { commit() }
            .onChange(of: draftDescription) { _, newValue in
                // Live update is too aggressive (one undo entry per
                // keystroke). Defer to the commit path on focus-loss /
                // Enter by ignoring intermediate changes — they're held
                // in `draftDescription` until the user blurs the field.
                _ = newValue
            }
    }

    private func commit() {
        guard draftDescription != row.description else { return }
        let sceneID = row.id
        let value = draftDescription
        Task { await model.updateHistoryDescription(sceneID: sceneID, to: value) }
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.background.tertiary)
            if let path = row.thumbnailRelativePath,
               let nsImage = loadThumbnail(relativePath: path)
            {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "rectangle.stack")
                    .imageScale(.large)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 48, height: 48)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, lineWidth: 0.5)
        )
    }

    private func loadThumbnail(relativePath: String) -> NSImage? {
        guard let appendTarget = model.appendTarget else { return nil }
        let url = appendTarget.bundleURL.appendingPathComponent(relativePath)
        return NSImage(contentsOf: url)
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
