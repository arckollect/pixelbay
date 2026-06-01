import AVFoundation
import PixelbayDesignSystem
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
struct TakePreviewSheet: View {
    let url: URL
    let title: String
    let takeLabel: String

    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var isPlaying = true

    private var endPublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScenePreviewPlayerView(player: player)
                .frame(width: 760, height: 428)
                .background(Color.black)
                .contentShape(Rectangle())
                .onTapGesture { togglePlay() }
            transport
        }
        .frame(width: 760)
        .background(Theme.Color.bgDeep)
        .onAppear {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
            isPlaying = true
        }
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
