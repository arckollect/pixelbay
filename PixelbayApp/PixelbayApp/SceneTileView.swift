import AppKit
import Foundation
import PixelbayCore
import PixelbayDesignSystem
import SwiftUI

// One scene as a 3:2 gallery tile in the Scene Recording grid (replaces the
// old wide SceneRowView). Thumbnail-forward: the tile *is* the thumbnail once a
// take exists. Meta and actions stay out of the way until hover, matching the
// Figma skeleton's clean grid.
//
//   - Empty   → centred Record control; the whole tile is the click target.
//   - Recorded → thumbnail fill + bottom scrim with "Scene N" + duration.
//   - Hover    → re-record / per-scene Sources / delete cluster (top-right),
//                an editable description and the take picker (bottom).
//
// All mutations route through ScenesSessionModel exactly as SceneRowView did,
// so the persistence/debounce behaviour is unchanged.

struct SceneTileView: View {
    @Bindable var model: ScenesSessionModel
    let sceneIndex: Int
    let catalog: ScenesSourceCatalog

    @State private var draftDescription: String = ""
    @State private var isHovering: Bool = false
    @State private var confirmDeletePresented: Bool = false
    @State private var confirmReshootPresented: Bool = false
    @State private var previewPresented: Bool = false
    @State private var showSourcesPopover: Bool = false

    private var scene: PixelbayCore.Scene {
        guard model.session.scenes.indices.contains(sceneIndex) else { return PixelbayCore.Scene() }
        return model.session.scenes[sceneIndex]
    }

    private var isRecording: Bool { model.phase != .idle }
    private var hasTake: Bool { scene.activeTake != nil }

    var body: some View {
        ZStack {
            base
            if hasTake {
                thumbnailLayer
                bottomScrim
            } else {
                emptyContent
            }
            overlayChrome
        }
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .stroke(Theme.Color.borderSubtle, lineWidth: Theme.Stroke.hairline)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .onTapGesture {
            // Empty tile: tap anywhere to start the first take. Recorded tiles
            // are re-recorded from the hover button to avoid accidental retakes.
            if !hasTake, !isRecording { Task { await model.recordScene(at: sceneIndex) } }
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onAppear { draftDescription = scene.description }
        .onChange(of: scene.description) { _, newValue in
            if newValue != draftDescription { draftDescription = newValue }
        }
        .alert("Delete this scene?", isPresented: $confirmDeletePresented) {
            Button("Delete", role: .destructive) { model.deleteScene(at: sceneIndex) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if scene.takes.isEmpty {
                Text("This scene has no recordings yet.")
            } else {
                Text("\(scene.takes.count) take\(scene.takes.count == 1 ? "" : "s") will be removed from the session. Underlying media files remain in the bundle until you run Clean up unused takes.")
            }
        }
        .alert("Reshoot Scene \(sceneIndex + 1)?", isPresented: $confirmReshootPresented) {
            Button("Reshoot") { Task { await model.recordScene(at: sceneIndex) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This starts a new recording and adds another take. Your current take stays available in the take picker.")
        }
        .sheet(isPresented: $previewPresented) {
            if let url = activeTakeScreenURL {
                TakePreviewSheet(url: url, title: "Scene \(sceneIndex + 1)", takeLabel: takeLabel)
            } else {
                missingPreview
            }
        }
    }

    /// `media/screen-{sessionID}.mov` for the active take, when the file is on
    /// disk. nil for a take whose screen recording is missing (shouldn't happen
    /// for a normal capture, but guard so the sheet degrades gracefully).
    private var activeTakeScreenURL: URL? {
        guard let take = scene.activeTake else { return nil }
        let url = model.bundle.url.appendingPathComponent("media/screen-\(take.sessionID).mov")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var takeLabel: String {
        let index = (scene.activeTakeIndex ?? 0) + 1
        return "Take \(index) of \(scene.takes.count)"
    }

    private var missingPreview: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "film.stack")
                .font(.system(size: 28))
                .foregroundStyle(Theme.Color.textTertiary)
            Text("Preview unavailable")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Color.textPrimary)
            Text("This take's screen recording couldn't be found in the bundle.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
            Button("Done") { previewPresented = false }
                .buttonStyle(.pbSecondary)
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 360)
        .background(Theme.Color.bgDeep)
    }

    // MARK: - Base / inset look

    private var base: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .fill(Theme.Color.bgElevated)
            // Inner top shadow (Figma: inset 0 4 4 rgba(0,0,0,0.45)) faked with
            // a blurred dark stroke clipped to the tile.
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .stroke(Color.black.opacity(0.45), lineWidth: 8)
                    .blur(radius: 4)
                    .offset(y: 4)
                    .mask(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            )
    }

    // MARK: - Recorded state

    @ViewBuilder
    private var thumbnailLayer: some View {
        if let path = scene.activeTake?.thumbnailRelativePath,
           let nsImage = loadThumbnail(relativePath: path) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
        } else {
            // Take exists but the thumbnail file isn't on disk yet (mid-record
            // race). Keep the elevated surface and show a neutral glyph.
            ZStack {
                Theme.Color.bgBase
                Image(systemName: "video.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.Color.textTertiary)
            }
        }
    }

    private var bottomScrim: some View {
        VStack {
            Spacer()
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 96)
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text("Scene \(sceneIndex + 1)")
                        .font(Theme.Font.cardTitle)
                        .foregroundStyle(Theme.Color.textPrimary)
                    if let take = scene.activeTake {
                        Text(durationLabel(take.durationSeconds))
                            .font(Theme.Font.monoTimecode)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.md)
                // When hovering, the description + take picker take this space.
                .opacity(isHovering ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Empty state

    private var emptyContent: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(isRecording ? Theme.Color.textTertiary : Theme.Color.recordingRed)
                .symbolRenderingMode(.hierarchical)
            Text("Scene \(sceneIndex + 1)")
                .font(Theme.Font.cardTitle)
                .foregroundStyle(Theme.Color.textSecondary)
            Text(isRecording ? "Recording…" : "Click to record")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chrome: badge, hover actions, hover meta

    // Keep the chrome (and the Sources-popover anchor) mounted while the
    // popover is open: moving the mouse off the tile toward the popover flips
    // `isHovering` false, and unmounting the anchoring button would dismiss the
    // popover before the user reaches it.
    private var chromeVisible: Bool { isHovering || showSourcesPopover }

    private var overlayChrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if scene.sourceOverride.hasAnyOverride {
                    customBadge
                }
                Spacer()
                actionCluster
                    .opacity(chromeVisible ? 1 : 0)
                    .allowsHitTesting(chromeVisible)
            }
            Spacer()
            // Description + take picker only matter once a take exists; hiding
            // them on empty tiles also keeps the whole-tile tap-to-record clean.
            if hasTake {
                hoverMeta
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
            }
        }
        .padding(Theme.Spacing.sm)
    }

