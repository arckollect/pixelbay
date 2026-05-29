#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import Observation
import PixelbayDesignSystem

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
        ZStack {
            Theme.Color.bgBase.ignoresSafeArea()
            VStack(spacing: Theme.Spacing.xl) {
                hero
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(PermissionKind.allCases, id: \.self) { kind in
                        PermissionRowView(
                            kind: kind,
                            status: viewModel.statuses[kind] ?? .notDetermined,
                            onGrant: { Task { await viewModel.request(kind) } },
                            onOpenSettings: { Task { await viewModel.openSettings(for: kind) } }
                        )
                    }
                }
                .frame(maxWidth: 520)

                if viewModel.anyRequiresRelaunch {
                    relaunchBanner
                        .frame(maxWidth: 520)
                }

                Spacer(minLength: 0)
                ctaSection
                    .frame(maxWidth: 520)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, Theme.Spacing.xxl)
        }
        .frame(minWidth: 560, minHeight: 560)
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

    private var hero: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Welcome to Pixelbay")
                .font(Theme.Font.displayTitle)
                .foregroundStyle(Theme.Color.textPrimary)
            Text("Grant access so Pixelbay can record your screen, webcam, and audio.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.lg)
    }

    @ViewBuilder
    private var ctaSection: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Button("Continue") { onContinue() }
                .buttonStyle(.pbPrimary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.requiredSatisfied)
            if !viewModel.requiredSatisfied {
                Text("Grant the required permissions above to continue.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
        }
    }

    private var relaunchBanner: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.Color.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Restart required")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Screen Recording was just granted. Pixelbay must relaunch to use it.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
            Button("Quit & Relaunch") {
                AppRelauncher.quitAndRelaunch()
            }
            .buttonStyle(.pbSecondary)
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Color.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.large))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .strokeBorder(Theme.Color.warning.opacity(0.35), lineWidth: Theme.Stroke.hairline)
        )
    }
}

private struct PermissionRowView: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let onGrant: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            iconBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.humanReadableName)
                    .font(Theme.Font.bodyEmphasized)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(kind.rationale)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actionButton
                .transition(.asymmetric(
                    insertion: .scale.combined(with: .opacity),
                    removal: .opacity
                ))
        }
        .pbCard(elevated: true, padding: Theme.Spacing.md)
        .animation(.smooth, value: status)
    }

    /// SF Symbol for the permission, on a tinted circle whose colour
    /// reflects the current status (accent until acted on, green/red/amber
    /// once resolved).
    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.18))
                .frame(width: 36, height: 36)
            Image(systemName: symbolName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(statusColor)
        }
    }

    private var symbolName: String {
        switch kind {
        case .screenRecording: return "rectangle.inset.filled.badge.record"
        case .camera: return "camera.fill"
        case .microphone: return "mic.fill"
        case .accessibility: return "hand.tap.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .granted: return Theme.Color.success
        case .denied: return Theme.Color.danger
        case .requiresRelaunch: return Theme.Color.warning
        case .notDetermined: return Theme.Color.accent
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .granted:
            Label("Granted", systemImage: "checkmark")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.success)
        case .requiresRelaunch:
            Text("Relaunch needed")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.warning)
        case .denied:
            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.pbSecondary)
        case .notDetermined:
            Button("Grant", action: onGrant)
                .buttonStyle(.pbPrimary)
        }
    }
}
#endif
