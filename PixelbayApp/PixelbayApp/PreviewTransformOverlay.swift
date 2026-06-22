import PixelbayCore
import PixelbayDesignSystem
import SwiftUI

// Interactive transform layer drawn over the editor preview. Lets the user
// click the screen or webcam and drag to move / corner-drag to scale, producing
// a free-form `LayoutMode.custom` arrangement. Modeled on
// `ZoomFollowSafeZoneOverlay` for the output-space ↔ container-space mapping
// (`fittedVideoRect`), but interactive.
//
// All per-gesture state lives HERE (not on ProjectView) so a drag re-evaluates
// only this subtree — the same isolation principle as `ResizableVSplit`. The
// committed rects arrive as `let` inputs and change only on revision
// (apply/undo/redo); the live `dragRect` overrides them while dragging.
//
// The fiddly geometry (clamp, aspect-lock, snap) lives in PixelbayCore
// (`NormalizedRect` + `SnapGuides`) where it's unit-tested.
struct PreviewTransformOverlay: View {
    enum Target: Hashable { case screen, webcam }

    /// Committed/resolved rects in normalized output space (0…1). The webcam is
    /// nil for cam-less recordings.
    let screenRect: NormalizedRect
    let webcamRect: NormalizedRect?
    let outputSize: CGSize
    let camShape: CamShape
    /// Letterbox (false) vs crop (true) — must match the player's fit so the
    /// handles sit exactly on the rendered content.
    let fill: Bool
    /// Throttled live feedback while dragging (ProjectView rebuilds just the
    /// videoComposition). Emits the would-be rects for both layers.
    let onLivePreview: (_ screen: NormalizedRect, _ webcam: NormalizedRect?) -> Void
    /// Single undoable commit at the end of a gesture / after a nudge settles.
    let onCommit: (_ screen: NormalizedRect, _ webcam: NormalizedRect?) -> Void

    @State private var selection: Target?
    @State private var dragTarget: Target?
    @State private var dragRect: NormalizedRect?
    @State private var dragMode: DragMode?
    @State private var vGuides: [Double] = []
    @State private var hGuides: [Double] = []
    @State private var readout: String?
    @State private var hovered: Target?
    @State private var nudgeCommitTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private enum DragMode {
        case move(start: NormalizedRect, grab: CGPoint)   // grab in normalized space
        case resize(corner: RectCorner, start: NormalizedRect)
    }

    // Tuning.
    private let handleHitRadius: CGFloat = 12
    private let handleVisualSize: CGFloat = 9
    private let snapThresholdPt: CGFloat = 7
    private let screenMinWidth = 0.10
    private let webcamMinWidth = 0.05

