import AppKit
import PixelbayCore
import PixelbayDesignSystem
import SwiftUI
import UniformTypeIdentifiers

// Phase 3a Inspector sections for scene composition, split across two right-
// rail tabs:
//   • CameraInspector     — webcam composition: PiP / side-by-side mode,
//     position, size, shape ("Camera" tab).
//   • BackgroundInspector — the backdrop gallery + frame padding
//     ("Background & Scene" tab).
// Both funnel edits through a single `onChange` closure that dispatches a
// `SetLayoutPresetCommand` — coalescing logic (debouncing slider drags,
// dropping no-op edits) lives in the caller's Task so the views stay dumb
// forms. Background-color edits commit on focus loss / Enter via SwiftUI's
// ColorPicker which already coalesces continuous picker drags.

/// Webcam composition controls: PiP vs side-by-side mode, and — depending on
/// the mode — the PiP position grid + cam size, or the split screen-side +
/// share slider. Cam shape (rectangle / circle) applies to both modes.
struct CameraInspector: View {
    let layout: LayoutPreset
    let onChange: (LayoutPreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            PBSectionHeader("Camera")

            modeRow
            if case .pip = layout.mode {
                positionGrid
                camSizeRow
            } else if case .splitHorizontal(_, let fraction) = layout.mode {
                splitControls(fraction: fraction)
            }
            // Custom mode shows no extra rows here — the explanation + Reset
            // Layout affordance live at the top of the Layout tab (ProjectView).

            camShapeRow
        }
    }

    /// True when the layout is a free-form custom arrangement (produced by
    /// dragging/scaling a layer in the preview). The preset controls below
    /// stand in as one-click "starting points" that convert back out of custom.
    private var isCustom: Bool {
        if case .custom = layout.mode { return true }
        return false
    }

    // MARK: - Mode

    private var modeRow: some View {
        HStack {
            Text("Mode")
            Spacer()
            // The "Custom" segment only appears once a custom arrangement
            // exists — you enter custom by dragging in the preview, not by
            // tapping here (tapping it is a no-op). PiP / Side-by-Side always
            // convert out of custom.
            PBSegmentedControl(selection: modeBinding, modeSegments)
                .frame(maxWidth: isCustom ? 280 : 200)
        }
    }

    private var modeSegments: [(LayoutModeTag, String)] {
        var segments: [(LayoutModeTag, String)] = [
            (.pip, "Picture-in-Picture"),
            (.split, "Side-by-Side"),
        ]
        if isCustom { segments.append((.custom, "Custom")) }
        return segments
    }

    private var modeBinding: Binding<LayoutModeTag> {
        Binding(
            get: {
                switch layout.mode {
                case .pip: return .pip
                case .splitHorizontal: return .split
                case .custom: return .custom
                }
            },
            set: { newTag in
                switch newTag {
                case .pip:
                    var next = layout
                    next.mode = .pip(position: .bottomRight, size: .medium)
                    onChange(next)
                case .split:
                    var next = layout
                    next.mode = .splitHorizontal(screenSide: .left, screenFraction: 0.7)
                    onChange(next)
                case .custom:
                    break  // display-only; entered by dragging in the preview
                }
            }
        )
    }

    // MARK: - PiP grid + size

    /// Cam-position picker rendered as a mini "canvas": a 16:9 frame that
    /// stands in for the output, with a 3×3 grid of tap zones. The selected
    /// zone shows a little accent cam chip seated where the PiP would land;
    /// the rest show faint dots. Reads far more clearly than the old grid of
    /// nine identical rectangles.
    private var positionGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cam Position").font(Theme.Font.caption).foregroundStyle(Theme.Color.textSecondary)
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.Color.bgBase, Theme.Color.bgDeep],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                            .strokeBorder(Theme.Color.borderSubtle, lineWidth: Theme.Stroke.hairline)
                    )
                VStack(spacing: 0) {
                    ForEach(positionRows, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(row, id: \.self) { pos in
                                positionCell(pos)
                            }
                        }
                    }
                }
                .padding(7)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.18), value: selectedPosition)
        }
    }

    private var positionRows: [[CamPosition]] {
        [
            [.topLeft, .topCenter, .topRight],
            [.middleLeft, .center, .middleRight],
            [.bottomLeft, .bottomCenter, .bottomRight]
        ]
    }

    private var selectedPosition: CamPosition? {
        if case .pip(let current, _) = layout.mode { return current }
        return nil
    }

    private func positionCell(_ pos: CamPosition) -> some View {
        let isSelected = selectedPosition == pos
        return ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.Color.accent)
                    .overlay(
                        Image(systemName: "video.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: Theme.Color.accent.opacity(0.5), radius: 4, y: 1)
                    .padding(4)
            } else {
                Circle()
                    .fill(Theme.Color.textTertiary.opacity(0.55))
                    .frame(width: 4, height: 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            guard case .pip(_, let size) = layout.mode else { return }
            var next = layout
            next.mode = .pip(position: pos, size: size)
            onChange(next)
        }
        .help(pos.label)
    }

    private var camSizeRow: some View {
        HStack {
            Text("Cam Size").font(.caption)
            Spacer()
            PBSegmentedControl(selection: sizeBinding, [
                (CamSizePreset.small, "S"),
                (CamSizePreset.medium, "M"),
                (CamSizePreset.large, "L"),
            ])
            .frame(maxWidth: 110)
        }
    }

    private var sizeBinding: Binding<CamSizePreset> {
        Binding(
            get: {
                if case .pip(_, let s) = layout.mode { return s }
                return .medium
            },
            set: { newSize in
                guard case .pip(let pos, _) = layout.mode else { return }
                var next = layout
                next.mode = .pip(position: pos, size: newSize)
                onChange(next)
            }
        )
    }

    // MARK: - Split

    @ViewBuilder
    private func splitControls(fraction: Double) -> some View {
        HStack {
            Text("Screen Side").font(.caption)
            Spacer()
            PBSegmentedControl(selection: splitSideBinding, [
                (HorizontalSide.left, "Left"),
                (HorizontalSide.right, "Right"),
            ])
            .frame(maxWidth: 130)
        }
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Screen Share").font(.caption)
                Spacer()
                Text(String(format: "%.0f%%", fraction * 100))
                    .font(Theme.Font.monoTimecode)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            PBSlider(
                value: Binding<Double>(
                    get: { fraction },
                    set: { newValue in
                        guard case .splitHorizontal(let side, _) = layout.mode else { return }
                        var next = layout
                        next.mode = .splitHorizontal(screenSide: side, screenFraction: newValue)
                        onChange(next)
                    }
                ),
                in: 0.3...0.9
            )
        }
    }

    private var splitSideBinding: Binding<HorizontalSide> {
        Binding(
            get: {
                if case .splitHorizontal(let side, _) = layout.mode { return side }
                return .left
            },
            set: { newSide in
                guard case .splitHorizontal(_, let fraction) = layout.mode else { return }
                var next = layout
                next.mode = .splitHorizontal(screenSide: newSide, screenFraction: fraction)
                onChange(next)
            }
        )
    }

    // MARK: - Shape

    private var camShapeRow: some View {
        HStack {
            Text("Cam Shape").font(.caption)
            Spacer()
            PBSegmentedControl(selection: camShapeBinding, [
                (CamShape.rectangle, "Rectangle"),
                (CamShape.circle, "Circle"),
            ])
            .frame(maxWidth: 180)
        }
    }

    private var camShapeBinding: Binding<CamShape> {
        Binding(
            get: { layout.camShape },
            set: { newShape in
                var next = layout
                next.camShape = newShape
                onChange(next)
            }
        )
    }
}

