#if canImport(AppKit)
import AppKit
import Foundation

// Quit-and-relaunch helper. The Screen Recording permission, once granted in
// System Settings, does not take effect for the running process — only a
// fresh launch picks up the new TCC entry. The onboarding view shows a "Quit
// & Relaunch" CTA tied to this enum after the coordinator detects a pending
// relaunch.
//
// Implementation note: `/usr/bin/open -n <Bundle>` spawns a new instance of
// the same app, which is reliable across direct-distribution builds. We do
// this BEFORE terminating the current process so the user does not see a
// dock-icon disappearance gap.
@MainActor
public enum AppRelauncher {
    public static func quitAndRelaunch(bundleURL: URL = Bundle.main.bundleURL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        do {
            try task.run()
        } catch {
            // If `open` fails for some reason there is nothing useful we can
            // do here — terminating without a relaunch leaves the user worse
            // off than not relaunching at all, so we bail.
            return
        }
        NSApp.terminate(nil)
    }
}
#endif
