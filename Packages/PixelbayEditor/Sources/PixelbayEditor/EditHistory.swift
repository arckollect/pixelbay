import Foundation
import OSLog
import PixelbayCore

private let log = Logger(subsystem: "com.pixelbay.PixelbayApp", category: "EditHistory")

// Owns the editor's `Project` plus its undo/redo stacks. Single-document
// model — Phase 2's UI mounts one EditHistory per `.pixelbay` bundle.
//
// Concurrency: actor — the @MainActor view models call into it via await,
// and editing operations (some involving async asset loads later) are
// naturally serial against a single document. SwiftUI binds via a thin
// @Observable view model wrapper that mirrors `project` per change.
public actor EditHistory {
    public private(set) var project: Project
    private var undoStack: [any EditCommand] = []
    private var redoStack: [any EditCommand] = []

    /// Soft cap on the undo stack. Past this we drop the oldest entries.
    /// Phase 2 doesn't expose a configuration knob; if a user complains
    /// they hit it during a session, raise it.
    public var maximumHistory: Int = 256

    public init(project: Project) {
        self.project = project
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// The display name of the last applied command (for menu strings:
    /// "Undo Trim Clip"). Nil when the undo stack is empty.
    public var undoActionName: String? {
        undoStack.last?.displayName
    }

    /// The display name of the most-recently-undone command (for "Redo X"
    /// menus). Nil when nothing is queued for redo.
    public var redoActionName: String? {
        redoStack.last?.displayName
    }

    /// Applies a command to the project, pushes its inverse onto the undo
    /// stack, and clears the redo stack (linear-history model). Throws
    /// EditError if the command itself rejects.
    public func apply(_ command: any EditCommand) throws {
        let inverse = try command.apply(to: &project)
        undoStack.append(inverse)
        if undoStack.count > maximumHistory {
            undoStack.removeFirst(undoStack.count - maximumHistory)
        }
        redoStack.removeAll()
        log.debug("apply \(command.displayName, privacy: .public) — undoStack=\(self.undoStack.count) redoStack=0")
    }

    /// Pops the top inverse off the undo stack, applies it (which produces
    /// its own inverse — the "redo of the original"), and pushes that onto
    /// the redo stack.
    public func undo() throws {
        guard let inverse = undoStack.popLast() else { return }
        let redoCommand = try inverse.apply(to: &project)
        redoStack.append(redoCommand)
        log.debug("undo — undoStack=\(self.undoStack.count) redoStack=\(self.redoStack.count)")
    }

    public func redo() throws {
        guard let redoCommand = redoStack.popLast() else { return }
        let inverse = try redoCommand.apply(to: &project)
        undoStack.append(inverse)
        log.debug("redo — undoStack=\(self.undoStack.count) redoStack=\(self.redoStack.count)")
    }

    /// Replaces the project entirely (e.g. on bundle reload from disk).
    /// Drops both stacks — recorded ops can't safely span a project swap.
    public func replace(project: Project) {
        self.project = project
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