/// The backdrop gallery (image wallpapers, gradient meshes, solid color /
/// desktop) plus the frame padding — the "Background & Scene" tab.
struct BackgroundInspector: View {
    let layout: LayoutPreset
    /// Project bundle root — image-wallpaper uploads are copied in here so the
    /// project stays self-contained.
    let bundleURL: URL
    let onChange: (LayoutPreset) -> Void
    let onError: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            backgroundSection

            // Padding is meaningless in a custom arrangement (the screen rect is
            // authored directly by dragging), so it's hidden there. Corner
            // radius still rounds the floating screen, so it stays available
            // whenever a background is set or a radius is already dialed in.
            if !isCustom, layout.padding > 0 || hasBackground {
                paddingRow
                cornerRadiusRow
            } else if isCustom, hasBackground || layout.screenCornerRadius > 0 {
                cornerRadiusRow
            }
        }
    }

    // MARK: - Background

    private var isCustom: Bool {
        if case .custom = layout.mode { return true }
        return false
    }

    private var hasBackground: Bool {
        if case .none = layout.background { return false }
        return true
    }

    private var backgroundGridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    }

    /// Background picker. Three swatch groups — image wallpapers (built-ins +
    /// Upload), gradient "wallpaper" meshes, and utility tiles (None / Desktop
    /// / Custom) — above a contextual editor (shown only for a solid color).
    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Background")
                .font(Theme.Font.cardTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            backgroundGroupLabel("Wallpapers")
            LazyVGrid(columns: backgroundGridColumns, spacing: 8) {
                ForEach(WallpaperCatalog.builtins) { builtin in
                    imageSwatch(builtin)
                }
                uploadSwatch
            }

            backgroundGroupLabel("Gradients")
            LazyVGrid(columns: backgroundGridColumns, spacing: 8) {
                ForEach(Self.wallpaperPresets, id: \.name) { preset in
                    wallpaperSwatch(preset)
                }
            }

            backgroundGroupLabel("Basic")
            LazyVGrid(columns: backgroundGridColumns, spacing: 8) {
                noneSwatch
                desktopSwatch
                customSwatch
            }

            backgroundEditor
        }
    }

    private func backgroundGroupLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.top, 2)
    }

    /// "No background" — the recording fills the frame. A slashed circle on an
    /// elevated tile, ringed when active.
    private var noneSwatch: some View {
        swatchButton(isSelected: isNoneSelected) {
            setBackground(.none)
        } content: {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.Color.bgElevated)
                .overlay(
                    Image(systemName: "nosign")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.Color.textTertiary)
                )
        }
    }

    private func wallpaperSwatch(_ preset: WallpaperGradient) -> some View {
        swatchButton(isSelected: isWallpaperSelected(preset)) {
            selectWallpaper(preset)
        } content: {
            WallpaperPreview(gradient: preset)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        .help(preset.name)
    }

    /// A built-in image wallpaper bundled with the app.
    private func imageSwatch(_ builtin: BuiltinWallpaper) -> some View {
        swatchButton(isSelected: isBuiltinSelected(builtin)) {
            applyFloating(.image(.builtin(id: builtin.id, name: builtin.name)))
        } content: {
            WallpaperThumbnail(url: builtin.url)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        .help(builtin.name)
    }

    /// Upload-your-own tile. Shows the active upload's thumbnail when one is
    /// set (like the Custom-color tile), otherwise an upload glyph.
    private var uploadSwatch: some View {
        swatchButton(isSelected: isUploadSelected) {
            presentUploadPanel()
        } content: {
            if let ref = currentUploadRef, let rel = ref.relativePath {
                if let url = try? ProjectBundle(url: bundleURL).url(forRelativePath: rel) {
                    WallpaperThumbnail(url: url)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                }
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.Color.bgElevated)
                    .overlay(
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Theme.Color.textSecondary)
                    )
            }
        }
        .help("Upload your own image")
    }

    /// "Desktop" — derive the background from the user's actual macOS desktop
    /// wallpaper (sampled to a gradient by `WallpaperSource.live`, already wired
    /// into preview/export). A picture glyph since we can't cheaply sample the
    /// real image into this tiny swatch.
    private var desktopSwatch: some View {
        swatchButton(isSelected: isSystemWallpaperSelected) {
            selectSystemWallpaper()
        } content: {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.Color.bgElevated, Theme.Color.bgInsetCard],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    Image(systemName: "photo.fill")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.Color.textSecondary)
                )
        }
        .help("Use your desktop wallpaper")
    }

    /// Custom solid color. Shows the live picked color when a solid is active,
    /// otherwise a palette glyph inviting a custom pick.
    private var customSwatch: some View {
        swatchButton(isSelected: isCustomSolidSelected) {
            if case .solid = layout.background { return }
            setBackground(.solid(color: PixelbayCore.RGBColor(r: 0.10, g: 0.11, b: 0.14)))
        } content: {
            if case .solid(let color) = layout.background {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(swiftUIColor(from: color))
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.Color.bgElevated)
                    .overlay(
                        Image(systemName: "paintpalette.fill")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Theme.Color.textSecondary)
                    )
            }
        }
        .help("Custom color")
    }

    /// Shared swatch chrome: a fixed-height tappable tile with a hairline rim
    /// and an accent selection ring.
    private func swatchButton<Content: View>(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(height: 34)
                .frame(maxWidth: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: Theme.Stroke.hairline)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .strokeBorder(Theme.Color.accent, lineWidth: isSelected ? 2 : 0)
                )
                .shadow(color: isSelected ? Theme.Color.accent.opacity(0.35) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    /// Fine-tune editor: appears under the gallery for solid/gradient so the
    /// exact colors stay editable (preset gradients included).
    @ViewBuilder
    private var backgroundEditor: some View {
        switch layout.background {
        case .solid(let color):
            HStack {
                Text("Color").font(.caption)
                Spacer()
                ColorPicker(
                    "",
                    selection: solidColorBinding(current: color),
                    supportsOpacity: false
                )
                .labelsHidden()
            }
        case .gradient(let from, let to):
            HStack {
                Text("Gradient").font(.caption)
                Spacer()
                ColorPicker(
                    "",
                    selection: gradientStopBinding(isStart: true, current: from),
                    supportsOpacity: false
                )
                .labelsHidden()
                .help("Top")
                ColorPicker(
                    "",
                    selection: gradientStopBinding(isStart: false, current: to),
                    supportsOpacity: false
                )
                .labelsHidden()
                .help("Bottom")
            }
        case .none, .systemWallpaper, .wallpaper, .image:
            // Wallpapers/images are pick-only; None has nothing to tune.
            EmptyView()
        }
    }

    // MARK: - Background selection state

    private var isNoneSelected: Bool {
        if case .none = layout.background { return true }
        return false
    }

    private var isCustomSolidSelected: Bool {
        if case .solid = layout.background { return true }
        return false
    }

    private func isWallpaperSelected(_ preset: WallpaperGradient) -> Bool {
        if case .wallpaper(let w) = layout.background {
            return w.name == preset.name
        }
        return false
    }

    private var isSystemWallpaperSelected: Bool {
        if case .systemWallpaper = layout.background { return true }
        return false
    }

    /// Commit a background change, mirroring the padding/corner-radius
    /// bookkeeping the old segmented control did: clear padding when going to
    /// `.none`, seed a sensible default padding when turning a background on.
    private func setBackground(_ bg: Background) {
        var next = layout
        next.background = bg
        if case .none = bg {
            next.padding = 0
            next.screenCornerRadius = 0
        } else if next.padding == 0 {
            next.padding = 32
        }
        onChange(next)
    }

    /// Apply a background that should sit behind a "floating" screen — a
    /// wallpaper, desktop, or image. Seeds a generous inset + rounded screen
    /// corners, but only when they're at their defaults, so switching between
    /// backgrounds keeps a user's tuned padding / corner radius.
    private func applyFloating(_ bg: Background) {
        var next = layout
        next.background = bg
        if next.padding == 0 { next.padding = 48 }
        if next.screenCornerRadius == 0 { next.screenCornerRadius = 24 }
        onChange(next)
    }

    private func selectWallpaper(_ preset: WallpaperGradient) {
        applyFloating(.wallpaper(preset))
    }

    /// Use the user's desktop wallpaper. `WallpaperSource.live` (wired into
    /// preview/export) samples the real desktop into a gradient at render time;
    /// the `fallback` only shows if that sampling fails.
    private func selectSystemWallpaper() {
        applyFloating(.systemWallpaper(fallback: PixelbayCore.RGBColor(r: 0.10, g: 0.11, b: 0.14)))
    }

    // MARK: - Image wallpapers

    private func isBuiltinSelected(_ builtin: BuiltinWallpaper) -> Bool {
        if case .image(let ref) = layout.background { return ref.builtinID == builtin.id }
        return false
    }

    /// The active background if it's a user upload (has a relative path).
    private var currentUploadRef: WallpaperImageRef? {
        if case .image(let ref) = layout.background, ref.relativePath != nil { return ref }
        return nil
    }

    private var isUploadSelected: Bool { currentUploadRef != nil }

    private func presentUploadPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use Wallpaper"
        panel.message = "Choose an image to use as the background."
        if panel.runModal() == .OK, let src = panel.url {
            importUpload(from: src)
        }
    }

    /// Copy the picked image into the project bundle (so the project stays
    /// self-contained) and set it as the background.
    private func importUpload(from src: URL) {
        let ext = src.pathExtension.isEmpty ? "png" : src.pathExtension
        let relativePath = "backgrounds/\(UUID().uuidString).\(ext)"
        do {
            let dest = try ProjectBundle(url: bundleURL).url(forRelativePath: relativePath)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            onError("Wallpaper upload failed: \(error.localizedDescription)")
            return
        }
        let name = src.deletingPathExtension().lastPathComponent
        applyFloating(.image(.upload(relativePath: relativePath, name: name)))
    }

    private func solidColorBinding(current: PixelbayCore.RGBColor) -> Binding<Color> {
        Binding(
            get: { swiftUIColor(from: current) },
            set: { newColor in
                var next = layout
                next.background = .solid(color: rgbColor(from: newColor))
                onChange(next)
            }
        )
    }

    private func gradientStopBinding(isStart: Bool, current: PixelbayCore.RGBColor) -> Binding<Color> {
        Binding(
            get: { swiftUIColor(from: current) },
            set: { newColor in
                guard case .gradient(let from, let to) = layout.background else { return }
                let stop = rgbColor(from: newColor)
                var next = layout
                next.background = isStart
                    ? .gradient(from: stop, to: to)
                    : .gradient(from: from, to: stop)
                onChange(next)
            }
        )
    }

    // MARK: - Padding

    private var paddingRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Padding").font(.caption)
                Spacer()
                Text("\(Int(layout.padding)) px")
                    .font(Theme.Font.monoTimecode)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            PBSlider(
                value: Binding<Double>(
                    get: { layout.padding },
                    set: { newValue in
                        var next = layout
                        next.padding = newValue
                        onChange(next)
                    }
                ),
                in: 0...120
            )
        }
    }

    // MARK: - Corner radius

    /// Rounds the screen layer itself. Applying a wallpaper/desktop background
    /// seeds a default radius (`applyFloating`); this slider lets the user tune
    /// it — including back to 0 for sharp corners. Shown alongside Padding (same
    /// gate) since both only matter once the screen is inset over a background.
    private var cornerRadiusRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Corner radius").font(.caption)
                Spacer()
                Text("\(Int(layout.screenCornerRadius)) px")
                    .font(Theme.Font.monoTimecode)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            PBSlider(
                value: Binding<Double>(
                    get: { layout.screenCornerRadius },
                    set: { newValue in
                        var next = layout
                        next.screenCornerRadius = newValue
                        onChange(next)
                    }
                ),
                in: 0...120
            )
        }
    }
}

