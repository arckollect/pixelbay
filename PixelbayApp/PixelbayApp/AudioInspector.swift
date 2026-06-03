import PixelbayCore
import PixelbayDesignSystem
import PixelbayEditor
import SwiftUI

// Audio tab — per-selected-clip volume + speed, carved out of ProjectView's
// inline clipInspector. Owns the in-progress drag preview dictionaries (only
// this view reads them) so a slider drag commits ONE EditCommand on release
// instead of flooding the undo stack with per-tick micro-edits.
//
// Track-mute controls are appended below when audio-bearing tracks exist
// (see `tracks`/`onToggleMute`), giving the tab a light mixer feel.

struct AudioInspector: View {
    let clip: Clip?
    /// Audio-bearing tracks (mic / system audio / voiceover) for the mute
    /// list. Empty → the mute section is omitted.
    let audioTracks: [Track]
    let onApply: (any EditCommand) -> Void

    @State private var previewVolumes: [ClipID: Double] = [:]
    @State private var previewSpeeds: [ClipID: Double] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            clipSection
            if !audioTracks.isEmpty {
                PBDivider()
                tracksSection
            }
        }
    }

    // MARK: - Selected clip

    @ViewBuilder
    private var clipSection: some View {
        if let clip {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                PBSectionHeader("Clip")
                volumeSlider(for: clip)
                speedSlider(for: clip)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                PBSectionHeader("Clip")
                Text("Select a clip in the timeline to edit its volume and speed.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func volumeSlider(for clip: Clip) -> some View {
        let liveValue = previewVolumes[clip.id] ?? min(clip.volume, 2.0)
        let clipID = clip.id
        let committedValue = clip.volume
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("Volume")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                Text(String(format: "%.0f%%", liveValue * 100))
                    .font(Theme.Font.monoTimecode)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Slider(
                value: Binding<Double>(
                    get: { liveValue },
                    set: { newValue in previewVolumes[clipID] = newValue }
                ),
                in: 0...2,
                onEditingChanged: { isEditing in
                    guard !isEditing, let final = previewVolumes[clipID] else { return }
                    previewVolumes[clipID] = nil
                    if abs(final - committedValue) < 0.0001 { return }
                    onApply(SetClipVolumeCommand(clipID: clipID, newVolume: final))
                }
            )
        }
    }

    private func speedSlider(for clip: Clip) -> some View {
        let liveValue = previewSpeeds[clip.id] ?? min(max(clip.speed, 0.25), 4.0)
        let clipID = clip.id
        let committedValue = clip.speed
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("Speed")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                Text(String(format: "%.2f×", liveValue))
                    .font(Theme.Font.monoTimecode)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Slider(
                value: Binding<Double>(
                    get: { liveValue },
                    set: { newValue in previewSpeeds[clipID] = newValue }
                ),
                in: 0.25...4.0,
                onEditingChanged: { isEditing in
                    guard !isEditing, let final = previewSpeeds[clipID] else { return }
                    previewSpeeds[clipID] = nil
                    if abs(final - committedValue) < 0.0001 { return }
                    onApply(SetClipSpeedCommand(clipID: clipID, newSpeed: final))
                }
            )
        }
    }

    // MARK: - Track mute list

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            PBSectionHeader("Tracks")
            ForEach(audioTracks) { track in
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: track.kind.inspectorSymbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(track.muted ? Theme.Color.textTertiary : Theme.Color.accent)
                        .frame(width: 18)
                    Text(track.name)
                        .font(Theme.Font.body)
                        .foregroundStyle(track.muted ? Theme.Color.textSecondary : Theme.Color.textPrimary)
                    Spacer()
                    Button {
                        onApply(SetTrackMutedCommand(trackID: track.id, muted: !track.muted))
                    } label: {
                        Image(systemName: track.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(track.muted ? Theme.Color.danger : Theme.Color.textSecondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(track.muted ? "Unmute \(track.name)" : "Mute \(track.name)")
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// SF Symbol per track kind — shared by the Audio tab mute list and the
// timeline lane headers so iconography stays consistent across the editor.
extension TrackKind {
    /// Tracks that carry their own audio stream — the ones worth surfacing
    /// in the Audio tab's mute list. Screen/webcam can carry audio too, but
    /// the dedicated mic / system-audio / voiceover tracks are the ones the
    /// editor splits out, so those are the mixer rows.
    var isAudioBearing: Bool {
        switch self {
        case .microphone, .systemAudio, .voiceover: return true
        case .screen, .webcam, .overlay, .effects: return false
        }
    }

    var inspectorSymbol: String {
        switch self {
        case .screen: return "display"
        case .webcam: return "video.fill"
        case .microphone: return "mic.fill"
        case .systemAudio: return "speaker.wave.2.fill"
        case .voiceover: return "waveform"
        case .overlay: return "rectangle.on.rectangle"
        case .effects: return "plus.magnifyingglass"
        }
    }
}
