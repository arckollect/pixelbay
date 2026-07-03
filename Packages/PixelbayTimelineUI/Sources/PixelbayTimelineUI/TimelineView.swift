#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import ImageIO
import OSLog
import PixelbayCore
import PixelbayDesignSystem
import PixelbayEditor
import SwiftUI

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "TimelineView")

// SwiftUI host for the AppKit-backed timeline. Per HANDOFF §5: the track
// area is an NSView (CALayer-backed) because SwiftUI 5's gesture / scroll
// / redraw still struggles with fine-grained scrubbing and simultaneous
// multi-clip drag at high zoom. The chrome (toolbar / inspector / media
// tab) stays in SwiftUI.
//
// Phase 2 v0.1 supports: read-only visualization, click-to-select, and
// drag interactions for Move + Trim (one EditCommand per drag — see
// `TimelineDragPreview`). Option-click split, waveforms, and playhead
// sync are subsequent slices.

public struct TimelineView: NSViewRepresentable {
    public let project: Project
    public var bundleURL: URL?
    public var pixelsPerSecond: CGFloat
    public var trackHeight: CGFloat
    public var scrollX: CGFloat
    public var selectedClipID: ClipID?
    public var selectedEffectKeyframeID: EffectKeyframeID?
    /// Cheap identity for the project. Bumped by the host on every
    /// committed edit (apply / undo / redo) — paired with the simple
    /// inputs above it forms a "did anything that needs a rebuild
    /// change?" check so the NSView can skip the full layer rebuild
    /// when only the playhead moved (~30fps). Without this, every
    /// PreviewPlayer time-observer tick rebuilds every CALayer.
    public var revision: Int
    /// Player playhead position in timeline-domain seconds. nil hides the
    /// overlay (e.g. before the player loads). Updated frequently during
    /// playback (~30fps via PreviewPlayer's periodic time observer); the
    /// NSView fast-paths the playhead-only update so we don't rebuild
    /// every CALayer per frame.
    public var playheadTime: RationalTime?
    public var onSelect: (ClipID?) -> Void
    public var onSelectEffectKeyframe: (EffectKeyframeID?) -> Void
    /// Posted on mouseUp at the end of a drag — the host (`ProjectView`)
    /// dispatches it through `ProjectDocument.apply(_:)`. Pure value type
    /// so it crosses the SwiftUI / AppKit boundary cleanly.
    public var onApplyCommand: (any EditCommand) -> Void
    /// Called on ruler click + drag with the timeline-domain time at the
    /// pointer. Host (ProjectView) seeks the PreviewPlayer.
    public var onScrub: (RationalTime) -> Void
    /// Per-row height overrides keyed by `TimelineDisplayRow.id` — rows
    /// absent from the map use `trackHeight`. View state owned by the host.
    public var rowHeightOverrides: [String: CGFloat]
    /// Fired on mouseUp of a row-resize drag with the FULL updated override
    /// map (existing overrides + the dragged row). The host stores it and
    /// passes it back via `rowHeightOverrides`.
    public var onRowHeightsChange: ([String: CGFloat]) -> Void
    /// True while the host is mid-drag on a continuous geometry control
    /// (track-height / zoom slider). Suppresses thumbnail + waveform layers
    /// so per-tick rebuilds stay allocation-free; content returns on release.
    public var suppressContent: Bool

    public init(
        project: Project,
        bundleURL: URL? = nil,
        pixelsPerSecond: CGFloat = TimelineLayoutCalculator.defaultPixelsPerSecond,
        trackHeight: CGFloat = TimelineLayoutCalculator.defaultTrackHeight,
        scrollX: CGFloat = 0,
        selectedClipID: ClipID?,
        selectedEffectKeyframeID: EffectKeyframeID? = nil,
        playheadTime: RationalTime? = nil,
        revision: Int = 0,
        rowHeightOverrides: [String: CGFloat] = [:],
        suppressContent: Bool = false,
        onSelect: @escaping (ClipID?) -> Void,
        onSelectEffectKeyframe: @escaping (EffectKeyframeID?) -> Void = { _ in },
        onApplyCommand: @escaping (any EditCommand) -> Void = { _ in },
        onScrub: @escaping (RationalTime) -> Void = { _ in },
        onRowHeightsChange: @escaping ([String: CGFloat]) -> Void = { _ in }
    ) {
        self.project = project
        self.bundleURL = bundleURL
        self.pixelsPerSecond = pixelsPerSecond
        self.trackHeight = trackHeight
        self.scrollX = scrollX
        self.selectedClipID = selectedClipID
        self.selectedEffectKeyframeID = selectedEffectKeyframeID
        self.playheadTime = playheadTime
        self.revision = revision
        self.rowHeightOverrides = rowHeightOverrides
        self.suppressContent = suppressContent
        self.onSelect = onSelect
        self.onSelectEffectKeyframe = onSelectEffectKeyframe
        self.onApplyCommand = onApplyCommand
        self.onScrub = onScrub
        self.onRowHeightsChange = onRowHeightsChange
    }

    // We wrap our NSView in an NSScrollView (not SwiftUI's ScrollView)
    // because:
    //   1. SwiftUI's ScrollView fights `TimelineNSView.isFlipped = true`.
    //      With a flipped NSView under SwiftUI's ScrollView, the
    //      ScrollView's anchor lands on the bottom of our content (the
    //      last track) instead of the top (the ruler) — and worse,
    //      `defaultScrollAnchor(.topLeading)` keeps re-snapping the user
    //      back there on every PreviewPlayer time-observer tick.
    //   2. NSScrollView respects `documentView.isFlipped`: scroll origin
    //      (0,0) is the top-left of content, the ruler is visible by
    //      default, and there's no SwiftUI re-anchor running on each
    //      frame. AppKit also handles trackpad / scroll-wheel
    //      ergonomics natively.
    //   3. Enables the sticky-ruler `addFloatingSubview(_:for: .vertical)`
    //      machinery below — the ruler stays pinned to the top of the
    //      viewport during vertical scroll while still tracking
    //      horizontal scroll (so tick / clip alignment holds at every
    //      scroll position).
    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = TimelineScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        // Overlay scrollers float over content instead of taking layout width,
        // so they can't appear/disappear and reflow the lanes mid-resize
        // (another potential source of resize twitch).
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        // Match the flipped documentView so AppKit places (0,0) at top.
        // The clip view must not draw its own background: where the
        // document doesn't cover the viewport (mid-resize, before the
        // floor-sizing pass below lands) a drawing clip view paints the
        // system windowBackground gray — a visible block on the dark
        // canvas.
        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        scroll.contentView = clipView
        let timeline = TimelineNSView()
        timeline.onSelect = onSelect
        timeline.onSelectEffectKeyframe = onSelectEffectKeyframe
        timeline.onApplyCommand = onApplyCommand
        timeline.onScrub = onScrub
        timeline.onRowHeightsChange = onRowHeightsChange
        timeline.update(project: project, bundleURL: bundleURL, pixelsPerSecond: pixelsPerSecond, trackHeight: trackHeight, scrollX: scrollX, selectedClipID: selectedClipID, selectedEffectKeyframeID: selectedEffectKeyframeID, revision: revision, rowHeightOverrides: rowHeightOverrides, suppressContent: suppressContent)
        timeline.setPlayhead(time: playheadTime)
        scroll.documentView = timeline
        context.coordinator.timeline = timeline
        context.coordinator.observeBounds(of: scroll.contentView, timeline: timeline)

        // Sticky ruler. Floating subview pinned vertically to the top
        // of the viewport; AppKit scrolls it horizontally with the
        // document content so tick positions match clip frames. Hosts
        // the playhead-head pentagon too — keeping the head in the
        // ruler means it stays visible even when the user scrolls down
        // through long track lists.
        let rulerHost = StickyRulerView()
        rulerHost.pixelsPerSecond = pixelsPerSecond
        rulerHost.playheadTime = playheadTime
        rulerHost.onScrub = onScrub
        scroll.addFloatingSubview(rulerHost, for: .vertical)
        context.coordinator.rulerHost = rulerHost
        scroll.rulerHost = rulerHost

