#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import Observation

// SwiftUI-side bridge for the actor-isolated PermissionCoordinator. Holds the
// observable status snapshot the view binds to, and forwards user actions to
// the coordinator. Lives on the main actor so SwiftUI updates are safe.
@MainActor
@Observable
public final class PermissionViewModel {
    public private(set) var statuses: [PermissionKind: PermissionStatus]
    public let coordinator: PermissionCoordinator

    public init(coordinator: PermissionCoordinator) {
        self.coordinator = coordinator
        self.statuses = Dictionary(
            uniqueKeysWithValues: PermissionKind.allCases.map { ($0, .notDetermined) }
        )
    }

    public func refresh() async {
        statuses = await coordinator.refresh()
    }

    public func request(_ kind: PermissionKind) async {
        _ = await coordinator.request(kind)
        await refresh()
    }

    public func openSettings(for kind: PermissionKind) async {
        await coordinator.openSettings(for: kind)
    }

    public var anyRequiresRelaunch: Bool {
        statuses.values.contains(.requiresRelaunch)
    }

    public var requiredSatisfied: Bool {
        for kind in PermissionKind.allCases where kind.isRequiredForLaunch {
            if statuses[kind] != .granted { return false }
        }
        return true
    }
}

// First-launch onboarding scene. Renders one row per permission with the
// current status and a Grant button. The "Quit & Relaunch" CTA appears only
// when at least one row is in .requiresRelaunch — the documented Screen
// Recording grant flow.
//
// The view polls the coordinator on a 1.5s tick while visible. macOS may
// update preflight asynchronously after the user grants in System Settings,
// and we want the row to flip to .requiresRelaunch (or .granted) without
// requiring the user to click anything.
public struct OnboardingView: View {
    @Bindable public var viewModel: PermissionViewModel
    public var onContinue: () -> Void

    public init(
        viewModel: PermissionViewModel,
        onContinue: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onContinue = onContinue
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Pixelbay")
                    .font(.largeTitle.bold())
                Text("Grant access so Pixelbay can record your screen, webcam, and audio.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    PermissionRowView(
                        kind: kind,
                        status: viewModel.statuses[kind] ?? .notDetermined,
                        onGrant: { Task { await viewModel.request(kind) } },
                        onOpenSettings: { Task { await viewModel.openSettings(for: kind) } }
                    )
                }
            }

            if viewModel.anyRequiresRelaunch {
                relaunchBanner
            }

            HStack {
                Spacer()
                Button("Continue") { onContinue() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.requiredSatisfied)
            }
        }
        .padding(40)
        .frame(minWidth: 540, minHeight: 480)
        .task {
            await viewModel.refresh()
            // Poll every 1.5s while visible so a Settings-side grant flips
            // the row without the user having to click "Re-check".
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { break }
                await viewModel.refresh()
            }
        }
    }

    private var relaunchBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Restart required")
                    .font(.headline)
                Text("Screen Recording was just granted. Pixelbay must relaunch to use it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit & Relaunch") {
                AppRelauncher.quitAndRelaunch()
            }
            .controlSize(.large)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PermissionRowView: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let onGrant: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            statusIcon
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.humanReadableName)
                    .font(.headline)
                Text(kind.rationale)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actionButton
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .requiresRelaunch:
            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
        case .notDetermined:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .granted:
            Text("Granted").foregroundStyle(.secondary)
        case .requiresRelaunch:
            Text("Relaunch needed").foregroundStyle(.orange)
        case .denied:
            Button("Open Settings", action: onOpenSettings)
        case .notDetermined:
            Button("Grant", action: onGrant)
        }
    }
}
#endif
