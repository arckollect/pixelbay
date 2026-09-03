import AppKit
import Foundation
import PixelbayCore
import PixelbayDesignSystem
import SwiftUI

// One scene in the Scene Recording grid: a 16:9 thumbnail card with a quiet
// footer beneath it.
//
//   Card
//   - Empty    → the whole card is the Record button: red glyph + label,
//                surface lifts on hover, scales down on press.
//   - Recorded → first-frame thumbnail with a duration pill (bottom-right)
//                and badges (top-left: Custom sources / N takes). Hover dims
//                the frame and reveals a centred Play control plus a Reshoot
//                pill (top-right).
//   Footer
//   - "Scene N" (+ take picker when there are several takes); trailing
//     Sources + ⋯ actions sit at tertiary contrast and brighten on hover.
//     Everything is also on the card's context menu, so nothing depends on
//     discovering the hover state.
//
// Drag the card onto another to reorder — the drag preview is the card
// itself and the drop target gets an accent ring. All mutations route through
// ScenesSessionModel, so persistence/debounce behaviour is unchanged.

struct SceneTileView: View {
    @Bindable var model: ScenesSessionModel
    let sceneIndex: Int
    let catalog: ScenesSourceCatalog

    @State private var isHovering = false
    @State private var isDropTarget = false
    @State private var confirmDeletePresented = false
    @State private var confirmReshootPresented = false
    @State private var previewPresented = false
    @State private var showSourcesPopover = false

    private var scene: PixelbayCore.Scene {
        guard model.session.scenes.indices.contains(sceneIndex) else { return PixelbayCore.Scene() }
        return model.session.scenes[sceneIndex]
    }