        sizeDocumentView(timeline, in: scroll, rulerHost: rulerHost)
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let timeline = scroll.documentView as? TimelineNSView else { return }
        context.coordinator.observeBounds(of: scroll.contentView, timeline: timeline)
        timeline.onSelect = onSelect
        timeline.onSelectEffectKeyframe = onSelectEffectKeyframe
        timeline.onApplyCommand = onApplyCommand
        timeline.onScrub = onScrub
        timeline.onRowHeightsChange = onRowHeightsChange
        timeline.update(project: project, bundleURL: bundleURL, pixelsPerSecond: pixelsPerSecond, trackHeight: trackHeight, scrollX: scrollX, selectedClipID: selectedClipID, selectedEffectKeyframeID: selectedEffectKeyframeID, revision: revision, rowHeightOverrides: rowHeightOverrides, suppressContent: suppressContent)
        timeline.setPlayhead(time: playheadTime)
        let rulerHost = context.coordinator.rulerHost
        rulerHost?.pixelsPerSecond = pixelsPerSecond
        rulerHost?.playheadTime = playheadTime
        rulerHost?.onScrub = onScrub
        sizeDocumentView(timeline, in: scroll, rulerHost: rulerHost)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        // Weak so we don't fight AppKit's view-lifetime ownership; the
        // NSScrollView retains the floating subview, the documentView
        // retains the timeline.
        weak var timeline: TimelineNSView?
        weak var rulerHost: StickyRulerView?
        private weak var observedClipView: NSClipView?
        private var boundsObserver: NSObjectProtocol?

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        @MainActor
        func observeBounds(of clipView: NSClipView, timeline: TimelineNSView) {
            self.timeline = timeline
            guard observedClipView !== clipView else { return }
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            observedClipView = clipView
            clipView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak timeline] _ in
                Task { @MainActor [weak timeline] in
                    timeline?.visibleRegionDidChange()
                }
            }
        }
    }

    /// Resize the documentView to the natural content size, with a floor
    /// of the visible viewport so the lanes always span the full width
    /// and don't leave a stripe of empty scroll-view background on the
    /// right when the project is short. Also sizes the floating ruler
    /// to match the document width so its ticks span the full content
    /// (AppKit clips to the viewport at draw time).
    private func sizeDocumentView(_ timeline: TimelineNSView, in scroll: NSScrollView, rulerHost: StickyRulerView?) {
        let natural = TimelineLayoutCalculator.contentSize(
            for: project,
            pixelsPerSecond: pixelsPerSecond,
            trackHeight: trackHeight,
            rowHeightOverrides: rowHeightOverrides
        )
        // Stamp the natural size on the view so TimelineScrollView.tile()
        // can re-apply the viewport floor on AppKit-only layout passes
        // (window resize / divider drag) that never reach updateNSView.
        timeline.naturalContentSize = natural
        let viewport = scroll.contentSize
        let target = NSSize(
            width: max(natural.width, viewport.width),
            height: max(natural.height, viewport.height)
        )
        // No-animation transaction: when the pane divider is dragged, the
        // viewport (and so this target) changes every tick. Without disabling
        // actions the document/ruler frame changes animate over ~0.25s and the
        // timeline visibly twitches/settles behind the drag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if timeline.frame.size != target {
            timeline.setFrameSize(target)
        }
        if let rulerHost {
            let rulerFrame = NSRect(
                x: 0, y: 0,
                width: target.width,
                height: TimelineLayoutCalculator.rulerHeight
            )
            if rulerHost.frame != rulerFrame {
                rulerHost.frame = rulerFrame
            }
        }
        CATransaction.commit()
    }
}

/// NSScrollView subclass that swallows the automatic scroller *flash*
/// while its own frame is actively changing — i.e. while the user drags
/// the preview/timeline divider.
///
/// AppKit auto-calls `flashScrollers()` whenever the content size changes
/// relative to the viewport, to hint scrollability. During a continuous
/// divider drag the viewport changes every tick, so the overlay scrollers
/// flash in and out repeatedly — the "scroll handles appear then
/// disappear" twitch. The scrollers are `.overlay` style (they float and
/// never reflow the lanes), so suppressing the flash during resize is
/// purely cosmetic: the timeline stays calm while dragging, and a real
/// scroll gesture still reveals the scroller normally (that path doesn't
/// go through `flashScrollers()`).
///
/// The suppression is scoped to resize only: `setFrameSize` raises the
/// flag synchronously (so the flash AppKit triggers inside the same tile
/// pass is swallowed) and clears it one runloop hop later, so flashes from
/// genuine content changes (zoom, adding tracks) while the pane is idle
/// still play.
private final class TimelineScrollView: NSScrollView {
    private var suppressScrollerFlash = false
    /// The floating ruler, so `tile()` can keep it sized to the document
    /// width on AppKit-only layout passes.
    weak var rulerHost: StickyRulerView?

    /// Re-apply the viewport floor to the document + ruler on every AppKit
    /// layout pass. `TimelineView.sizeDocumentView` does this on SwiftUI
    /// updates, but a pure window/divider resize never calls updateNSView —
    /// the viewport would outgrow the document, exposing uncovered canvas
    /// on the right and leaving stale row-card widths.
    override func tile() {
        super.tile()
        guard let timeline = documentView as? TimelineNSView,
              timeline.naturalContentSize != .zero else { return }
        let natural = timeline.naturalContentSize
        let target = NSSize(
            width: max(natural.width, contentSize.width),
            height: max(natural.height, contentSize.height)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if timeline.frame.size != target {
            timeline.setFrameSize(target)
        }
        if let rulerHost {
            let rulerFrame = NSRect(
                x: 0, y: 0,
                width: target.width,
                height: TimelineLayoutCalculator.rulerHeight
            )
            if rulerHost.frame != rulerFrame {
                rulerHost.frame = rulerFrame
            }
        }
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        if changed { suppressScrollerFlash = true }
        super.setFrameSize(newSize)
        if changed {
            // Clear after the current tile/layout pass settles. Coalesces
            // naturally across a drag: each tick re-raises the flag before
            // its own flash, and the final tick's reset lands after the
            // drag ends.
            DispatchQueue.main.async { [weak self] in
                self?.suppressScrollerFlash = false
            }
        }
    }

    override func flashScrollers() {
        guard !suppressScrollerFlash else { return }
        super.flashScrollers()
    }
}

/// NSClipView subclass that flips its coordinate system to match the
/// documentView. Without this, NSScrollView's clipView is non-flipped
/// and the documentView's flipped layout would render upside-down
/// relative to scroll position. AppKit's standard idiom for flipped
/// scrolling is `documentView.isFlipped == clipView.isFlipped`.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// CALayer-backed NSView. CAlayer hierarchy is rebuilt on every full
// `update(...)` for simplicity; during a drag we call a faster path
// that re-applies the drag preview without rebuilding from scratch.
// The playhead overlay has its own dedicated layer (`playheadLayer`)
// so per-frame playback updates only move that one layer rather than
// rebuild the whole tree.
public final class TimelineNSView: NSView {
    public var onSelect: ((ClipID?) -> Void)?
    public var onSelectEffectKeyframe: ((EffectKeyframeID?) -> Void)?
    public var onApplyCommand: ((any EditCommand) -> Void)?
    public var onScrub: ((RationalTime) -> Void)?
    public var onRowHeightsChange: (([String: CGFloat]) -> Void)?

    private var project: Project?
    private var bundleURL: URL?
    private var pixelsPerSecond: CGFloat = TimelineLayoutCalculator.defaultPixelsPerSecond
    private var trackHeight: CGFloat = TimelineLayoutCalculator.defaultTrackHeight
    private var scrollX: CGFloat = 0
    private var selectedClipID: ClipID?
    private var selectedEffectKeyframeID: EffectKeyframeID?
    private var playheadTime: RationalTime?
    /// Committed per-row height overrides (from the host, via update).
    private var rowHeightOverrides: [String: CGFloat] = [:]
    /// The in-flight row-resize drag's live value, merged over
    /// `rowHeightOverrides` for layout so the row tracks the cursor;
    /// folded into the committed map on mouseUp.
    private var liveRowHeights: [String: CGFloat] = [:]
    /// Host-driven content suppression (set while the header's track-height
    /// or zoom slider is mid-drag). See `suppressContentLayers`.
    private var contentSuppressedByHost = false
    /// True while an interactive resize is rebuilding the tree ~60×/s. Clip
    /// content (thumbnail tiles, waveform bitmaps) is skipped during these
    /// rebuilds: creating a Task per tile, decoding PNG→CGImage (~300KB
    /// bitmap) per tile, and allocating a fresh full-clip-width waveform
    /// backing store PER TICK is the "resizing rows spikes memory and
    /// freezes the machine" bug. Glass clip bodies render throughout; the
    /// settle rebuild on release restores content.
    private var suppressContentLayers: Bool {
        contentSuppressedByHost || dragSession?.kind == .resizeRow
    }
    /// Decoded thumbnail tiles keyed by (asset|time|size). The loader's L1
    /// caches PNG BYTES — decoding to CGImage on every rebuild still costs
    /// an allocation + decode per tile. Caching the decoded image lets
    /// rebuilds hand Core Animation the SAME CGImage object (no copy, no
    /// decode, no Task). LRU-capped.
    private var tileImages: [String: CGImage] = [:]
    private var tileImageLRU: [String] = []
    private let tileImageCapacity = 256
    /// Last-applied non-playhead inputs. Compared against incoming `update(...)`
    /// calls to short-circuit no-op rebuilds. nil = first call (always rebuild).
    private var lastInputs: InputSnapshot?
    private let waveformLoader = WaveformLoader()
    private let thumbnailLoader = ThumbnailLoader()

    private struct InputSnapshot: Equatable {
        let bundleURL: URL?
        let pixelsPerSecond: CGFloat
        let trackHeight: CGFloat
        let scrollX: CGFloat
        let selectedClipID: ClipID?
        let selectedEffectKeyframeID: EffectKeyframeID?
        let revision: Int
        let rowHeightOverrides: [String: CGFloat]
        let suppressContent: Bool
    }

    /// Effective per-row heights for layout: committed overrides with any
    /// in-flight drag value on top.
    private var effectiveRowHeights: [String: CGFloat] {
        rowHeightOverrides.merging(liveRowHeights) { _, live in live }
    }

    /// Cached layout — recomputed each `rebuildLayers(...)` call from the
    /// inputs above plus the active drag preview.
    private var lastLayout: TimelineLayout?
    /// Dedicated overlay layer for the playhead vertical line. Updated in
    /// `setPlayhead(time:)` without rebuilding the rest of the tree, so
    /// the ~30fps PreviewPlayer time observer doesn't churn the entire
    /// CALayer hierarchy. The companion "head" pentagon lives on the
    /// floating `StickyRulerView` instead so it stays visible when the
    /// user scrolls past the ruler.
    private var playheadLineLayer: CALayer?
    private var lastThumbnailVisibleBucket: Int?

