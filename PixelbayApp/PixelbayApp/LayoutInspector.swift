import AppKit
import PixelbayCore
import SwiftUI

// Phase 3a Inspector section: cam-position grid, cam shape, background.
// Edits funnel back through a single `onChange` closure that dispatches a
// `SetLayoutPresetCommand` — coalescing logic (debouncing slider drags,
// dropping no-op edits) lives in the caller's Task so the view stays a
// dumb form. Background-color edits commit on focus loss / Enter via
// SwiftUI's ColorPicker which already coalesces continuous picker drags.

struct LayoutInspector: View {
    let layout: LayoutPreset
    let cursorSettings: CursorSettings
    let onChange: (LayoutPreset) -> Void
    let onCursorChange: (CursorSettings) -> Void

    // Live drag value for the cursor-size slider — mirrors the
    // EffectsInspector.zoomFactorSlider pattern. The model is only
    // mutated on `onEditingChanged: false`, so the undo stack records one
    // SetCursorSettingsCommand per gesture instead of one per slider tick.
    @State private var previewCursorScale: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Layout").font(.headline)

            modeRow
            if case .pip = layout.mode {
                positionGrid
                camSizeRow
            } else if case .splitHorizontal(_, let fraction) = layout.mode {
                splitControls(fraction: fraction)
            }

            camShapeRow
            backgroundRow
            backgroundColorRow

            if layout.padding > 0 || hasBackground {
                paddingRow
            }

            Divider().padding(.vertical, 2)
            cursorSection
        }
    }

    // MARK: - Mode

    private var modeRow: some View {
        HStack {
            Text("Mode")
            Spacer()
            Picker("", selection: modeBinding) {
                Text("Picture-in-Picture").tag(LayoutModeTag.pip)
                Text("Side-by-Side").tag(LayoutModeTag.split)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 200)
        }
    }

    private var modeBinding: Binding<LayoutModeTag> {
        Binding(
            get: {
                switch layout.mode {
                case .pip: return .pip
                case .splitHorizontal: return .split
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
                }
            }
        )
    }

    // MARK: - PiP grid + size

    private var positionGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cam Position").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 4) {
                ForEach(positionRows, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(row, id: \.self) { pos in
                            positionButton(pos)
                        }
                    }
                }
            }
        }
    }

    private var positionRows: [[CamPosition]] {
        [
            [.topLeft, .topCenter, .topRight],
            [.middleLeft, .center, .middleRight],
            [.bottomLeft, .bottomCenter, .bottomRight]
        ]
    }

    private func positionButton(_ pos: CamPosition) -> some View {
        let isSelected: Bool = {
            if case .pip(let current, _) = layout.mode { return current == pos }
            return false
        }()
        return Button {
            guard case .pip(_, let size) = layout.mode else { return }
            var next = layout
            next.mode = .pip(position: pos, size: size)
            onChange(next)
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.18))
                .frame(width: 28, height: 18)
        }
        .buttonStyle(.plain)
        .help(pos.label)
    }

    private var camSizeRow: some View {
        HStack {
            Text("Cam Size").font(.caption)
            Spacer()
            Picker("", selection: sizeBinding) {
                Text("S").tag(CamSizePreset.small)
                Text("M").tag(CamSizePreset.medium)
                Text("L").tag(CamSizePreset.large)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
            Picker("", selection: splitSideBinding) {
                Text("Left").tag(HorizontalSide.left)
                Text("Right").tag(HorizontalSide.right)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 130)
        }
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Screen Share").font(.caption)
                Spacer()
                Text(String(format: "%.0f%%", fraction * 100))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
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
            Picker("", selection: camShapeBinding) {
                Text("Rectangle").tag(CamShape.rectangle)
                Text("Circle").tag(CamShape.circle)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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

    // MARK: - Background

    private var hasBackground: Bool {
        if case .none = layout.background { return false }
        return true
    }

    private var backgroundRow: some View {
        HStack {
            Text("Background").font(.caption)
            Spacer()
            Picker("", selection: backgroundKindBinding) {
                Text("None").tag(BackgroundKind.none)
                Text("Solid").tag(BackgroundKind.solid)
                Text("Gradient").tag(BackgroundKind.gradient)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 200)
        }
    }

    @ViewBuilder
    private var backgroundColorRow: some View {
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
        case .none, .systemWallpaper:
            EmptyView()
        }
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

    private var backgroundKindBinding: Binding<BackgroundKind> {
        Binding(
            get: {
                switch layout.background {
                case .none: return .none
                case .solid: return .solid
                case .gradient: return .gradient
                case .systemWallpaper: return .solid
                }
            },
            set: { newKind in
                var next = layout
                switch newKind {
                case .none:
                    next.background = .none
                case .solid:
                    next.background = .solid(color: RGBColor(r: 0.06, g: 0.07, b: 0.10))
                case .gradient:
                    next.background = .gradient(
                        from: RGBColor(r: 0.06, g: 0.07, b: 0.10),
                        to: RGBColor(r: 0.15, g: 0.18, b: 0.25)
                    )
                }
                if case .none = next.background {
                    next.padding = 0
                    next.screenCornerRadius = 0
                } else if next.padding == 0 {
                    next.padding = 32
                }
                onChange(next)
            }
        )
    }

    // MARK: - Cursor (Phase 3c)

    @ViewBuilder
    private var cursorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cursor").font(.caption.bold()).foregroundStyle(.secondary)
            cursorSizeSlider
        }
    }

    private var cursorSizeSlider: some View {
        let liveValue = previewCursorScale ?? cursorSettings.scale
        let committedValue = cursorSettings.scale
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Size").font(.caption)
                Spacer()
                Text(String(format: "%.2f×", liveValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding<Double>(
                    get: { liveValue },
                    set: { newValue in previewCursorScale = newValue }
                ),
                in: 0.5...4.0,
                onEditingChanged: { isEditing in
                    guard !isEditing, let final = previewCursorScale else { return }
                    previewCursorScale = nil
                    // Epsilon guard — sub-millimetre slider noise on
                    // release shouldn't write a no-op command to the
                    // undo stack.
                    if abs(final - committedValue) < 0.005 { return }
                    var next = cursorSettings
                    next.scale = final
                    onCursorChange(next)
                }
            )
        }
    }

    // MARK: - Padding

    private var paddingRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Padding").font(.caption)
                Spacer()
                Text("\(Int(layout.padding)) px")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
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
}

private enum LayoutModeTag: Hashable {
    case pip
    case split
}

private enum BackgroundKind: Hashable {
    case none
    case solid
    case gradient
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
