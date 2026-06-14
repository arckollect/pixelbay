import AppKit
import Foundation
import PixelbayCore
import PixelbayDesignSystem
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
    @FocusState private var isEditingDescription: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            thumbnail
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                header
                descriptionField
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(Theme.Color.accent)
        .pbCard()
        .opacity(0.85)
        .onAppear {
            draftDescription = row.description
        }
        .onChange(of: row.description) { _, newValue in
            if !isEditingDescription, newValue != draftDescription {
                draftDescription = newValue
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Text("Scene \(historyIndex + 1)")
                .font(Theme.Font.cardTitle)
                .foregroundStyle(Theme.Color.textPrimary)
            Text("merged")
                .font(Theme.Font.caption)
                .padding(.horizontal, Theme.Spacing.xs)
                .padding(.vertical, 2)
                .background(Theme.Color.bgElevated, in: Capsule())
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text(durationLabel(row.durationSeconds))
                .font(Theme.Font.monoTimecode)
                .foregroundStyle(Theme.Color.textSecondary)
        }
    }

    private var descriptionField: some View {
        TextField("Describe this scene…", text: $draftDescription, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Color.textPrimary)
            .focused($isEditingDescription)
            // Commit on Enter or focus-loss. Each commit dispatches one
            // SetClipExtraCommand per clip in the group through the
            // editor's command pipeline — the editor's revision bumps and
            // any open preview rebuilds.
            .onSubmit { commit() }
            .onChange(of: isEditingDescription) { _, focused in
                if !focused { commit() }
            }
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
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .fill(Theme.Color.bgBase)
            if let path = row.thumbnailRelativePath,
               let nsImage = loadThumbnail(relativePath: path)
            {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            } else {
                Image(systemName: "rectangle.stack")
                    .imageScale(.large)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
        }
        .frame(width: 48, height: 48)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .stroke(Theme.Color.borderSubtle, lineWidth: Theme.Stroke.hairline)
        )
    }

    private func loadThumbnail(relativePath: String) -> NSImage? {
        guard let appendTarget = model.appendTarget else { return nil }
        guard let url = try? ProjectBundle(url: appendTarget.bundleURL).url(forRelativePath: relativePath) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
