import Foundation
import OSLog
import Observation
import PixelbayCore
import PixelbayEditor

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "ProjectDocument")

// MainActor-bound document object that wires the Editor model into SwiftUI.
//
// Owns:
//   • the EditHistory actor (which owns the Project + undo/redo stacks)
//   • a mirror of the Project on the main actor (so SwiftUI binds without
//     async hops; refreshed on every command apply / undo / redo / load)
//   • the bundle URL (for save)
//   • a "dirty" flag (true between mutations and the next save)
//
// Phase 2 v0.1's Inspector + Save / Undo / Redo work against this. The
// timeline UI in PixelbayTimelineUI will bind to the same shape — its
// drag-handlers post EditCommands through `apply(_:)`.

@MainActor
@Observable
final class ProjectDocument {
    enum Status: Equatable {
        case idle
        case loading
        case ready
        case saving
        case failed(message: String)
    }

    private(set) var status: Status = .idle
    private(set) var project: Project
    private(set) var canUndo: Bool = false
    private(set) var canRedo: Bool = false
    private(set) var undoActionName: String?
    private(set) var redoActionName: String?
    private(set) var isDirty: Bool = false
    /// Monotonic counter incremented on every apply / undo / redo. Used by
    /// ProjectView to key its preview-rebuild task — each committed edit
    /// reloads the AVMutableComposition so playback reflects trims /
    /// splits / volume changes immediately. Save does NOT bump this:
    /// content is unchanged, just persisted.
    private(set) var revision: Int = 0

    let bundleURL: URL
    private let history: EditHistory
    private let store: ProjectBundleStore

    init(bundleURL: URL, project: Project, store: ProjectBundleStore = ProjectBundleStore()) {
        self.bundleURL = bundleURL
        self.project = project
        self.history = EditHistory(project: project)
        self.store = store
        self.status = .ready
    }

    /// Apply a command via the underlying EditHistory actor and refresh
    /// the main-actor mirror. Errors surface as Status.failed(message:);
    /// callers are expected to surface them in UI.
    func apply(_ command: any EditCommand) async {
        do {
            try await history.apply(command)
            await refreshFromHistory()
            isDirty = true
            revision &+= 1
        } catch {
            log.error("apply \(command.displayName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            status = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func undo() async {
        do {
            try await history.undo()
            await refreshFromHistory()
            isDirty = true
            revision &+= 1
        } catch {
            log.error("undo failed: \(String(describing: error), privacy: .public)")
            status = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func redo() async {
        do {
            try await history.redo()
            await refreshFromHistory()
            isDirty = true
            revision &+= 1
        } catch {
            log.error("redo failed: \(String(describing: error), privacy: .public)")
            status = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Atomic save back to project.json. Updates the in-memory project's
    /// `modifiedAt` first so the on-disk file reflects the save time.
    func save() async {
        guard !project.tracks.isEmpty || !project.assets.isEmpty || isDirty else { return }
        status = .saving
        var snapshot = project
        snapshot.modifiedAt = Date()
        let bundle = ProjectBundle(url: bundleURL)
        do {
            try store.writeProject(snapshot, to: bundle)
            await history.replace(project: snapshot)
            await refreshFromHistory()
            isDirty = false
            status = .ready
            log.info("saved project at \(self.bundleURL.path, privacy: .public)")
        } catch {
            log.error("save failed: \(String(describing: error), privacy: .public)")
            status = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func acknowledgeError() {
        if case .failed = status {
            status = .ready
        }
    }

    /// Open a project bundle from disk into a fresh ProjectDocument. Returns
    /// nil with logging if the bundle is missing project.json or fails to
    /// decode — the caller (App.openProject) surfaces the error in UI.
    ///
    /// Auto-heals projects that have MediaAssets but no Tracks. Pre-fix
    /// recordings (RecordingService versions before 2026-05-02) only wrote
    /// MediaAsset records, never the Tracks/Clips that PreviewCompositionBuilder
    /// iterates — opening such a project would surface "Project has no screen
    /// recording asset to preview" with no editable surface. The synthesized
    /// tracks aren't marked dirty (no implicit "Save (modified)" badge); they
    /// persist only if the user makes some other edit and saves.
    static func open(bundleURL: URL, store: ProjectBundleStore = ProjectBundleStore()) async throws -> ProjectDocument {
        let bundle = ProjectBundle(url: bundleURL)
        var project = try store.loadProject(from: bundle)
        if project.tracks.isEmpty, !project.assets.isEmpty {
            synthesizeTracksFromAssets(into: &project)
            log.info("auto-healed missing tracks for \(bundleURL.path, privacy: .public) — synthesized \(project.tracks.count) track(s)")
        }
        log.info("opened project at \(bundleURL.path, privacy: .public)")
        return ProjectDocument(bundleURL: bundleURL, project: project, store: store)
    }

    private static func synthesizeTracksFromAssets(into project: inout Project) {
        for asset in project.assets where asset.nativeDuration.value > 0 {
            let kind: TrackKind
            let name: String
            switch asset.kind {
            case .display: kind = .screen; name = "Screen"
            case .webcam: kind = .webcam; name = "Webcam"
            case .microphone: kind = .microphone; name = "Microphone"
            case .systemAudio: kind = .systemAudio; name = "System Audio"
            case .voiceover: kind = .voiceover; name = "Voiceover"
            case .imported, .window, .area, .device:
                // These don't have an obvious 1:1 track mapping in v0.1.
                // Skipped here; user can wire them up by hand later.
                continue
            }
            let range = TimeRange(start: .zero, duration: asset.nativeDuration)
            let clip = Clip(assetID: asset.id, sourceRange: range, timelineRange: range)
            project.tracks.append(Track(kind: kind, name: name, clips: [clip]))
        }
    }

    private func refreshFromHistory() async {
        self.project = await history.project
        self.canUndo = await history.canUndo
        self.canRedo = await history.canRedo
        self.undoActionName = await history.undoActionName
        self.redoActionName = await history.redoActionName
    }
}
