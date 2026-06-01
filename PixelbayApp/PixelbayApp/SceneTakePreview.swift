import AVFoundation
import PixelbayDesignSystem
import PixelbayPlayback
import SwiftUI

// Lightweight take-preview surface for the Scene Recording grid. Plays a
// single take's screen recording (media/screen-{sessionID}.mov) in a sheet.
//
// Deliberately hosts an AVPlayerLayer directly (not AVKit's AVPlayerView):
// the editor learned the hard way that AVPlayerView's AVPlayerController KVO
// races with item swaps (see PreviewPlayer.swift). A plain AVPlayerLayer host
// has none of that machinery, so it's the safe primitive even for a one-shot.

/// SwiftUI wrapper around a layer-backed NSView whose backing layer is an
/// `AVPlayerLayer`. App-local twin of PixelbayPlayback's `PlayerLayerHostingView`
/// (whose `attach` is package-internal, hence not reusable here).
struct ScenePreviewPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.attach(player)
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.attach(player)
    }

    final class PlayerLayerView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layerContentsRedrawPolicy = .duringViewResize
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func makeBackingLayer() -> CALayer {
            let layer = AVPlayerLayer()
            layer.videoGravity = .resizeAspect
            return layer
        }

        private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

        func attach(_ player: AVPlayer) {
            guard let playerLayer, playerLayer.player !== player else { return }
            playerLayer.player = player
        }
    }
}

/// Modal preview of a single recorded take. Auto-plays on open; tap the video
/// (or the transport button) to toggle play/pause; loops back to the start when
/// it reaches the end.
///
/// Plays the *composited* take — screen with the webcam PiP overlaid — by
/// asking the model to build a single-take `PreviewComposition` (same path as
/// the editor preview / merge). If that build fails it falls back to the bare
/// screen recording so the preview still shows something. The composition
/// build is async, so the player shows a brief spinner until the item is ready.
struct TakePreviewSheet: View {
    let model: ScenesSessionModel
    let sceneIndex: Int
    let title: String
    let takeLabel: String
    /// Bare `screen-{sessionID}.mov` used when the composited build returns
    /// nil. `nil` when even the screen recording is missing from the bundle.
    let fallbackScreenURL: URL?

    private enum LoadState: Equatable { case loading, ready, unavailable }

    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var isPlaying = true
    @State private var loadState: LoadState = .loading

    private var endPublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
    }

    var body: some View {
        Group {
            if loadState == .unavailable {
                missingPreview
            } else {
                VStack(spacing: 0) {
                    header
                    ScenePreviewPlayerView(player: player)
                        .frame(width: 760, height: 428)
                        .background(Color.black)
                        .overlay {
                            if loadState == .loading {
                                ProgressView()
                                    .controlSize(.large)
                                    .tint(Theme.Color.textSecondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { togglePlay() }
                    transport
                }
                .frame(width: 760)
            }
        }
        .background(Theme.Color.bgDeep)
        .task { await loadTake() }
        .onDisappear {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        .onReceive(endPublisher) { note in
            // Loop the take so the user can keep watching.
            guard (note.object as? AVPlayerItem) === player.currentItem else { return }
            player.seek(to: .zero)
            player.play()
            isPlaying = true
        }
    }

    /// Builds the composited item (screen + webcam PiP) and starts playback.
    /// Falls back to the bare screen recording, then to an "unavailable" state.
    private func loadTake() async {
        guard loadState == .loading else { return }

        let item: AVPlayerItem
        if let preview = await model.takePreviewComposition(forSceneAt: sceneIndex) {
            let composited = AVPlayerItem(asset: preview.composition)
            if let videoComposition = preview.videoComposition {
                composited.videoComposition = videoComposition
            }
            if let audioMix = preview.audioMix {
                composited.audioMix = audioMix
            }
            item = composited
        } else if let fallbackScreenURL {
            item = AVPlayerItem(url: fallbackScreenURL)
        } else {
            loadState = .unavailable
            return
        }

        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        loadState = .ready
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
            Button("Done") { dismiss() }
                .buttonStyle(.pbSecondary)
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(takeLabel)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.pbSecondary)
        }
        .padding(Theme.Spacing.lg)
    }

    private var transport: some View {
        HStack {
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.pbSecondary)
            Spacer()
        }
        .padding(Theme.Spacing.lg)
    }

    private func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }
}