private enum LayoutModeTag: Hashable {
    case pip
    case split
    /// Display-only — surfaced in the mode control while a free-form custom
    /// arrangement is active. Selecting it does nothing; you enter custom by
    /// dragging in the preview.
    case custom
}

/// SwiftUI preview of a `WallpaperGradient` — the inspector swatch. Renders the
/// same base + soft radial blobs the Metal compositor draws (approximated with
/// `RadialGradient` layers), so the picker thumbnail reads like the exported
/// frame. The live editor preview is the real Metal render, so exactness here
/// isn't required.
struct WallpaperPreview: View {
    let gradient: WallpaperGradient

    var body: some View {
        GeometryReader { geo in
            ZStack {
                swiftUIColor(from: gradient.base)
                ForEach(Array(gradient.blobs.enumerated()), id: \.offset) { _, blob in
                    let center = swiftUIColor(from: blob.color)   // alpha = strength
                    RadialGradient(
                        gradient: Gradient(colors: [center, center.opacity(0)]),
                        center: UnitPoint(x: blob.x, y: blob.y),
                        startRadius: 0,
                        endRadius: max(1, blob.radius * geo.size.height)
                    )
                }
            }
        }
    }
}

/// Image-wallpaper swatch content: a downscaled, aspect-filled thumbnail of a
/// wallpaper file. Thumbnails are decoded + cached by `WallpaperCatalog`, so a
/// gallery of these stays cheap. Falls back to a flat tile while/if the image
/// can't be read.
struct WallpaperThumbnail: View {
    let url: URL

