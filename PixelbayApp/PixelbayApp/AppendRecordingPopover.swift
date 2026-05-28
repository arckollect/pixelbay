import AVFoundation
import CoreGraphics
import Foundation
import OSLog
import PixelbayCore
import SwiftUI

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "AppendRecordingPopover")

// Slice A.3 — popover anchored to the timeline-end "+" button. Reuses
// `ScenesSourceCatalog` for display / camera / mic enumeration so a third
// caller (after PrecaptureModel and ScenesWindowView) doesn't drift from
// the canonical SCShareableContent + AVCaptureDevice flow.
//
// Lifecycle:
//   - The user clicks "+", popover appears with the same sources the
//     editor's project was originally recorded against (best-effort —
//     ScenesSourceCatalog re-enumerates on appear so a hot-plugged display
//     shows up).
//   - The user clicks Start → recording begins with `appendTracks: false`
//     against the editor's bundle. The view flips to a "Recording…" panel
//     with elapsed time and a Stop button (the existing HUD also appears).
//   - On stop, the popover closes and the caller's `onRecorded(result)`
//     handler routes the result into `ProjectDocument.appendRecordingToTimeline`.

struct AppendRecordingPopover: View {
    @Environment(RecordingService.self) private var recording
    @Environment(\.dismiss) private var dismiss

    /// The editor's bundle. RecordingService writes new assets into it
    /// directly via `existingBundle:`.
    let bundle: ProjectBundle
    /// Callback fired after the user clicks Stop and the recording
    /// finalizes. Caller is expected to route into ProjectDocument.
    let onRecorded: (RecordingService.Result) -> Void

    @State private var catalog = ScenesSourceCatalog()
    @State private var selectedDisplayID: CGDirectDisplayID?
    @State private var selectedCameraID: String?
    @State private var selectedMicrophoneID: String?
    @State private var includeSystemAudio: Bool = true
    @State private var startedAt: Date?
    @State private var localPhase: LocalPhase = .picking
    @State private var lastErrorMessage: String?

    private enum LocalPhase: Equatable {
        case picking
        case starting
        case recording
        case stopping
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch localPhase {
            case .picking, .starting:
                pickerBody
            case .recording, .stopping:
                recordingBody
            }
            if let lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 380)
        .task {
            await catalog.reload()
            let seeded = catalog.seedingDefaultsIfMissing(
                from: (
                    displayID: selectedDisplayID,
                    cameraUniqueID: selectedCameraID,
                    micUniqueID: selectedMicrophoneID
                )
            )
            selectedDisplayID = seeded.displayID
            selectedCameraID = seeded.cameraUniqueID
            selectedMicrophoneID = seeded.micUniqueID
        }
        .onChange(of: recording.phase) { _, new in
            handleRecordingPhase(new)
        }
    }

    // MARK: - Picker

    private var pickerBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Record more")
                .font(.headline)
            Text("Append a new recording to the end of this project's timeline.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Display", selection: $selectedDisplayID) {
                if catalog.displays.isEmpty {
                    Text("No displays available").tag(CGDirectDisplayID?.none)
                }
                ForEach(catalog.displays) { display in
                    Text(display.localizedName).tag(CGDirectDisplayID?.some(display.id))
                }
            }
            .pickerStyle(.menu)

            Picker("Camera", selection: $selectedCameraID) {
                Text("None").tag(String?.none)
                ForEach(catalog.cameras) { cam in
                    Text(cam.localizedName).tag(String?.some(cam.id))
                }
            }
            .pickerStyle(.menu)

            Picker("Microphone", selection: $selectedMicrophoneID) {
                Text("None").tag(String?.none)
                ForEach(catalog.microphones) { mic in
                    Text(mic.localizedName).tag(String?.some(mic.id))
                }
            }
            .pickerStyle(.menu)

            Toggle("Capture system audio", isOn: $includeSystemAudio)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button {
                    Task { await start() }
                } label: {
                    Label("Start", systemImage: "record.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedDisplayID == nil || localPhase != .picking)
            }
        }
    }

    // MARK: - Recording state

    private var recordingBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording…").font(.headline)
                    if let startedAt {
                        TimelineView(.periodic(from: startedAt, by: 0.1)) { ctx in
                            Text(elapsedLabel(ctx.date.timeIntervalSince(startedAt)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
            Text("The new recording will append after the existing timeline content when you click Stop.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button {
                    Task { await stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(localPhase != .recording)
            }
        }
    }

    private func elapsedLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let m = total / 60
        let s = total % 60
        return String(format: "Elapsed %d:%02d", m, s)
    }

    // MARK: - Recording lifecycle

    @MainActor
    private func start() async {
        guard let displayID = selectedDisplayID else { return }
        lastErrorMessage = nil
        localPhase = .starting
        startedAt = Date()
        let bounds = catalog.displays.first(where: { $0.id == displayID })?.globalBounds
        let request = RecordingService.StartRequest(
            displayID: displayID,
            displayPointsBounds: bounds,
            cameraID: selectedCameraID,
            micID: selectedMicrophoneID,
            includeSystemAudio: includeSystemAudio,
            logClicks: false,
            // Critical — assets-only into the editor's bundle. The editor's
            // command pipeline (in ProjectDocument.appendRecordingToTimeline)
            // creates the tracks/clips so undo / redo work uniformly.
            appendTracks: false
        )
        await recording.start(request, existingBundle: bundle)
    }

    @MainActor
    private func stop() async {
        localPhase = .stopping
        await recording.stop()
    }

    /// Reacts to `RecordingService.phase` transitions. We don't poll —
    /// `onChange(of: recording.phase)` already gives us the transitions.
    @MainActor
    private func handleRecordingPhase(_ phase: RecordingService.Phase) {
        switch phase {
        case .recording:
            // The async `start` task may have returned before the service
            // transitions to .recording; the popover's local phase should
            // follow whenever the service confirms.
            if localPhase == .starting {
                localPhase = .recording
            }
        case .stopped(let result):
            // Hand the result off to the caller, then close.
            recording.acknowledgeResult()
            onRecorded(result)
            dismiss()
        case .failed(let message):
            lastErrorMessage = message
            localPhase = .picking
            recording.acknowledgeResult()
        case .idle:
            // External actor acknowledged before we ran; reset to picker.
            if localPhase != .picking {
                localPhase = .picking
            }
        default:
            break
        }
    }
}