    /// In-progress drag state. nil = not dragging; non-nil = dragging.
    /// On mouseUp: the deltaPixels is converted to a RationalTime and an
    /// EditCommand is dispatched via `onApplyCommand`. Scrub drags are
    /// also tracked here (Kind.scrub) but their mouseUp doesn't post a
    /// command — scrubbing emits onScrub on each tick.
    private struct DragSession {
        enum Kind {
            case move
            case trimIn
            case trimOut
            case scrub
            case moveEffect
            case trimEffectIn
            case trimEffectOut
            case resizeRow
        }
        var kind: Kind
        var clipID: ClipID?              // set for clip kinds; nil otherwise
        var effectKeyframeID: EffectKeyframeID?  // set for effect kinds
        var rowID: String? = nil         // set for resizeRow
        var startRowHeight: CGFloat = 0  // row height at drag start (resizeRow)
        var startPoint: CGPoint
        var currentDeltaPixels: CGFloat
        var currentDeltaYPixels: CGFloat = 0
    }
    private var dragSession: DragSession?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    /// Natural (un-floored) content size from the last SwiftUI update —
    /// stamped by `TimelineView.sizeDocumentView` so the enclosing
    /// `TimelineScrollView.tile()` can re-apply the viewport floor during
    /// AppKit-only layout passes.
    var naturalContentSize: CGSize = .zero

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.NSColor.bgDeep.cgColor
        layer?.masksToBounds = true
        // Snap, never animate, on bounds/position changes — so resizing the
        // pane divider doesn't let the backing layer ease into its new size
        // (a source of the resize twitch).
        layer?.actions = ["bounds": NSNull(), "position": NSNull()]
    }