    var body: some View {
        GeometryReader { geo in
            if let image = WallpaperCatalog.thumbnail(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                Rectangle().fill(Theme.Color.bgElevated)
            }
        }
    }
}

private func meshBlob(
    _ r: Double, _ g: Double, _ b: Double,
    strength: Double, x: Double, y: Double, radius: Double
) -> WallpaperGradient.Blob {
    WallpaperGradient.Blob(
        color: PixelbayCore.RGBColor(r: r, g: g, b: b, a: strength),
        x: x, y: y, radius: radius
    )
}

extension BackgroundInspector {
    /// Curated "wallpaper" mesh gradients — the Screen Studio / Loom look,
    /// rendered procedurally (no bundled images). Cool-leaning to match the
    /// app's premium palette, with a few warm and light options for variety.
    static let wallpaperPresets: [WallpaperGradient] = [
        WallpaperGradient(name: "Aurora", base: PixelbayCore.RGBColor(r: 0.05, g: 0.06, b: 0.13), blobs: [
            meshBlob(0.20, 0.42, 0.92, strength: 0.90, x: 0.18, y: 0.20, radius: 0.95),
            meshBlob(0.52, 0.22, 0.85, strength: 0.85, x: 0.82, y: 0.85, radius: 1.00),
            meshBlob(0.10, 0.50, 0.72, strength: 0.55, x: 0.15, y: 0.92, radius: 0.80),
        ]),
        WallpaperGradient(name: "Royal", base: PixelbayCore.RGBColor(r: 0.06, g: 0.07, b: 0.20), blobs: [
            meshBlob(0.20, 0.30, 0.85, strength: 0.90, x: 0.25, y: 0.25, radius: 1.00),
            meshBlob(0.35, 0.20, 0.80, strength: 0.80, x: 0.80, y: 0.80, radius: 0.95),
            meshBlob(0.15, 0.45, 0.90, strength: 0.55, x: 0.85, y: 0.20, radius: 0.75),
        ]),
        WallpaperGradient(name: "Ocean", base: PixelbayCore.RGBColor(r: 0.02, g: 0.08, b: 0.16), blobs: [
            meshBlob(0.10, 0.45, 0.80, strength: 0.90, x: 0.20, y: 0.30, radius: 1.00),
            meshBlob(0.12, 0.58, 0.74, strength: 0.70, x: 0.85, y: 0.75, radius: 0.90),
            meshBlob(0.05, 0.22, 0.52, strength: 0.75, x: 0.55, y: 1.00, radius: 0.85),
        ]),
        WallpaperGradient(name: "Lavender", base: PixelbayCore.RGBColor(r: 0.12, g: 0.10, b: 0.20), blobs: [
            meshBlob(0.52, 0.36, 0.86, strength: 0.90, x: 0.22, y: 0.24, radius: 0.95),
            meshBlob(0.72, 0.46, 0.80, strength: 0.70, x: 0.82, y: 0.82, radius: 0.95),
            meshBlob(0.36, 0.42, 0.86, strength: 0.65, x: 0.85, y: 0.18, radius: 0.75),
        ]),
        WallpaperGradient(name: "Sunset", base: PixelbayCore.RGBColor(r: 0.15, g: 0.06, b: 0.12), blobs: [
            meshBlob(0.96, 0.46, 0.36, strength: 0.88, x: 0.20, y: 0.78, radius: 0.95),
            meshBlob(0.86, 0.30, 0.55, strength: 0.78, x: 0.78, y: 0.85, radius: 0.90),
            meshBlob(0.40, 0.18, 0.58, strength: 0.70, x: 0.70, y: 0.20, radius: 0.85),
        ]),
        WallpaperGradient(name: "Rose", base: PixelbayCore.RGBColor(r: 0.14, g: 0.08, b: 0.12), blobs: [
            meshBlob(0.92, 0.50, 0.62, strength: 0.85, x: 0.25, y: 0.28, radius: 0.95),
            meshBlob(0.76, 0.34, 0.56, strength: 0.72, x: 0.82, y: 0.80, radius: 0.92),
            meshBlob(0.50, 0.24, 0.50, strength: 0.62, x: 0.18, y: 0.88, radius: 0.78),
        ]),
        WallpaperGradient(name: "Ember", base: PixelbayCore.RGBColor(r: 0.12, g: 0.06, b: 0.08), blobs: [
            meshBlob(0.86, 0.40, 0.30, strength: 0.85, x: 0.78, y: 0.30, radius: 0.95),
            meshBlob(0.70, 0.24, 0.34, strength: 0.72, x: 0.22, y: 0.82, radius: 0.92),
            meshBlob(0.40, 0.15, 0.30, strength: 0.62, x: 0.20, y: 0.20, radius: 0.78),
        ]),
        WallpaperGradient(name: "Slate", base: PixelbayCore.RGBColor(r: 0.10, g: 0.11, b: 0.14), blobs: [
            meshBlob(0.26, 0.31, 0.42, strength: 0.85, x: 0.24, y: 0.26, radius: 1.00),
            meshBlob(0.18, 0.20, 0.28, strength: 0.80, x: 0.82, y: 0.82, radius: 0.95),
            meshBlob(0.32, 0.36, 0.46, strength: 0.55, x: 0.85, y: 0.20, radius: 0.75),
        ]),
        WallpaperGradient(name: "Graphite", base: PixelbayCore.RGBColor(r: 0.08, g: 0.09, b: 0.11), blobs: [
            meshBlob(0.24, 0.26, 0.30, strength: 0.80, x: 0.28, y: 0.30, radius: 1.00),
            meshBlob(0.14, 0.15, 0.18, strength: 0.80, x: 0.80, y: 0.80, radius: 0.95),
            meshBlob(0.30, 0.32, 0.36, strength: 0.50, x: 0.80, y: 0.22, radius: 0.70),
        ]),
        WallpaperGradient(name: "Sky", base: PixelbayCore.RGBColor(r: 0.85, g: 0.90, b: 0.97), blobs: [
            meshBlob(0.58, 0.78, 0.96, strength: 0.75, x: 0.22, y: 0.26, radius: 0.95),
            meshBlob(0.74, 0.70, 0.95, strength: 0.62, x: 0.82, y: 0.80, radius: 0.95),
            meshBlob(0.92, 0.86, 0.96, strength: 0.55, x: 0.80, y: 0.20, radius: 0.75),
        ]),
        WallpaperGradient(name: "Peach", base: PixelbayCore.RGBColor(r: 0.96, g: 0.88, b: 0.84), blobs: [
            meshBlob(0.99, 0.72, 0.62, strength: 0.70, x: 0.22, y: 0.78, radius: 0.95),
            meshBlob(0.92, 0.76, 0.88, strength: 0.60, x: 0.80, y: 0.82, radius: 0.92),
            meshBlob(0.82, 0.86, 0.96, strength: 0.55, x: 0.74, y: 0.20, radius: 0.80),
        ]),
        WallpaperGradient(name: "Paper", base: PixelbayCore.RGBColor(r: 0.94, g: 0.95, b: 0.97), blobs: [
            meshBlob(0.82, 0.84, 0.90, strength: 0.70, x: 0.26, y: 0.28, radius: 1.00),
            meshBlob(0.88, 0.86, 0.92, strength: 0.60, x: 0.80, y: 0.82, radius: 0.95),
        ]),
    ]
}

private func swiftUIColor(from c: PixelbayCore.RGBColor) -> Color {
    Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
}

// NSColor(c) can return a color in any space depending on the picker's
// origin; we force-convert to sRGB so the stored RGBColor matches the
// component scale the compositor reads back.
private func rgbColor(from c: Color) -> PixelbayCore.RGBColor {
    let resolved = NSColor(c).usingColorSpace(.sRGB) ?? NSColor.black
    return PixelbayCore.RGBColor(
        r: Double(resolved.redComponent),
        g: Double(resolved.greenComponent),
        b: Double(resolved.blueComponent),
        a: Double(resolved.alphaComponent)
    )
}

private extension CamPosition {
    var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenter: return "Top Center"
        case .topRight: return "Top Right"
        case .middleLeft: return "Middle Left"
        case .center: return "Center"
        case .middleRight: return "Middle Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomRight: return "Bottom Right"
        }
    }
}