    private var isRecording: Bool { model.phase != .idle }
    private var hasTake: Bool { scene.activeTake != nil }
    private var hasCustomSources: Bool { scene.sourceOverride.hasAnyOverride }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            card
            footer
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .animation(.easeOut(duration: 0.14), value: isDropTarget)
        .contextMenu { menuItems }
        .dropDestination(for: String.self) { items, _ in
            guard let first = items.first, let from = Int(first), from != sceneIndex else { return false }
            model.moveScene(from: from, to: from < sceneIndex ? sceneIndex + 1 : sceneIndex)
            return true
        } isTargeted: { isDropTarget = $0 }
        .alert("Delete Scene \(sceneIndex + 1)?", isPresented: $confirmDeletePresented) {
            Button("Delete", role: .destructive) { model.deleteScene(at: sceneIndex) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if scene.takes.isEmpty {
                Text("This scene has no recordings yet.")
            } else {
                Text("\(scene.takes.count) take\(scene.takes.count == 1 ? "" : "s") will be removed from the session. The media stays in the bundle until you clean up unused takes.")
            }
        }
        .alert("Reshoot Scene \(sceneIndex + 1)?", isPresented: $confirmReshootPresented) {
            Button("Reshoot") { Task { await model.recordScene(at: sceneIndex) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Starts a new recording as another take. The current take stays available in the take picker.")
        }
        .sheet(isPresented: $previewPresented) {
            TakePreviewSheet(
                model: model,
                sceneIndex: sceneIndex,
                title: "Scene \(sceneIndex + 1)",
                takeLabel: takeLabel,
                fallbackScreenURL: activeTakeScreenURL
            )
        }
    }

    // MARK: - Card

    @ViewBuilder
    private var card: some View {
        if hasTake {
            cardFrame { recordedContent }
        } else {
            // The empty card is one big Record button so the press feedback
            // scales the whole card (border included), not just its label.
            Button(action: startFirstTake) {
                cardFrame { emptyContent }
            }
            .buttonStyle(PressableCardStyle())
            .disabled(isRecording)
        }
    }

    /// The 16:9 footprint, surface, border, and drag source shared by both
    /// states. A `Color.clear` spacer owns the aspect ratio and the content
    /// rides in an overlay so a `scaledToFill` thumbnail can never inflate the
    /// cell (which is what used to leave uneven gaps in the grid).
    private func cardFrame<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                ZStack {
                    shape.fill(Theme.Color.bgElevated)
                    content()
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(borderColor, lineWidth: borderWidth))
            .contentShape(shape)
            .scaleEffect(isDropTarget ? 1.015 : 1)
            .draggable(String(sceneIndex)) { dragPreview }
    }

    private var borderColor: Color {
        if isDropTarget { return Theme.Color.accent }
        if hasCustomSources { return Theme.Color.accent.opacity(0.7) }
        return isHovering ? Theme.Color.borderStrong : Theme.Color.borderSubtle
    }

    private var borderWidth: CGFloat {
        (isDropTarget || hasCustomSources) ? Theme.Stroke.regular : Theme.Stroke.hairline
    }

    /// What follows the pointer during a reorder drag: the card itself at a
    /// reduced size, so the drag reads as moving the scene rather than a
    /// placeholder.
    private var dragPreview: some View {
        ZStack {
            shape.fill(Theme.Color.bgElevated)
            if hasTake {
                thumbnailImage
            } else {
                Text("Scene \(sceneIndex + 1)")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .frame(width: 200, height: 112)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.Color.borderStrong, lineWidth: Theme.Stroke.regular))
    }

    // MARK: - Empty state

    private var emptyContent: some View {
        ZStack {
            // Hover lift: a faint wash rather than a colour swap, so the
            // surface stays in the same depth plane as its neighbours.
            shape.fill(Color.white.opacity(isHovering && !isRecording ? 0.04 : 0))
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isRecording ? Theme.Color.textTertiary : Theme.Color.recordingRed)
                Text(isRecording ? "Recording…" : "Record")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(
                        isHovering && !isRecording ? Theme.Color.textPrimary : Theme.Color.textSecondary
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startFirstTake() {
        guard !isRecording else { return }
        Task { await model.recordScene(at: sceneIndex) }
    }

    // MARK: - Recorded state

    private var recordedContent: some View {
        ZStack {
            thumbnailImage

            // Hover: dim the frame and surface Play. The dim is what makes the
            // white control legible over any footage.
            Color.black.opacity(isHovering ? 0.28 : 0)
                .allowsHitTesting(false)

            playButton
                .opacity(isHovering ? 1 : 0)
                .scaleEffect(isHovering ? 1 : 0.96)
                .allowsHitTesting(isHovering)

            VStack {
                HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                    badges
                    Spacer()
                    reshootPill
                        .opacity(isHovering ? 1 : 0)
                        .allowsHitTesting(isHovering)
                }
                Spacer()
                HStack {
                    Spacer()
                    if let take = scene.activeTake {
                        durationPill(take.durationSeconds)
                    }
                }
            }
            .padding(Theme.Spacing.sm)
        }
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let path = scene.activeTake?.thumbnailRelativePath,
           let nsImage = loadThumbnail(relativePath: path) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
        } else {
            // Take exists but the thumbnail isn't on disk yet (mid-record
            // race). Keep the surface and show a neutral glyph.
            ZStack {
                Theme.Color.bgBase
                Image(systemName: "video.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.Color.textTertiary)
            }
        }
    }

    private var playButton: some View {
        Button {
            previewPresented = true
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: 1)   // optically centre the triangle
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: Theme.Stroke.regular))
        }
        .buttonStyle(PressableCardStyle(scale: 0.94))
        .help("Preview this take")
    }

    private var reshootPill: some View {
        Button {
            confirmReshootPresented = true
        } label: {
            Label("Reshoot", systemImage: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: Theme.Stroke.hairline))
        }
        .buttonStyle(PressableCardStyle(scale: 0.96))
        .disabled(isRecording)
        .help("Record another take of this scene")
    }

    @ViewBuilder
    private var badges: some View {
        if hasCustomSources {
            badge("Custom", tint: Theme.Color.accent)
                .accessibilityLabel("Uses custom source overrides")
        }
        if scene.takes.count > 1 {
            badge("\(scene.takes.count) takes", tint: Theme.Color.textSecondary)
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.55), in: Capsule())
    }

    private func durationPill(_ seconds: Double) -> some View {
        Text(durationLabel(seconds))
            .font(Theme.Font.monoTimecode)
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.55), in: Capsule())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Text("Scene \(sceneIndex + 1)")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                if scene.takes.count > 1 {
                    takeMenu
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Per-scene actions: quiet until the pointer is over the cell.
            HStack(spacing: 2) {
                footerIconButton("slider.horizontal.3", help: "Sources for this scene") {
                    showSourcesPopover = true
                }
                .popover(isPresented: $showSourcesPopover, arrowEdge: .bottom) {
                    sourcesPopover
                }

                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
            }
            .foregroundStyle(isHovering ? Theme.Color.textPrimary : Theme.Color.textTertiary)
        }
        .padding(.horizontal, Theme.Spacing.xs)
    }

    /// "Take 2 of 3 ▾" — a menu rather than a segmented control so it stays
    /// one quiet line in the footer however many takes pile up.
    private var takeMenu: some View {
        Menu {
            Picker("Active take", selection: takeBinding) {
                ForEach(scene.takes.indices, id: \.self) { idx in
                    Text("Take \(idx + 1)").tag(idx)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text(takeLabel)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Color.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose which take merges into the project")
    }

    private func footerIconButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableCardStyle(scale: 0.92))
        .help(help)
    }

    @ViewBuilder
    private var menuItems: some View {
        if hasTake {
            Button {
                previewPresented = true
            } label: {
                Label("Preview Take", systemImage: "play")
            }
            Button {
                confirmReshootPresented = true
            } label: {
                Label("Reshoot…", systemImage: "arrow.clockwise")
            }
            .disabled(isRecording)
        } else {
            Button(action: startFirstTake) {
                Label("Record", systemImage: "record.circle")
            }
            .disabled(isRecording)
        }
        Button {
            showSourcesPopover = true
        } label: {
            Label("Sources…", systemImage: "slider.horizontal.3")
        }
        Divider()
        Button(role: .destructive) {
            confirmDeletePresented = true
        } label: {
            Label("Delete Scene", systemImage: "trash")
        }
    }

    // MARK: - Sources popover

    private var sourcesPopover: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scene \(sceneIndex + 1) Sources")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Overrides the default sources for this scene only.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            SceneOverridePickers(
                catalog: catalog,
                defaults: model.session.defaults,
                override: overrideBinding
            )
        }
        .tint(Theme.Color.accent)
        .padding(Theme.Spacing.lg)
        .frame(width: 300)
    }

    private var overrideBinding: Binding<SceneSourceOverride> {
        Binding(
            get: { scene.sourceOverride },
            set: { model.updateSourceOverride(sceneID: scene.id, $0) }
        )
    }

    private var takeBinding: Binding<Int> {
        Binding(
            get: { scene.activeTakeIndex ?? 0 },
            set: { model.setActiveTake(sceneID: scene.id, takeIndex: $0) }
        )
    }

    // MARK: - Helpers

    /// `media/screen-{sessionID}.mov` for the active take, when the file is on
    /// disk. nil for a take whose screen recording is missing (shouldn't happen
    /// for a normal capture, but guard so the sheet degrades gracefully).
    private var activeTakeScreenURL: URL? {
        guard let take = scene.activeTake else { return nil }
        guard let url = try? model.bundle.url(forRelativePath: "media/screen-\(take.sessionID).mov") else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var takeLabel: String {
        let index = (scene.activeTakeIndex ?? 0) + 1
        return "Take \(index) of \(scene.takes.count)"
    }

    /// Loads `bundle/<relativePath>` via NSImage. Returns nil when the file is
    /// missing (recording-in-progress race). NSImage caches recently-loaded
    /// URLs so per-render calls are cheap.
    private func loadThumbnail(relativePath: String) -> NSImage? {
        guard let url = try? model.bundle.url(forRelativePath: relativePath) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Press feedback

/// Scales the whole label down slightly while pressed — the "I heard you"
/// acknowledgement every pressable surface in the grid shares. Kept subtle
/// (0.92–0.985) so it reads as feedback, not motion.
struct PressableCardStyle: ButtonStyle {
    var scale: CGFloat = 0.985

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Ghost "add scene" tile

/// Trailing grid cell: a dashed-outline placeholder that adds another scene.
/// Shares the 16:9 footprint of a real card so the grid stays even.
struct AddSceneTile: View {
    let action: () -> Void
    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                shape.fill(Theme.Color.bgElevated.opacity(hovering ? 0.5 : 0.25))
                shape.strokeBorder(
                    hovering ? Theme.Color.textSecondary : Theme.Color.borderStrong,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
                VStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "plus")
                        .font(.system(size: 28, weight: .regular))
                    Text("Add Scene")
                        .font(Theme.Font.cardTitle)
                }
                .foregroundStyle(hovering ? Theme.Color.textPrimary : Theme.Color.textTertiary)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .contentShape(shape)
        }
        .buttonStyle(PressableCardStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .help("Add another scene")
    }
}