    private var customBadge: some View {
        Text("Custom")
            .font(Theme.Font.caption)
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, 2)
            .background(Theme.Color.accent.opacity(0.18), in: Capsule())
            .foregroundStyle(Theme.Color.accent)
            .accessibilityLabel("Uses custom source overrides")
    }

    private var actionCluster: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if hasTake {
                circleButton(systemName: "play.fill", tint: Theme.Color.textPrimary, help: "Preview this take") {
                    previewPresented = true
                }
            }

            circleButton(
                systemName: hasTake ? "arrow.clockwise" : "record.circle",
                tint: hasTake ? Theme.Color.accent : Theme.Color.recordingRed,
                help: hasTake ? "Reshoot — record a new take" : "Record"
            ) {
                // Reshooting an existing scene starts a recording (hides the
                // window), so confirm first — same guard as Delete. The first
                // take needs no confirmation.
                if hasTake {
                    confirmReshootPresented = true
                } else {
                    Task { await model.recordScene(at: sceneIndex) }
                }
            }
            .disabled(isRecording)

            circleButton(systemName: "slider.horizontal.3", tint: Theme.Color.textPrimary, help: "Sources") {
                showSourcesPopover = true
            }
            .popover(isPresented: $showSourcesPopover, arrowEdge: .bottom) {
                sourcesPopover
            }

            circleButton(systemName: "trash", tint: Theme.Color.danger, help: "Delete this scene") {
                confirmDeletePresented = true
            }
        }
    }

    private var hoverMeta: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Scene \(sceneIndex + 1)")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                if let take = scene.activeTake {
                    Text(durationLabel(take.durationSeconds))
                        .font(Theme.Font.monoTimecode)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                Spacer()
            }
            TextField("Describe this scene…", text: $draftDescription, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...2)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textPrimary)
                .onSubmit { model.updateDescription(sceneID: scene.id, to: draftDescription) }
                .onChange(of: draftDescription) { _, newValue in
                    model.updateDescription(sceneID: scene.id, to: newValue)
                }
            if scene.takes.count > 1 {
                takePicker
            }
        }
        .padding(Theme.Spacing.sm)
        .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }

    private var takePicker: some View {
        Picker("Active take", selection: takeBinding) {
            ForEach(scene.takes.indices, id: \.self) { idx in
                Text("\(idx + 1)").tag(idx)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(maxWidth: 180, alignment: .leading)
    }

    private var takeBinding: Binding<Int> {
        Binding(
            get: { scene.activeTakeIndex ?? 0 },
            set: { model.setActiveTake(sceneID: scene.id, takeIndex: $0) }
        )
    }

    private var sourcesPopover: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Sources for Scene \(sceneIndex + 1)")
                .font(Theme.Font.cardTitle)
                .foregroundStyle(Theme.Color.textSecondary)
            SceneOverridePickers(
                catalog: catalog,
                defaults: model.session.defaults,
                override: overrideBinding
            )
        }
        .tint(Theme.Color.accent)
        .padding(Theme.Spacing.lg)
        .frame(width: 280)
    }

    private var overrideBinding: Binding<SceneSourceOverride> {
        Binding(
            get: { scene.sourceOverride },
            set: { model.updateSourceOverride(sceneID: scene.id, $0) }
        )
    }

    // MARK: - Building blocks

    private func circleButton(
        systemName: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Theme.Color.borderSubtle, lineWidth: Theme.Stroke.hairline))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Helpers

    /// Loads `bundle/<relativePath>` via NSImage. Returns nil when the file is
    /// missing (recording-in-progress race). NSImage caches recently-loaded
    /// URLs so per-render calls are cheap.
    private func loadThumbnail(relativePath: String) -> NSImage? {
        let url = model.bundle.url.appendingPathComponent(relativePath)
        return NSImage(contentsOf: url)
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Ghost "add scene" tile

/// Trailing grid cell: a dashed-outline placeholder that adds another scene.
/// Shares the 3:2 footprint of a real tile so the grid stays even.
struct AddSceneTile: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .fill(Theme.Color.bgElevated.opacity(hovering ? 0.5 : 0.25))
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(
                        hovering ? Theme.Color.textSecondary : Theme.Color.borderStrong,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
                VStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "plus")
                        .font(.system(size: 30, weight: .regular))
                    Text("Add Scene")
                        .font(Theme.Font.cardTitle)
                }
                .foregroundStyle(hovering ? Theme.Color.textSecondary : Theme.Color.textTertiary)
            }
            .aspectRatio(3.0 / 2.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .help("Add another scene")
    }
}
