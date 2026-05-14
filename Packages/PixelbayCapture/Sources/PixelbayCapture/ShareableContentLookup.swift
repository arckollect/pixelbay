import Foundation
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

#if canImport(ScreenCaptureKit)

// Sendable seam over `SCShareableContent.current`, following the same shape
// as PermissionProbe / FileManagerWrapper (HANDOFF §6.1). The live impl hits
// the real OS; tests inject a fake closure that throws to exercise the
// `.sourceUnavailable` translation paths without spinning up real streams.
public struct ShareableContentLookup: Sendable {
    public var display: @Sendable (CGDirectDisplayID) async throws -> SCDisplay
    public var window: @Sendable (CGWindowID) async throws -> SCWindow
    // Resolves bundle identifiers to SCRunningApplication so the live backend
    // can hand them to SCContentFilter's excludingApplications. Returns only
    // the matches; missing IDs are silently dropped (the worst case is the
    // app's own windows leak into screen.mov, not a recording failure).
    public var applications: @Sendable ([String]) async throws -> [SCRunningApplication]

    public init(
        display: @escaping @Sendable (CGDirectDisplayID) async throws -> SCDisplay,
        window: @escaping @Sendable (CGWindowID) async throws -> SCWindow,
        applications: @escaping @Sendable ([String]) async throws -> [SCRunningApplication] = { ids in
            guard !ids.isEmpty else { return [] }
            let content = try await SCShareableContent.current
            let set = Set(ids)
            return content.applications.filter { set.contains($0.bundleIdentifier) }
        }
    ) {
        self.display = display
        self.window = window
        self.applications = applications
    }

    public static let live = ShareableContentLookup(
        display: { id in
            let content = try await SCShareableContent.current
            guard let match = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError.sourceUnavailable(message: "Display \(id) not in SCShareableContent")
            }
            return match
        },
        window: { id in
            let content = try await SCShareableContent.current
            guard let match = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError.sourceUnavailable(message: "Window \(id) not in SCShareableContent")
            }
            return match
        }
    )
}

#endif