    var body: some View {
        GeometryReader { geo in
            let container = geo.size
            let video = fittedVideoRect(container: container)
            ZStack {
                // Full-area hit target: clicks in the letterbox deselect.
                Color.clear
                    .contentShape(Rectangle())

                guideLines(video: video)
                if let hovered, hovered != selection {
                    outline(for: hovered, video: video)
                        .stroke(Theme.Color.accent.opacity(0.35), lineWidth: 1)
                }
                if let selection {
                    selectionChrome(target: selection, video: video)
                }
                if let readout {
                    readoutPill(text: readout, video: video, container: container)
                }
            }
            .frame(width: container.width, height: container.height)
            .contentShape(Rectangle())
            .focusable(selection != nil)
            .focused($focused)
            // Keep focusability (arrow-key nudge) but suppress the system focus
            // ring — otherwise selecting a layer draws a blue ring around the
            // whole preview (this view fills the container). The selection
            // chrome + handles are drawn manually and are unaffected.
            .focusEffectDisabled()
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt): hovered = hitTestBody(pt, video: video)
                case .ended: hovered = nil
                }
            }
            .gesture(dragGesture(video: video, container: container))
            .onKeyPress(phases: .down) { press in handleKey(press) }
        }
        // Inputs change only on revision (commit/undo/redo/preset). When they
        // land, drop the live drag rect so the overlay reflects the committed
        // truth without a flash.
        .onChange(of: screenRect) { _, _ in clearDragState() }
        .onChange(of: webcamRect) { _, _ in clearDragState() }
    }

    // MARK: - Selection chrome

    @ViewBuilder
    private func selectionChrome(target: Target, video: CGRect) -> some View {
        if let rect = displayedRect(target) {
            outline(for: target, video: video)
                .stroke(Theme.Color.accent, lineWidth: 1.5)
            ForEach(RectCorner.allCases, id: \.self) { corner in
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Theme.Color.accent, lineWidth: 1.5))
                    .frame(width: handleVisualSize, height: handleVisualSize)
                    .position(cornerPoint(rect, corner: corner, video: video))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
        }
    }

    private func outline(for target: Target, video: CGRect) -> Path {
        guard let rect = displayedRect(target) else { return Path() }
        return Path(roundedRect: toContainer(rect, video: video), cornerRadius: 1)
    }

    @ViewBuilder
    private func guideLines(video: CGRect) -> some View {
        ForEach(vGuides, id: \.self) { line in
            Rectangle()
                .fill(Theme.Color.accent)
                .frame(width: 1, height: video.height)
                .position(x: video.minX + CGFloat(line) * video.width, y: video.midY)
        }
        ForEach(hGuides, id: \.self) { line in
            Rectangle()
                .fill(Theme.Color.accent)
                .frame(width: video.width, height: 1)
                .position(x: video.midX, y: video.minY + CGFloat(line) * video.height)
        }
    }

    private func readoutPill(text: String, video: CGRect, container: CGSize) -> some View {
        let anchorRect = displayedRect(dragTarget ?? selection ?? .screen)
        let frame = anchorRect.map { toContainer($0, video: video) } ?? video
        return Text(text)
            .font(Theme.Font.monoTimecode)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.7), in: Capsule())
            .position(
                x: min(max(frame.midX, video.minX + 40), video.maxX - 40),
                y: max(frame.minY - 14, video.minY + 12)
            )
            .allowsHitTesting(false)
    }

    // MARK: - Gesture

    private func dragGesture(video: CGRect, container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragMode == nil {
                    beginDrag(at: value.startLocation, video: video)
                }
                guard let mode = dragMode, let target = dragTarget else { return }
                let cur = toNormalizedPoint(value.location, video: video)
                let next: NormalizedRect
                switch mode {
                case .move(let start, let grab):
                    let moved = start.translated(dx: cur.x - Double(grab.x), dy: cur.y - Double(grab.y))
                    let threshold = Double(snapThresholdPt / max(1, video.width))
                    let snapped = SnapGuides.snap(moved, threshold: threshold)
                    next = snapped.rect
                    vGuides = snapped.vertical
                    hGuides = snapped.horizontal
                    readout = "X \(pct(next.x))  Y \(pct(next.y))"
                case .resize(let corner, let start):
                    next = start.resized(
                        draggingCorner: corner,
                        toX: cur.x, toY: cur.y,
                        aspect: aspect(of: target),
                        minWidth: minWidth(of: target)
                    )
                    vGuides = []
                    hGuides = []
                    readout = "\(pct(next.width)) × \(pct(next.height))"
                }
                dragRect = next
                emitLive(target: target, rect: next)
            }
            .onEnded { value in
                defer { dragMode = nil; vGuides = []; hGuides = []; readout = nil }
                guard let target = dragTarget, let rect = dragRect else { return }
                // A press with no real movement is a pure select/deselect — no commit.
                let moved = hypot(value.translation.width, value.translation.height) > 1.5
                if moved {
                    commit(target: target, rect: rect)
                    // Keep dragRect until the committed input lands (cleared by onChange).
                } else {
                    dragRect = nil
                    dragTarget = nil
                }
            }
    }

    /// First tick of a gesture: decide what was grabbed and set up the drag.
    private func beginDrag(at point: CGPoint, video: CGRect) {
        // 1. Corner handle of the selected layer.
        if let sel = selection, let rect = displayedRect(sel) {
            for corner in RectCorner.allCases {
                if distance(cornerPoint(rect, corner: corner, video: video), point) <= handleHitRadius {
                    dragTarget = sel
                    dragMode = .resize(corner: corner, start: rect)
                    focused = true
                    return
                }
            }
        }
        // 2. Body — webcam is on top, then screen. Else deselect.
        if let target = hitTestBody(point, video: video) {
            selection = target
            dragTarget = target
            let grab = toNormalizedPoint(point, video: video)
            dragMode = .move(start: displayedRect(target) ?? screenRect, grab: grab)
            focused = true
        } else {
            selection = nil
            dragTarget = nil
            dragMode = nil
            focused = false
        }
    }

    // MARK: - Hit testing

    /// Topmost layer body under `point` (webcam above screen), or nil.
    private func hitTestBody(_ point: CGPoint, video: CGRect) -> Target? {
        if let webcam = webcamRect, toContainer(displayed(webcam, .webcam), video: video).contains(point) {
            return .webcam
        }
        if toContainer(displayed(screenRect, .screen), video: video).contains(point) {
            return .screen
        }
        return nil
    }

    private func displayed(_ committed: NormalizedRect, _ target: Target) -> NormalizedRect {
        (dragTarget == target ? dragRect : nil) ?? committed
    }

    private func displayedRect(_ target: Target) -> NormalizedRect? {
        switch target {
        case .screen: return displayed(screenRect, .screen)
        case .webcam: return webcamRect.map { displayed($0, .webcam) }
        }
    }

    // MARK: - Keyboard nudge

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape {
            selection = nil
            dragTarget = nil
            focused = false
            return .handled
        }
        guard let target = selection else { return .ignored }
        let step = press.modifiers.contains(.shift) ? 10.0 : 1.0
        switch press.key {
        case .leftArrow:  nudge(target, dxPx: -step, dyPx: 0); return .handled
        case .rightArrow: nudge(target, dxPx: step, dyPx: 0); return .handled
        case .upArrow:    nudge(target, dxPx: 0, dyPx: -step); return .handled
        case .downArrow:  nudge(target, dxPx: 0, dyPx: step); return .handled
        default:          return .ignored
        }
    }

    private func nudge(_ target: Target, dxPx: Double, dyPx: Double) {
        guard outputSize.width > 0, outputSize.height > 0 else { return }
        let base = (dragTarget == target ? dragRect : nil) ?? committed(target)
        guard let base else { return }
        let moved = base.translated(dx: dxPx / Double(outputSize.width), dy: dyPx / Double(outputSize.height))
        dragTarget = target
        dragRect = moved
        emitLive(target: target, rect: moved)
        // Coalesce a burst of presses into one undo entry: commit ~350ms after
        // the last key.
        nudgeCommitTask?.cancel()
        nudgeCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            commit(target: target, rect: moved)
        }
    }

    // MARK: - Emit

    private func emitLive(target: Target, rect: NormalizedRect) {
        switch target {
        case .screen: onLivePreview(rect, webcamRect)
        case .webcam: onLivePreview(screenRect, rect)
        }
    }

    private func commit(target: Target, rect: NormalizedRect) {
        switch target {
        case .screen: onCommit(rect, webcamRect)
        case .webcam: onCommit(screenRect, rect)
        }
    }

    private func committed(_ target: Target) -> NormalizedRect? {
        switch target {
        case .screen: return screenRect
        case .webcam: return webcamRect
        }
    }

    private func clearDragState() {
        dragRect = nil
        dragTarget = nil
        dragMode = nil
        vGuides = []
        hGuides = []
        readout = nil
    }

    // MARK: - Geometry / mapping

    /// Aspect ratio in NORMALIZED space (width/height of the rect in 0…1
    /// coordinates), which is what `resized` operates on. A layer's *pixel*
    /// aspect divided by the output's pixel aspect: e.g. a 16:9 webcam inside a
    /// 16:9 canvas is a square in normalized space (aspect 1), and the screen —
    /// whose content fills the output aspect — is always 1.
    private func aspect(of target: Target) -> Double {
        let outputAspect = outputSize.height > 0
            ? Double(outputSize.width / outputSize.height)
            : 16.0 / 9.0
        let pixelAspect: Double
        switch target {
        case .screen: pixelAspect = outputAspect
        case .webcam: pixelAspect = camShape == .circle ? 1 : 16.0 / 9.0
        }
        return pixelAspect / outputAspect
    }

    private func minWidth(of target: Target) -> Double {
        target == .screen ? screenMinWidth : webcamMinWidth
    }

    private func toContainer(_ n: NormalizedRect, video: CGRect) -> CGRect {
        CGRect(
            x: video.minX + CGFloat(n.x) * video.width,
            y: video.minY + CGFloat(n.y) * video.height,
            width: CGFloat(n.width) * video.width,
            height: CGFloat(n.height) * video.height
        )
    }

    private func cornerPoint(_ n: NormalizedRect, corner: RectCorner, video: CGRect) -> CGPoint {
        let c = n.corner(corner)
        return CGPoint(x: video.minX + CGFloat(c.x) * video.width, y: video.minY + CGFloat(c.y) * video.height)
    }

    private func toNormalizedPoint(_ p: CGPoint, video: CGRect) -> CGPoint {
        guard video.width > 0, video.height > 0 else { return .zero }
        return CGPoint(x: (p.x - video.minX) / video.width, y: (p.y - video.minY) / video.height)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    /// Letterbox/crop fit of the output frame within the container — mirrors
    /// `ZoomFollowSafeZoneOverlay.fittedVideoRect`.
    private func fittedVideoRect(container: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0,
              outputSize.width > 0, outputSize.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let containerAspect = container.width / container.height
        let videoAspect = outputSize.width / outputSize.height
        let width: CGFloat
        let height: CGFloat
        if fill {
            if containerAspect > videoAspect {
                width = container.width
                height = container.width / videoAspect
            } else {
                height = container.height
                width = container.height * videoAspect
            }
        } else {
            if containerAspect > videoAspect {
                height = container.height
                width = container.height * videoAspect
            } else {
                width = container.width
                height = container.width / videoAspect
            }
        }
        return CGRect(
            x: (container.width - width) / 2,
            y: (container.height - height) / 2,
            width: width,
            height: height
        )
    }
}