    /// Row cards, lane widths, and the effects hint are computed from
    /// `bounds` at rebuild time. A frame change outside a SwiftUI update
    /// (window resize, divider drag) would leave them stale — cards ending
    /// mid-timeline over uncovered canvas — so rebuild here. Mid-drag this
    /// fires per tick, same cost as the existing clip-drag rebuild path.
    /// EXCEPT during a row-resize drag: mouseDragged already rebuilt for
    /// this tick and then grows the frame — rebuilding again here would
    /// double every tick's layer churn for no visual difference (lane
    /// geometry doesn't depend on the document's height).
    public override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed, project != nil, dragSession?.kind != .resizeRow {
            rebuildLayers()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func update(project: Project, bundleURL: URL?, pixelsPerSecond: CGFloat, trackHeight: CGFloat, scrollX: CGFloat, selectedClipID: ClipID?, selectedEffectKeyframeID: EffectKeyframeID?, revision: Int, rowHeightOverrides: [String: CGFloat] = [:], suppressContent: Bool = false) {
        self.contentSuppressedByHost = suppressContent
        let snapshot = InputSnapshot(
            bundleURL: bundleURL,
            pixelsPerSecond: pixelsPerSecond,
            trackHeight: trackHeight,
            scrollX: scrollX,
            selectedClipID: selectedClipID,
            selectedEffectKeyframeID: selectedEffectKeyframeID,
            revision: revision,
            rowHeightOverrides: rowHeightOverrides,
            suppressContent: suppressContent
        )
        // Skip the full layer rebuild when nothing the layout depends on
        // has changed. The playhead path (`setPlayhead(time:)`) runs
        // independently — its caller invokes it after `update`. The
        // PreviewPlayer's ~30fps time observer fires `updateNSView`
        // continuously during playback; without this gate we'd rebuild
        // every CALayer ~30 times per second.
        if lastInputs == snapshot && self.project != nil {
            self.project = project
            return
        }
        self.project = project
        self.bundleURL = bundleURL
        self.pixelsPerSecond = pixelsPerSecond
        self.trackHeight = trackHeight
        self.scrollX = scrollX
        self.selectedClipID = selectedClipID
        self.selectedEffectKeyframeID = selectedEffectKeyframeID
        self.rowHeightOverrides = rowHeightOverrides
        self.lastInputs = snapshot
        self.lastThumbnailVisibleBucket = nil
        needsLayout = true
        rebuildLayers()
    }

    func visibleRegionDidChange() {
        let bucketWidth: CGFloat = 400
        let bucket = Int((visibleRect.minX / bucketWidth).rounded(.down))
        guard bucket != lastThumbnailVisibleBucket else { return }
        lastThumbnailVisibleBucket = bucket
        rebuildLayers()
    }

    private func rebuildLayers() {
        guard let project, let layer else { return }
        let viewport = TimelineViewport(
            size: bounds.size == .zero ? CGSize(width: 800, height: 240) : bounds.size,
            pixelsPerSecond: pixelsPerSecond,
            scrollX: scrollX,
            trackHeight: trackHeight,
            rowHeightOverrides: effectiveRowHeights
        )
        let preview = currentDragPreview()
        let layout = TimelineLayoutCalculator.layout(project: project, viewport: viewport, dragPreview: preview)
        lastLayout = layout

        // Mid-drag rebuilds happen on every mouseDragged (often dozens of
        // times per second). Wrap the layer mutation in a CATransaction
        // with no implicit animation so the preview doesn't smear.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        layer.sublayers?.removeAll()
        // The playhead line lives in our sublayer tree; the removeAll
        // above dropped it. Drop the reference too so setPlayhead lazy-
        // adds a fresh layer the next time it runs. The ruler strip +
        // playhead head live on the floating `StickyRulerView` and are
        // not affected.
        playheadLineLayer = nil

        // The first `rulerHeight + verticalInset` of document-y is left
        // empty on purpose — when the user is scrolled to top, the
        // floating ruler covers it exactly; when scrolled further down,
        // it's the standard sticky-header trade-off (top of lane 1 sits
        // briefly under the floating ruler as it scrolls past).

        // Branch B (2026-05-27): render iterates `displayRows`. For a
        // grouped row, draw the primary track's band only. For a
        // singleTrack row, draw the physical track's clips as before.
        // PiP/audio badges (`layout.groupedOverlapBadges`) are painted
        // in a separate pass below so the badge always lands on top of
        // the primary clip.
        let tracksByID = Dictionary(
            layout.tracks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for row in layout.displayRows {
            switch row.kind {
            case .effectsLane:
                continue   // drawn in the dedicated effects pass below
            case .singleTrack(let trackID, _):
                guard let track = tracksByID[trackID] else { continue }
                drawSingleTrackRow(track, in: layer)
            case .groupedVideo(_, let primaryTrackID),
                 .groupedAudio(_, let primaryTrackID):
                drawGroupedRow(
                    primaryTrackID: primaryTrackID,
                    isVideoGroup: row.kind.isVideoGroup,
                    tracksByID: tracksByID,
                    in: layer
                )
            }
        }

        // Badges last so they sit on top of clip layers regardless of
        // draw order above.
        for badge in layout.groupedOverlapBadges {
            addOverlapBadge(
                on: badge.anchorFrame,
                isVideo: badge.kind == .video,
                in: layer
            )
        }

        // Disclosure chevrons for each grouped lane (Slice B.4).
        for disclosure in layout.laneDisclosures {
            addDisclosureChevron(disclosure, in: layer)
        }

        let effectsLane = layout.effectsLane
        drawRowCard(headerFrame: effectsLane.headerFrame, laneFrame: effectsLane.laneFrame, in: layer)
        // Effects header through the shared lane-header path so it matches the
        // icon+name treatment of the track lanes above it.
        drawLaneHeader(
            frame: effectsLane.headerFrame,
            title: "Effects",
            symbolName: "plus.magnifyingglass",
            tint: Theme.NSColor.trackEffects,
            emphasized: false,
            muted: false,
            in: layer
        )

        // Empty state reads as intentional, not broken — and teaches the
        // gesture that fills it. Drawn inside rebuildLayers so the
        // revision-gate still suppresses per-frame rebuilds.
        if effectsLane.keyframes.isEmpty {
            let hint = CATextLayer()
            hint.string = "No effects yet — ⌥ click to add a zoom"
            hint.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            hint.fontSize = 11
            hint.alignmentMode = .center
            hint.contentsScale = window?.backingScaleFactor ?? 2
            hint.foregroundColor = Theme.NSColor.textTertiary.cgColor
            hint.backgroundColor = NSColor.clear.cgColor
            let hintHeight: CGFloat = 14
            hint.frame = CGRect(
                x: effectsLane.laneFrame.minX,
                y: effectsLane.laneFrame.midY - hintHeight / 2,
                width: effectsLane.laneFrame.width,
                height: hintHeight
            )
            layer.addSublayer(hint)
        }

        for keyframe in effectsLane.keyframes {
            let isSelected = keyframe.id == selectedEffectKeyframeID
            let role = baseColorForEffectKeyframe(keyframe)
            // Glossy vertical gradient (a lighter top edge → the full role
            // colour) at near-full opacity, plus an always-on soft glow that
            // intensifies on selection. Small badges, so they can afford to
            // be the boldest, most saturated element on the timeline.
            let topColor = role.blended(withFraction: 0.30, of: .white) ?? role
            let kfLayer = CAGradientLayer()
            kfLayer.frame = keyframe.frame
            kfLayer.cornerRadius = 6
            kfLayer.startPoint = CGPoint(x: 0.5, y: 0)
            kfLayer.endPoint = CGPoint(x: 0.5, y: 1)
            kfLayer.colors = [
                topColor.withAlphaComponent(isSelected ? 1.0 : 0.98).cgColor,
                role.withAlphaComponent(isSelected ? 1.0 : 0.90).cgColor
            ]
            kfLayer.borderWidth = isSelected ? 2 : 1
            kfLayer.borderColor = isSelected
                ? Theme.NSColor.textPrimary.withAlphaComponent(0.95).cgColor
                : topColor.withAlphaComponent(0.95).cgColor
            kfLayer.shadowColor = role.cgColor
            kfLayer.shadowOpacity = isSelected ? 0.75 : 0.4
            kfLayer.shadowRadius = isSelected ? 9 : 5
            kfLayer.shadowOffset = .zero
            kfLayer.shadowPath = CGPath(
                roundedRect: CGRect(origin: .zero, size: keyframe.frame.size),
                cornerWidth: 6,
                cornerHeight: 6,
                transform: nil
            )
            layer.addSublayer(kfLayer)

            // Small ⌘ glyph in the top-left for manual-hotkey keyframes so
            // the user can tell at a glance which were AI-guessed vs
            // intentionally stamped. Skip when the keyframe is too narrow.
            if keyframe.origin == .manualHotkey, keyframe.frame.width >= 24 {
                let glyph = CATextLayer()
                glyph.string = "⌘"
                glyph.fontSize = 11
                glyph.foregroundColor = Theme.NSColor.textPrimary.cgColor
                glyph.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
                glyph.alignmentMode = .left
                glyph.frame = CGRect(
                    x: keyframe.frame.minX + 4,
                    y: keyframe.frame.minY + 2,
                    width: 14,
                    height: 14
                )
                layer.addSublayer(glyph)
            }
        }

        // Re-establish the playhead overlay on top of the newly-rebuilt
        // clip tree. setPlayhead is a fast no-op if `playheadTime` is nil.
        setPlayhead(time: playheadTime)
    }

    private func currentDragPreview() -> TimelineDragPreview {
        guard let session = dragSession else { return .none }
        switch session.kind {
        case .move:
            guard let clipID = session.clipID else { return .none }
            return .moveClip(clipID, deltaPixels: session.currentDeltaPixels)
        case .trimIn:
            guard let clipID = session.clipID else { return .none }
            return .trimIn(clipID, deltaPixels: session.currentDeltaPixels)
        case .trimOut:
            guard let clipID = session.clipID else { return .none }
            return .trimOut(clipID, deltaPixels: session.currentDeltaPixels)
        case .scrub: return .none
        case .moveEffect:
            guard let id = session.effectKeyframeID else { return .none }
            return .moveEffectKeyframe(id, deltaPixels: session.currentDeltaPixels)
        case .trimEffectIn:
            guard let id = session.effectKeyframeID else { return .none }
            return .trimEffectKeyframeIn(id, deltaPixels: session.currentDeltaPixels)
        case .trimEffectOut:
            guard let id = session.effectKeyframeID else { return .none }
            return .trimEffectKeyframeOut(id, deltaPixels: session.currentDeltaPixels)
        case .resizeRow:
            // Row resize previews through liveRowHeights, not a clip-frame
            // delta — the layout picks it up via effectiveRowHeights.
            return .none
        }
    }

    /// Draws one physical-track row: row card + header + clips + optional
    /// waveform overlay. Used for `singleTrack` display rows (expanded
    /// grouped child OR a track outside any group).
    private func drawSingleTrackRow(_ track: TrackLayout, in layer: CALayer) {
        let muted = project?.tracks.first(where: { $0.id == track.id })?.muted ?? false
        drawRowCard(headerFrame: track.headerFrame, laneFrame: track.laneFrame, in: layer)
        drawLaneHeader(
            frame: track.headerFrame,
            title: track.name,
            symbolName: laneSymbol(for: track.kind),
            tint: baseColor(for: track.kind),
            emphasized: false,
            muted: muted,
            in: layer
        )
        for clip in track.clips {
            addClipLayer(clip, kind: track.kind, in: layer)
        }
    }

    /// Draws a grouped (collapsed) row: the primary physical track's
    /// clips become the lane's band. The secondary-track-overlap badges
    /// are painted in a separate pass from the precomputed
    /// `layout.groupedOverlapBadges` so they sit on top of the clip
    /// layers and the layout-vs-renderer split stays clean.
    private func drawGroupedRow(
        primaryTrackID: TrackID,
        isVideoGroup: Bool,
        tracksByID: [TrackID: TrackLayout],
        in layer: CALayer
    ) {
        guard let primary = tracksByID[primaryTrackID] else { return }

        drawRowCard(headerFrame: primary.headerFrame, laneFrame: primary.laneFrame, in: layer)
        // Header label uses the group's friendly name. No mute indicator on
        // grouped rows — the band aggregates multiple physical tracks whose
        // mute states can differ; mute lives on the expanded child rows.
        drawLaneHeader(
            frame: primary.headerFrame,
            title: isVideoGroup ? "Video" : "Audio",
            symbolName: isVideoGroup ? "video.fill" : "speaker.wave.2.fill",
            tint: baseColor(for: primary.kind),
            emphasized: true,
            muted: false,
            in: layer
        )

        // Primary track clips form the visible band.
        for clip in primary.clips {
            addClipLayer(clip, kind: primary.kind, in: layer)
        }
    }

    /// One soft rounded "row card" spanning a display row's header + lane,
    /// with a hairline seam where the header column meets the lane. Replaces
    /// the old opaque header box + flat lane wash so each row reads as a
    /// single continuous surface floating on the deep canvas — the lane's
    /// identity comes from its tinted icon and clips, not from chrome.
    private func drawRowCard(headerFrame: CGRect, laneFrame: CGRect, in layer: CALayer) {
        let cardInset: CGFloat = 6
        let card = CALayer()
        card.frame = CGRect(
            x: headerFrame.minX + cardInset,
            y: headerFrame.minY,
            width: max(0, laneFrame.maxX - headerFrame.minX - cardInset * 2),
            height: headerFrame.height
        )
        card.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor
        card.cornerRadius = 7
        layer.addSublayer(card)

        let seam = CALayer()
        seam.frame = CGRect(
            x: laneFrame.minX,
            y: headerFrame.minY + 6,
            width: Theme.Stroke.hairline,
            height: max(0, headerFrame.height - 12)
        )
        seam.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        layer.addSublayer(seam)
    }

    /// Shared clip rendering: a soft role-tinted "glass" body with a quiet
    /// same-hue rim. Selection is a crisp near-white border plus a gentle
    /// role-coloured glow — unmistakable over any fill or thumbnail, unlike
    /// the old blue-border-on-blue-block treatment.
    private func addClipLayer(_ clip: ClipLayout, kind: TrackKind, in layer: CALayer) {
        let isSelected = clip.id == selectedClipID
        let role = baseColor(for: kind)
        let clipLayer = CALayer()
        clipLayer.frame = clip.frame
        clipLayer.cornerRadius = 7
        clipLayer.borderWidth = isSelected ? 2 : 1
        clipLayer.borderColor = isSelected
            ? Theme.NSColor.textPrimary.withAlphaComponent(0.92).cgColor
            : role.withAlphaComponent(0.38).cgColor
        clipLayer.backgroundColor = role.withAlphaComponent(clipFillAlpha(kind: kind, selected: isSelected)).cgColor
        if isSelected {
            clipLayer.shadowColor = role.cgColor
            clipLayer.shadowOpacity = 0.5
            clipLayer.shadowRadius = 8
            clipLayer.shadowOffset = .zero
            clipLayer.shadowPath = CGPath(
                roundedRect: CGRect(origin: .zero, size: clip.frame.size),
                cornerWidth: 7,
                cornerHeight: 7,
                transform: nil
            )
        }
        layer.addSublayer(clipLayer)
        if isAudioKind(kind) {
            addWaveformLayer(forClip: clip, clipFrame: clip.frame, kind: kind)
        } else if isVideoKind(kind) {
            addThumbnailStrip(forClip: clip, clipFrame: clip.frame, kind: kind)
        }
    }

    /// Fill strength for the glass clip body. Audio stays quieter (the
    /// tinted waveform is the hero); video carries a touch more colour as
    /// the backdrop behind its thumbnail strip.
    private func clipFillAlpha(kind: TrackKind, selected: Bool) -> CGFloat {
        if isAudioKind(kind) {
            return selected ? 0.34 : 0.20
        }
        return selected ? 0.38 : 0.26
    }

    /// Renders the disclosure chevron for one grouped lane. SF Symbol
    /// "chevron.right" when collapsed (points to the band), "chevron.down"
    /// when expanded (points at the first child row). Drawn as a plain
    /// CALayer with `NSImage` contents — same pattern as the PiP badge.
    private func addDisclosureChevron(_ disclosure: LaneDisclosure, in layer: CALayer) {
        let symbolName = disclosure.isCollapsed ? "chevron.right" : "chevron.down"
        guard let symbol = tintedSymbol(symbolName, color: Theme.NSColor.textTertiary) else { return }
        let chevron = CALayer()
        chevron.frame = disclosure.hitFrame
        chevron.contents = symbol
        chevron.contentsGravity = .resizeAspect
        chevron.contentsScale = window?.backingScaleFactor ?? 2
        layer.addSublayer(chevron)
    }

    /// Adds a small icon-on-circle overlay anchored to the top-right of
    /// `clipFrame`. Used to signal "there's a non-primary track clip
    /// underlying this part of the grouped lane" — a video group shows
    /// a camera glyph, an audio group shows a speaker glyph. Both are
    /// SF Symbols rendered into a CALayer via NSImage.
    private func addOverlapBadge(on clipFrame: CGRect, isVideo: Bool, in layer: CALayer) {
        // Skip if the clip is too narrow to host the badge cleanly.
        guard clipFrame.width >= 18 else { return }
        let badgeSize: CGFloat = 14
        let inset: CGFloat = 3
        let badgeFrame = CGRect(
            x: clipFrame.maxX - badgeSize - inset,
            y: clipFrame.minY + inset,
            width: badgeSize,
            height: badgeSize
        )
        // Tinted circle background so the glyph reads against any
        // clip color.
        let bg = CALayer()
        bg.frame = badgeFrame
        bg.cornerRadius = badgeSize / 2
        bg.backgroundColor = Theme.NSColor.bgDeep.withAlphaComponent(0.85).cgColor
        layer.addSublayer(bg)
        let symbolName = isVideo ? "videocam.fill" : "speaker.wave.2.fill"
        if let symbol = tintedSymbol(symbolName, color: Theme.NSColor.textSecondary) {
            let glyph = CALayer()
            glyph.frame = badgeFrame.insetBy(dx: 2, dy: 2)
            glyph.contents = symbol
            glyph.contentsGravity = .resizeAspect
            glyph.contentsScale = window?.backingScaleFactor ?? 2
            layer.addSublayer(glyph)
        }
    }

    /// Draws a lane header cell: a per-kind glyph tinted to the lane's ROLE
    /// colour at the left (this — not a filled box — is what identifies the
    /// lane), the (vertically centred, truncating) track name, and — when
    /// `muted` — a danger-tinted speaker.slash on the right. The mute glyph
    /// is a status indicator only; toggling mute lives in the Audio
    /// inspector tab (no CALayer hit-testing here). The header background is
    /// transparent: the shared row card behind it provides the surface.
    private func drawLaneHeader(
        frame: CGRect,
        title: String,
        symbolName: String,
        tint: NSColor,
        emphasized: Bool,
        muted: Bool,
        in layer: CALayer
    ) {
        let scale = window?.backingScaleFactor ?? 2

        let textColor: NSColor = muted
            ? Theme.NSColor.textTertiary
            : (emphasized ? Theme.NSColor.textPrimary : Theme.NSColor.textSecondary)
        let iconColor: NSColor = muted ? Theme.NSColor.textTertiary : tint

        let leftPad: CGFloat = 14
        let gap: CGFloat = 6
        let iconSize: CGFloat = 13
        var textMinX = frame.minX + leftPad
        var textMaxX = frame.maxX - leftPad

        if let icon = tintedSymbol(symbolName, color: iconColor) {
            let iconLayer = CALayer()
            iconLayer.frame = CGRect(
                x: frame.minX + leftPad,
                y: frame.midY - iconSize / 2,
                width: iconSize,
                height: iconSize
            )
            iconLayer.contents = icon
            iconLayer.contentsGravity = .resizeAspect
            iconLayer.contentsScale = scale
            layer.addSublayer(iconLayer)
            textMinX += iconSize + gap
        }

        if muted, let mutedIcon = tintedSymbol("speaker.slash.fill", color: Theme.NSColor.danger) {
            let mutedSize: CGFloat = 12
            let mutedLayer = CALayer()
            mutedLayer.frame = CGRect(
                x: frame.maxX - leftPad - mutedSize,
                y: frame.midY - mutedSize / 2,
                width: mutedSize,
                height: mutedSize
            )
            mutedLayer.contents = mutedIcon
            mutedLayer.contentsGravity = .resizeAspect
            mutedLayer.contentsScale = scale
            layer.addSublayer(mutedLayer)
            textMaxX -= mutedSize + gap
        }

        let text = CATextLayer()
        let textHeight: CGFloat = 14
        text.frame = CGRect(
            x: textMinX,
            y: frame.midY - textHeight / 2,
            width: max(0, textMaxX - textMinX),
            height: textHeight
        )
        text.string = title
        text.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        text.fontSize = 11
        text.alignmentMode = .left
        text.truncationMode = .end
        text.isWrapped = false
        text.contentsScale = scale
        text.foregroundColor = textColor.cgColor
        text.backgroundColor = NSColor.clear.cgColor
        layer.addSublayer(text)
    }

    /// SF Symbol per track kind for the lane headers. Mirrors the app's
    /// `TrackKind.inspectorSymbol` (the TimelineUI package can't see app
    /// code) so iconography stays consistent across the editor.
    private func laneSymbol(for kind: TrackKind) -> String {
        switch kind {
        case .screen:        return "display"
        case .webcam:        return "video.fill"
        case .microphone:    return "mic.fill"
        case .systemAudio:   return "speaker.wave.2.fill"
        case .voiceover:     return "waveform"
        case .overlay:       return "rectangle.on.rectangle"
        case .effects:       return "plus.magnifyingglass"
        }
    }

    /// Renders an SF Symbol tinted to `color` as an NSImage suitable for a
    /// CALayer's `contents`. Template symbols set directly as layer contents
    /// render in their intrinsic (black) colour, which disappears on the
    /// dark header — the palette configuration bakes the tint in.
    private func tintedSymbol(_ name: String, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        return base.withSymbolConfiguration(config)
    }

    /// The lane's role colour — the single hue that identifies a track kind
    /// across its header icon, clip tint, rim, waveform, and selection glow.
    private func baseColor(for kind: TrackKind) -> NSColor {
        switch kind {
        case .screen:        return Theme.NSColor.trackVideo
        case .webcam:        return Theme.NSColor.trackWebcam
        case .microphone:    return Theme.NSColor.trackMic
        case .systemAudio:   return Theme.NSColor.trackSystemAudio
        case .voiceover:     return Theme.NSColor.trackVoiceover
        case .overlay:       return Theme.NSColor.trackOverlay
        case .effects:       return Theme.NSColor.trackEffects
        }
    }

    private func baseColorForEffectKeyframe(_ keyframe: EffectKeyframeLayout) -> NSColor {
        switch (keyframe.kind, keyframe.origin) {
        case (.zoom, .auto):            return Theme.NSColor.effectZoomAuto
        case (.zoom, .manualHotkey):    return Theme.NSColor.effectZoomManual
        case (.talkingHeadSwap, _):     return Theme.NSColor.effectTalkingHead
        }
    }

    private func isAudioKind(_ kind: TrackKind) -> Bool {
        switch kind {
        case .microphone, .systemAudio, .voiceover: return true
        case .screen, .webcam, .overlay, .effects: return false
        }
    }

    /// Video kinds that get a thumbnail strip (mirrors `isAudioKind` for the
    /// waveform path). `.effects` is a keyframe lane, not a video source.
    private func isVideoKind(_ kind: TrackKind) -> Bool {
        switch kind {
        case .screen, .webcam, .overlay: return true
        case .microphone, .systemAudio, .voiceover, .effects: return false
        }
    }

    /// Adds a `ThumbnailLayer` over a video clip and fills it with frames
    /// sampled across the clip's source range. Density is adaptive: one tile
    /// per `max(80, clipHeight * 16/9)` px of clip width (recomputed on every
    /// layout rebuild, so zoom changes re-tile). Short clips get one centred
    /// tile. Each tile loads async via `ThumbnailLoader` and is dropped in as
    /// it resolves; the disk + memory caches make re-tiling on zoom cheap.
    private func addThumbnailStrip(forClip clip: ClipLayout, clipFrame: CGRect, kind: TrackKind) {
        guard !suppressContentLayers else { return }
        guard let project, let bundleURL else { return }
        guard let modelClip = project.tracks.flatMap(\.clips).first(where: { $0.id == clip.id }) else { return }
        guard let asset = project.assets.first(where: { $0.id == modelClip.assetID }) else { return }
        guard let assetURL = try? ProjectBundle(url: bundleURL).mediaURL(for: asset) else { return }

        let inset: CGFloat = 4
        let stripFrame = CGRect(
            x: clipFrame.minX + inset,
            y: clipFrame.minY + inset,
            width: max(0, clipFrame.width - inset * 2),
            height: max(0, clipFrame.height - inset * 2)
        )
        guard stripFrame.width > 0, stripFrame.height > 0 else { return }

        let visibleFrame = visibleThumbnailFrame(for: stripFrame)
        guard visibleFrame.width > 1, visibleFrame.height > 1 else { return }

        let strip = ThumbnailLayer()
        strip.frame = visibleFrame
        strip.contentsScale = window?.backingScaleFactor ?? 2
        // Round the strip so tiles don't poke square corners into the
        // clip's rounded glass body.
        strip.cornerRadius = 5
        strip.masksToBounds = true
        layer?.addSublayer(strip)

        // GENERATION size is quantized to coarse buckets — the loader caches
        // by exact integer (width, height), so requesting tiles at the row's
        // live pixel height would cache-miss on EVERY tick of a height drag
        // and fire a fresh AVAssetImageGenerator decode per tile per pixel:
        // the "resizing rows spikes memory / freezes" bug. Rounding the
        // height up to 16px steps (and deriving tile count from the rounded
        // height, so sample times stay stable too) means a full drag crosses
        // ~5 cache buckets total. Tiles render via .resizeAspectFill into
        // their exact frames, so drawing a slightly-larger cached tile is
        // visually lossless.
        let genHeight = max(32, ceil(visibleFrame.height / 16) * 16)
        // Adaptive tile width: one frame per ~16:9 slot, min 80pt.
        let tileWidth = max(80, genHeight * (16.0 / 9.0))
        let tileCount = max(1, Int((visibleFrame.width / tileWidth).rounded(.down)))
        let actualTileWidth = visibleFrame.width / CGFloat(tileCount)

        let sourceStart = seconds(modelClip.sourceRange.start)
        let sourceDuration = seconds(modelClip.sourceRange.duration)
        let loader = thumbnailLoader
        let targetSize = CGSize(width: ceil(actualTileWidth / 32) * 32, height: genHeight)

        for i in 0..<tileCount {
            // Sample at the centre of each tile's time span.
            let tileMidXInClip = visibleFrame.minX - stripFrame.minX
                + (CGFloat(i) + 0.5) * actualTileWidth
            let fraction = max(0, min(1, Double(tileMidXInClip / stripFrame.width)))
            let atSeconds = sourceStart + fraction * sourceDuration
            // Tile frame is in the strip's own coordinate space (origin 0,0).
            let tileFrame = CGRect(
                x: CGFloat(i) * actualTileWidth,
                y: 0,
                width: actualTileWidth,
                height: visibleFrame.height
            )
            // Same millisecond rounding the loader keys on, so the decoded-
            // image cache and the loader's PNG cache stay aligned.
            let keySeconds = (atSeconds * 1000).rounded() / 1000
            let tileKey = "\(assetURL.path)|\(keySeconds)|\(Int(targetSize.width))x\(Int(targetSize.height))"
            if let cached = tileImages[tileKey] {
                // Synchronous fast path: rebuilds re-use the SAME CGImage
                // object — no Task, no PNG decode, no bitmap allocation.
                strip.addTile(cgImage: cached, frame: tileFrame)
                touchTileImage(tileKey)
                continue
            }
            Task { @MainActor [weak strip, weak self] in
                do {
                    let data = try await loader.thumbnail(
                        forAssetAt: assetURL,
                        atSeconds: atSeconds,
                        targetSize: targetSize
                    )
                    guard let cgImage = Self.cgImage(fromPNG: data) else { return }
                    self?.storeTileImage(cgImage, forKey: tileKey)
                    strip?.addTile(cgImage: cgImage, frame: tileFrame)
                } catch {
                    // Best-effort: leave the clip's tinted body showing. Logged
                    // once per failing asset; recording still plays back fine.
                    log.error("thumbnail load failed url=\(assetURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    // MARK: - Decoded-tile LRU

    private func storeTileImage(_ image: CGImage, forKey key: String) {
        tileImages[key] = image
        touchTileImage(key)
        while tileImageLRU.count > tileImageCapacity, let evict = tileImageLRU.first {
            tileImageLRU.removeFirst()
            tileImages[evict] = nil
        }
    }

    private func touchTileImage(_ key: String) {
        if let idx = tileImageLRU.firstIndex(of: key) { tileImageLRU.remove(at: idx) }
        tileImageLRU.append(key)
    }

    private func visibleThumbnailFrame(for stripFrame: CGRect) -> CGRect {
        let viewport = visibleRect
        let margin = max(240, viewport.width * 0.75)
        let interest = viewport.insetBy(dx: -margin, dy: 0)
        return stripFrame.intersection(interest)
    }

    private static func cgImage(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Adds a WaveformLayer above the clip's body and kicks off an async
    /// load via WaveformLoader. Resolves the asset URL by joining
    /// `bundleURL` with the MediaAsset's `relativePath`. Missing asset
    /// or no bundleURL → silently skips the waveform (the clip's tinted
    /// background still shows; the user just doesn't get the audio
    /// preview yet).
    private func addWaveformLayer(forClip clip: ClipLayout, clipFrame: CGRect, kind: TrackKind) {
        guard !suppressContentLayers else { return }
        guard let project, let bundleURL else { return }
        guard let modelClip = project.tracks.flatMap(\.clips).first(where: { $0.id == clip.id }) else { return }
        guard let asset = project.assets.first(where: { $0.id == modelClip.assetID }) else { return }
        guard let assetURL = try? ProjectBundle(url: bundleURL).mediaURL(for: asset) else { return }
        let waveform = WaveformLayer()
        // Inset the waveform inside the clip frame so the rounded clip
        // border still shows around the edges.
        let inset: CGFloat = 4
        waveform.frame = CGRect(
            x: clipFrame.minX + inset,
            y: clipFrame.minY + inset,
            width: max(0, clipFrame.width - inset * 2),
            height: max(0, clipFrame.height - inset * 2)
        )
        // Light tint of the lane's role colour, not stark white — the wave
        // stays the hero on the quiet glass body while the whole row reads
        // as one hue family (mic = violet, system audio = indigo, …).
        let waveTint = baseColor(for: kind)
            .blended(withFraction: 0.65, of: .white) ?? Theme.NSColor.waveformFill
        waveform.fillColor = waveTint.withAlphaComponent(0.92).cgColor
        waveform.contentsScale = window?.backingScaleFactor ?? 2
        layer?.addSublayer(waveform)

        let buckets = max(8, Int(waveform.frame.width))  // ~1 bucket per pixel
        let startSeconds = seconds(modelClip.sourceRange.start)
        let durationSeconds = seconds(modelClip.sourceRange.duration)
        let loader = waveformLoader
        // Stay on the main actor: `loader.peaks(...)` is an actor func so
        // its body still hops to the loader's actor for I/O. Keeping the
        // surrounding Task @MainActor lets us safely capture the
        // (non-Sendable) WaveformLayer reference. Strong ref is fine —
        // the load takes ~1s and the layer is dropped on next rebuild.
        Task { @MainActor [weak waveform] in
            do {
                let peaks = try await loader.peaks(
                    forAssetAt: assetURL,
                    startSeconds: startSeconds,
                    durationSeconds: durationSeconds,
                    buckets: buckets
                )
                waveform?.peaks = peaks
            } catch {
                // Best-effort: log and leave the waveform empty. Recording
                // still plays back fine via the existing PreviewPlayer.
                log.error("waveform load failed url=\(assetURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Cursor

    public override func resetCursorRects() {
        super.resetCursorRects()
        guard let lastLayout else { return }
        for track in lastLayout.tracks {
            for clip in track.clips {
                addBodyAndEdgeCursors(frame: clip.frame)
            }
        }
        for kf in lastLayout.effectsLane.keyframes {
            addBodyAndEdgeCursors(frame: kf.frame)
        }
        // Per-row height-resize zones along each header's bottom edge.
        for handle in lastLayout.rowResizeHandles {
            addCursorRect(handle.hitFrame, cursor: .resizeUpDown)
        }
    }

    private func addBodyAndEdgeCursors(frame: CGRect) {
        guard frame.width >= TimelineHitTest.edgeZoneWidth * 3 else {
            addCursorRect(frame, cursor: .openHand)
            return
        }
        let leftEdge = CGRect(
            x: frame.minX,
            y: frame.minY,
            width: TimelineHitTest.edgeZoneWidth,
            height: frame.height
        )
        let rightEdge = CGRect(
            x: frame.maxX - TimelineHitTest.edgeZoneWidth,
            y: frame.minY,
            width: TimelineHitTest.edgeZoneWidth,
            height: frame.height
        )
        let body = CGRect(
            x: leftEdge.maxX,
            y: frame.minY,
            width: rightEdge.minX - leftEdge.maxX,
            height: frame.height
        )
        addCursorRect(leftEdge, cursor: .resizeLeftRight)
        addCursorRect(rightEdge, cursor: .resizeLeftRight)
        addCursorRect(body, cursor: .openHand)
    }

    // MARK: - Playhead

    /// Updates the playhead line's x position. Called from the SwiftUI
    /// host on every PreviewPlayer time-observer tick (~30fps); does not
    /// rebuild any clip layers. The companion "head" pentagon lives on
    /// the floating `StickyRulerView` and is updated separately by the
    /// host via `rulerHost.playheadTime = ...`.
    public func setPlayhead(time: RationalTime?) {
        playheadTime = time
        guard let layer else { return }
        let viewport = TimelineViewport(
            size: bounds.size == .zero ? CGSize(width: 800, height: 240) : bounds.size,
            pixelsPerSecond: pixelsPerSecond,
            scrollX: scrollX,
            trackHeight: trackHeight
        )
        guard let time, let lastLayout else {
            playheadLineLayer?.isHidden = true
            return
        }
        let secs = CGFloat(seconds(time))
        let x = TimelineLayoutCalculator.viewportX(forTimelineSeconds: secs, viewport: viewport)
        // Hide the playhead if it would land behind the track-header column.
        // (Off the right edge is fine — the ScrollView will clip it.)
        guard x >= TimelineLayoutCalculator.trackHeaderWidth else {
            playheadLineLayer?.isHidden = true
            return
        }

        if playheadLineLayer == nil {
            let l = CALayer()
            l.backgroundColor = Theme.NSColor.timelinePlayhead.cgColor
            l.zPosition = 1000  // above all clip layers
            // Dark halo so the white line reads crisply over BOTH light clip
            // thumbnails and dark lanes — without it a thin line vanishes
            // into busy content (the "choppy / blends in" problem).
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.5
            l.shadowRadius = 1.5
            l.shadowOffset = .zero
            layer.addSublayer(l)
            playheadLineLayer = l
        }
        playheadLineLayer?.isHidden = false

        // Wrap in a no-animation CATransaction so per-frame updates
        // don't smear across the redraw boundary.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadLineLayer?.frame = CGRect(
            x: x - 1,   // centre the 2pt line on the exact time position
            y: 0,
            width: 2,
            height: lastLayout.totalContentHeight
        )
        CATransaction.commit()
    }

    // MARK: - Mouse handling

    public override func mouseDown(with event: NSEvent) {
        guard let lastLayout else { return }
        let point = convert(event.locationInWindow, from: nil)
        let hit = TimelineHitTest.hit(at: point, in: lastLayout)
        let optionHeld = event.modifierFlags.contains(.option)

        switch hit {
        case .clipBody(let clipID, _):
            onSelect?(clipID)
            onSelectEffectKeyframe?(nil)
            // ⌥-click on the body splits at the click point — common DAW
            // convention. We deliberately don't honour ⌥ on the edge zones;
            // those stay as trim handles to avoid the user accidentally
            // splitting at the very start/end of a clip (which the
            // SplitClipCommand bounds-check would reject anyway).
            if optionHeld {
                postSplit(at: point, clipID: clipID)
                dragSession = nil
            } else {
                dragSession = DragSession(kind: .move, clipID: clipID, effectKeyframeID: nil, startPoint: point, currentDeltaPixels: 0)
            }
        case .clipLeftEdge(let clipID, _):
            onSelect?(clipID)
            onSelectEffectKeyframe?(nil)
            dragSession = DragSession(kind: .trimIn, clipID: clipID, effectKeyframeID: nil, startPoint: point, currentDeltaPixels: 0)
        case .clipRightEdge(let clipID, _):
            onSelect?(clipID)
            onSelectEffectKeyframe?(nil)
            dragSession = DragSession(kind: .trimOut, clipID: clipID, effectKeyframeID: nil, startPoint: point, currentDeltaPixels: 0)
        case .ruler:
            onSelect?(nil)
            onSelectEffectKeyframe?(nil)
            postScrub(at: point)
            dragSession = DragSession(kind: .scrub, clipID: nil, effectKeyframeID: nil, startPoint: point, currentDeltaPixels: 0)
        case .effectKeyframeBody(let kfID):
            onSelect?(nil)
            onSelectEffectKeyframe?(kfID)
            window?.makeFirstResponder(self)
            dragSession = DragSession(kind: .moveEffect, clipID: nil, effectKeyframeID: kfID, startPoint: point, currentDeltaPixels: 0)
        case .effectKeyframeLeftEdge(let kfID):
            onSelect?(nil)
            onSelectEffectKeyframe?(kfID)
            window?.makeFirstResponder(self)
            dragSession = DragSession(kind: .trimEffectIn, clipID: nil, effectKeyframeID: kfID, startPoint: point, currentDeltaPixels: 0)
        case .effectKeyframeRightEdge(let kfID):
            onSelect?(nil)
            onSelectEffectKeyframe?(kfID)
            window?.makeFirstResponder(self)
            dragSession = DragSession(kind: .trimEffectOut, clipID: nil, effectKeyframeID: kfID, startPoint: point, currentDeltaPixels: 0)
        case .emptyEffectsLane:
            onSelect?(nil)
            // ⌥-click adds a new zoom keyframe at the click point. The
            // keyframe uses `EffectKeyframe`'s shared zoom easing defaults;
            // subsequent drag edits resize it. Without the option modifier,
            // treat as deselect — consistent with the empty-track-lane
            // behaviour.
            if optionHeld {
                postAddKeyframe(at: point)
            } else {
                onSelectEffectKeyframe?(nil)
            }
            dragSession = nil
        case .effectsLaneHeader:
            onSelectEffectKeyframe?(nil)
            dragSession = nil
        case .laneDisclosure(let groupID):
            // Branch B (Slice B.4): chevron click toggles the lane's
            // collapse state. Reads the current value through
            // `isLaneCollapsed` (which honours the smart-default seed
            // for lanes the user hasn't touched yet) and flips it.
            guard let project else {
                dragSession = nil
                return
            }
            let nowCollapsed = !project.isLaneCollapsed(groupID)
            onApplyCommand?(SetLaneCollapsedCommand(
                groupID: groupID,
                collapsed: nowCollapsed
            ))
            dragSession = nil
        case .rowResizeHandle(let rowID, let currentHeight):
            // Per-row height resize: vertical drag adjusts just this row.
            // No selection change — the user is manipulating chrome.
            dragSession = DragSession(
                kind: .resizeRow,
                rowID: rowID,
                startRowHeight: currentHeight,
                startPoint: point,
                currentDeltaPixels: 0
            )
        case .trackHeader, .emptyLane, .empty:
            onSelect?(nil)
            onSelectEffectKeyframe?(nil)
            dragSession = nil
        }
    }

    private func postAddKeyframe(at point: CGPoint) {
        let viewport = TimelineViewport(
            size: bounds.size == .zero ? CGSize(width: 800, height: 240) : bounds.size,
            pixelsPerSecond: pixelsPerSecond,
            scrollX: scrollX,
            trackHeight: trackHeight
        )
        let secs = TimelineLayoutCalculator.timelineSeconds(forViewportX: point.x, viewport: viewport)
        let kf = EffectKeyframe(
            kind: .zoom,
            timelineRange: TimeRange(
                start: .seconds(Double(secs)),
                duration: .seconds(1.5)
            )
        )
        onApplyCommand?(AddEffectKeyframeCommand(keyframe: kf))
        onSelectEffectKeyframe?(kf.id)
    }

    private func postScrub(at point: CGPoint) {
        let viewport = TimelineViewport(
            size: bounds.size == .zero ? CGSize(width: 800, height: 240) : bounds.size,
            pixelsPerSecond: pixelsPerSecond,
            scrollX: scrollX,
            trackHeight: trackHeight
        )
        let secs = TimelineLayoutCalculator.timelineSeconds(forViewportX: point.x, viewport: viewport)
        onScrub?(RationalTime.seconds(Double(secs)))
    }

    private func postSplit(at point: CGPoint, clipID: ClipID) {
        let viewport = TimelineViewport(
            size: bounds.size == .zero ? CGSize(width: 800, height: 240) : bounds.size,
            pixelsPerSecond: pixelsPerSecond,
            scrollX: scrollX,
            trackHeight: trackHeight
        )
        let secs = TimelineLayoutCalculator.timelineSeconds(forViewportX: point.x, viewport: viewport)
        let splitTime = RationalTime.seconds(Double(secs))
        onApplyCommand?(SplitClipCommand(clipID: clipID, splitTime: splitTime))
    }

    public override func mouseDragged(with event: NSEvent) {
        guard var session = dragSession else { return }
        let point = convert(event.locationInWindow, from: nil)
        session.currentDeltaPixels = point.x - session.startPoint.x
        session.currentDeltaYPixels = point.y - session.startPoint.y
        dragSession = session
        if session.kind == .scrub {
            // Scrub fires per-tick (no commit on mouseUp; the player is
            // already at the dragged time). No layer rebuild — the
            // playhead follows the player via setPlayhead(time:) on the
            // next SwiftUI update tick.
            postScrub(at: point)
        } else if session.kind == .resizeRow, let rowID = session.rowID {
            // Live per-row resize: track the cursor through the same
            // clamps the layout applies, then rebuild. Also grow the
            // document + natural size so an expanding bottom row isn't
            // clipped until the host's SwiftUI update lands.
            let newHeight = max(
                TimelineLayoutCalculator.minTrackHeight,
                min(TimelineLayoutCalculator.maxTrackHeight, session.startRowHeight + session.currentDeltaYPixels)
            )
            liveRowHeights[rowID] = newHeight
            rebuildLayers()
            if let layout = lastLayout {
                naturalContentSize.height = layout.totalContentHeight
                let targetHeight = max(layout.totalContentHeight, enclosingScrollView?.contentSize.height ?? 0)
                if frame.height != targetHeight {
                    setFrameSize(NSSize(width: frame.width, height: targetHeight))
                }
            }
        } else {
            rebuildLayers()
        }
    }

    public override func mouseUp(with event: NSEvent) {
        guard let session = dragSession else { return }
        defer {
            dragSession = nil
            rebuildLayers()
        }
        // Scrub doesn't produce an EditCommand on mouseUp.
        if session.kind == .scrub { return }
        // Row resize is view state, not a document edit: fold the live
        // value into the committed map, hand the full map to the host,
        // and skip the EditCommand path entirely.
        if session.kind == .resizeRow {
            guard !liveRowHeights.isEmpty else { return }
            rowHeightOverrides.merge(liveRowHeights) { _, live in live }
            liveRowHeights = [:]
            window?.invalidateCursorRects(for: self)
            onRowHeightsChange?(rowHeightOverrides)
            return
        }
        let pps = max(TimelineLayoutCalculator.minPixelsPerSecond,
                      min(TimelineLayoutCalculator.maxPixelsPerSecond, pixelsPerSecond))
        let deltaSeconds = Double(session.currentDeltaPixels / pps)
        // Threshold: ignore micro-drags (< 1pt) so a click that moves a
        // hair while the user releases the mouse doesn't churn an undo
        // entry.
        guard abs(session.currentDeltaPixels) >= 1 else { return }
        let delta = RationalTime.seconds(deltaSeconds)
        switch session.kind {
        case .move:
            guard let clipID = session.clipID else { return }
            // Move uses an absolute newTimelineStart, so we add delta to
            // the clip's current start. Clamped to t=0: the user cannot
            // drag a clip past the start of the timeline (strict snap).
            guard let clip = project?.clip(clipID) else { return }
            let proposedStart = seconds(clip.timelineRange.start) + deltaSeconds
            let newStart = RationalTime.seconds(max(0, proposedStart))
            // Branch B (Slice B.5): if the lead clip's lane is
            // collapsed, propagate the move to every overlapping clip
            // on the lane's underlying physical tracks. Otherwise the
            // single-clip command applies as before.
            let groupIDs = project?.clipsOnCollapsedLaneOverlapping(clipID) ?? [clipID]
            if groupIDs.count > 1 {
                onApplyCommand?(MoveClipsGroupCommand(
                    clipIDs: groupIDs,
                    leadClipID: clipID,
                    newTimelineStart: newStart
                ))
            } else {
                onApplyCommand?(MoveClipCommand(clipID: clipID, newTimelineStart: newStart))
            }
        case .trimIn:
            guard let clipID = session.clipID else { return }
            let groupIDs = project?.clipsOnCollapsedLaneOverlapping(clipID) ?? [clipID]
            if groupIDs.count > 1 {
                onApplyCommand?(TrimClipsGroupCommand(clipIDs: groupIDs, delta: delta))
            } else {
                onApplyCommand?(TrimClipInCommand(clipID: clipID, delta: delta))
            }
        case .trimOut:
            guard let clipID = session.clipID else { return }
            let groupIDs = project?.clipsOnCollapsedLaneOverlapping(clipID) ?? [clipID]
            if groupIDs.count > 1 {
                onApplyCommand?(TrimClipsOutGroupCommand(clipIDs: groupIDs, delta: delta))
            } else {
                onApplyCommand?(TrimClipOutCommand(clipID: clipID, delta: delta))
            }
        case .moveEffect, .trimEffectIn, .trimEffectOut:
            guard let kfID = session.effectKeyframeID,
                  let original = project?.effects.first(where: { $0.id == kfID }) else { return }
            let oldStart = seconds(original.timelineRange.start)
            let oldDuration = seconds(original.timelineRange.duration)
            // Floor for any keyframe duration — keeps the segment visible
            // at minimum zoom (1pt at maxPixelsPerSecond = 1/800s) and
            // sidesteps the command's "duration must be > 0" guard.
            let minDuration: Double = 0.01
            var newStartSec = oldStart
            var newDurationSec = oldDuration
            switch session.kind {
            case .moveEffect:
                newStartSec = max(0, oldStart + deltaSeconds)
            case .trimEffectIn:
                let clamped = min(max(deltaSeconds, -oldStart), oldDuration - minDuration)
                newStartSec = oldStart + clamped
                newDurationSec = oldDuration - clamped
            case .trimEffectOut:
                newDurationSec = max(minDuration, oldDuration + deltaSeconds)
            default:
                break
            }
            guard newStartSec != oldStart || newDurationSec != oldDuration else { return }
            var updated = original
            updated.timelineRange = TimeRange(
                start: .seconds(newStartSec),
                duration: .seconds(newDurationSec)
            )
            onApplyCommand?(UpdateEffectKeyframeCommand(keyframeID: kfID, newValue: updated))
        case .scrub, .resizeRow:
            // Already returned above; these cases for exhaustiveness.
            break
        }
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        // Delete / Backspace removes the selected effect keyframe. Clip
        // deletion is currently driven via the Inspector "Remove" button —
        // not wired here to avoid surprising the user with a destructive
        // hotkey on a timeline that doesn't yet have multi-clip selection.
        let isDelete = event.keyCode == 51 || event.keyCode == 117
        if isDelete, let id = selectedEffectKeyframeID {
            onApplyCommand?(RemoveEffectKeyframeCommand(keyframeID: id))
            onSelectEffectKeyframe?(nil)
            return
        }
        super.keyDown(with: event)
    }

    private func seconds(_ t: RationalTime) -> Double {
        guard t.timescale != 0 else { return 0 }
        return Double(t.value) / Double(t.timescale)
    }
}

/// NSView host for the sticky ruler. Lives as a floating subview of the
/// timeline's NSScrollView (`addFloatingSubview(_:for: .vertical)`) so
/// it stays pinned to the top of the viewport during vertical scroll
/// while still scrolling horizontally with the document content — tick
/// alignment with clip frames holds at every scroll position.
///
/// Also owns the playhead "head" pentagon. Putting the head here means
/// it stays visible inside the sticky ruler even when the user scrolls
/// past the document's ruler region; the companion vertical line is
/// still drawn into `TimelineNSView` so it spans the lanes.
///
/// Sized in viewport-flipped coords by `TimelineView.sizeDocumentView`:
/// the view's full width equals the document's content width and AppKit
/// clips during draw. We render ticks in absolute document-x (no
/// `scrollSeconds` math), matching the horizontal scroll naturally.
public final class StickyRulerView: NSView {
    private let rulerLayer = RulerLayer()
    private let playheadHead = CAShapeLayer()
    var onScrub: ((RationalTime) -> Void)?

    var pixelsPerSecond: CGFloat = TimelineLayoutCalculator.defaultPixelsPerSecond {
        didSet {
            rulerLayer.pixelsPerSecond = pixelsPerSecond
            updatePlayheadHead()
        }
    }

    var playheadTime: RationalTime? {
        didSet { updatePlayheadHead() }
    }

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.NSColor.timelineRuler.cgColor
        rulerLayer.scrollSeconds = 0  // we span the document; absolute x
        rulerLayer.headerWidth = TimelineLayoutCalculator.trackHeaderWidth
        rulerLayer.pixelsPerSecond = pixelsPerSecond
        layer?.addSublayer(rulerLayer)
        configurePlayheadHead()
        layer?.addSublayer(playheadHead)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rulerLayer.frame = bounds
        rulerLayer.contentsScale = window?.backingScaleFactor ?? 2
        rulerLayer.setNeedsDisplay()
        updatePlayheadHead()
        CATransaction.commit()
    }

    private func configurePlayheadHead() {
        let w: CGFloat = 9
        let h = TimelineLayoutCalculator.rulerHeight
        // A small white capsule grabber marking the exact playhead x —
        // the modern scrubber handle (vs the old chunky pennant). A dark
        // shadow lifts it off the ruler so it reads as a deliberate handle
        // over any content.
        let capsule = CGRect(x: 0, y: 4, width: w, height: h - 8)
        playheadHead.path = CGPath(
            roundedRect: capsule,
            cornerWidth: capsule.width / 2,
            cornerHeight: capsule.width / 2,
            transform: nil
        )
        playheadHead.fillColor = Theme.NSColor.timelinePlayhead.cgColor
        playheadHead.strokeColor = NSColor.clear.cgColor
        playheadHead.zPosition = 1
        playheadHead.shadowColor = NSColor.black.cgColor
        playheadHead.shadowOpacity = 0.45
        playheadHead.shadowRadius = 1.5
        playheadHead.shadowOffset = .zero
        playheadHead.isHidden = true
    }

    private func updatePlayheadHead() {
        guard let time = playheadTime else {
            playheadHead.isHidden = true
            return
        }
        let pps = max(TimelineLayoutCalculator.minPixelsPerSecond,
                      min(TimelineLayoutCalculator.maxPixelsPerSecond, pixelsPerSecond))
        let secs = CGFloat(seconds(time))
        let x = TimelineLayoutCalculator.trackHeaderWidth + secs * pps
        guard x >= TimelineLayoutCalculator.trackHeaderWidth, x <= bounds.maxX else {
            playheadHead.isHidden = true
            return
        }
        playheadHead.isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let headWidth: CGFloat = 9
        playheadHead.frame = CGRect(
            x: x - headWidth / 2,
            y: 0,
            width: headWidth,
            height: TimelineLayoutCalculator.rulerHeight
        )
        CATransaction.commit()
    }

    // MARK: - Click + drag scrubbing
    // Mirrors `TimelineNSView`'s `.ruler` hit-zone behaviour. The
    // document-resident ruler used to receive these clicks; with the
    // floating ruler now covering that area, we forward scrub events
    // from here. Clicks landing in the track-header column (x < headerWidth)
    // are ignored.

    public override func mouseDown(with event: NSEvent) {
        postScrub(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseDragged(with event: NSEvent) {
        postScrub(at: convert(event.locationInWindow, from: nil))
    }

    private func postScrub(at point: CGPoint) {
        guard point.x >= TimelineLayoutCalculator.trackHeaderWidth else { return }
        let pps = max(TimelineLayoutCalculator.minPixelsPerSecond,
                      min(TimelineLayoutCalculator.maxPixelsPerSecond, pixelsPerSecond))
        let secs = max(0, (point.x - TimelineLayoutCalculator.trackHeaderWidth) / pps)
        onScrub?(RationalTime.seconds(Double(secs)))
    }

    private func seconds(_ t: RationalTime) -> Double {
        guard t.timescale != 0 else { return 0 }
        return Double(t.value) / Double(t.timescale)
    }
}
#endif
