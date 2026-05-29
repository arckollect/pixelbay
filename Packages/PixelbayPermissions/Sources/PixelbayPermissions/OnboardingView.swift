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

// MARK: - Onboarding tone
//
// This scene established the app's visual language (Figma Frame 4, file
// pVbhIXw3Pkv1ZGWPRbF9Yy): a neutral near-black surface that fills the whole
// window, lighter neutral rows, a system-blue accent. The app-wide `Theme`
// palette was since retoned to match, so `Tone` is now a thin, onboarding-local
// alias over the shared tokens (plus the white-opacity text ramp this screen
// uses) rather than a departure from them.
private enum Tone {
    // Surfaces + accent now derive from the shared design tokens — the app-wide
    // Theme palette was retoned to this same neutral graphite + system-blue
    // language, so onboarding and the rest of the app share one source of truth.
    static let bg        = Theme.Color.bgBase     // #181818
    static let row       = Theme.Color.bgElevated // #282828
    static let title     = Color.white
    static let subtitle  = Color.white.opacity(0.55)
    static let rowBody   = Color.white.opacity(0.50)
    static let granted   = Color.white.opacity(0.45)
    static let accent     = Theme.Color.accent
    static let accentText = Color.white
    static let accentBg   = Theme.Color.accent.opacity(0.16)
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
            // Full-bleed neutral surface — the window *is* the card.
            Tone.bg.ignoresSafeArea()

            VStack(spacing: 26) {
                hero

                VStack(spacing: 14) {
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

                ctaSection
                    .padding(.top, 8)
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 48)
            .padding(.vertical, 56)
        }
        .frame(minWidth: 660, minHeight: 680)
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
        VStack(spacing: 20) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Welcome to Pixelbay")
                    .font(.system(size: 42, weight: .heavy, design: .rounded))
                    .foregroundStyle(Tone.title)
                    .multilineTextAlignment(.center)
                Text("Grant access so Pixelbay can record your screen, webcam, and audio.")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(Tone.subtitle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var ctaSection: some View {
        VStack(spacing: 10) {
            CaptureContinueButton(
                disabled: !viewModel.requiredSatisfied,
                action: onContinue
            )
            .keyboardShortcut(.defaultAction)

            if !viewModel.requiredSatisfied {
                Text("Grant the required permissions above to continue.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(Tone.rowBody)
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
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Tone.title)
                Text("Screen Recording was just granted. Pixelbay must relaunch to use it.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(Tone.subtitle)
            }
            Spacer()
            Button("Quit & Relaunch") {
                AppRelauncher.quitAndRelaunch()
            }
            .buttonStyle(.pbSecondary)
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Color.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
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
        HStack(spacing: 14) {
            iconBadge
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.humanReadableName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Tone.title)
                Text(kind.rationale)
                    .font(.system(size: 11.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Tone.rowBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            actionButton
                .transition(.asymmetric(
                    insertion: .scale.combined(with: .opacity),
                    removal: .opacity
                ))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(minHeight: 68)
        .background(Tone.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.smooth, value: status)
    }

    /// SF Symbol for the permission on a quiet neutral circle. The badge stays
    /// monochrome regardless of status — premium over loud colour — and the
    /// trailing action/label carries the status instead. Denied is the one
    /// exception: it tints to draw the eye toward the fix.
    private var iconBadge: some View {
        let tint = (status == .denied) ? Theme.Color.danger : Tone.accent
        let bg = (status == .denied) ? Theme.Color.danger.opacity(0.16) : Tone.accentBg
        return ZStack {
            Circle()
                .fill(bg)
                .frame(width: 38, height: 38)
            Image(systemName: symbolName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
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

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .granted:
            Label("Granted", systemImage: "checkmark")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(Tone.granted)
        case .requiresRelaunch:
            Text("Relaunch needed")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
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

// MARK: - Animated "capture" Continue button
//
// Borrows the layered, hover-reactive feel of the Uiverse "documents" button
// but reworks it around a camera: on hover the camera face tilts forward and a
// freshly-captured frame slides up from behind it — reading as a screen
// capture. Pressing dips the whole control (scale 0.95). Disabled, dimmed, and
// motion-frozen while required permissions are still outstanding.
private struct CaptureContinueButton: View {
    var disabled: Bool
    var action: () -> Void

    @State private var hovering = false

    private var active: Bool { hovering && !disabled }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ApertureIcon(active: active)
                    .frame(width: 24, height: 24)
                Text("Continue")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Tone.accentText)
            }
            .padding(.horizontal, 22)
            .frame(height: 48)
            .frame(minWidth: 210)
            .background(glassTile)
        }
        .buttonStyle(PressableScaleButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: active)
    }

    /// Premium dark "Liquid Glass" tile: an elevated near-black surface lit by
    /// two key-lights glinting off the top-left and bottom-right corners — the
    /// rest of the rim falls into shadow. Same beveled-glass read as the
    /// app-icon tile. Hover lifts the corner glints, sheen, and shadow together.
    private var glassTile: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return shape
            // Elevated dark base.
            .fill(Color(red: 0.145, green: 0.145, blue: 0.155))
            // Very subtle face sheen so it isn't dead flat.
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.06), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
            )
            // Faint full rim for edge definition in the shadowed stretches.
            .overlay(shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
            // Two corner key-lights: top-left and bottom-right glints.
            .overlay(cornerGlint(.topLeading, shape: shape))
            .overlay(cornerGlint(.bottomTrailing, shape: shape))
            .compositingGroup()
            .shadow(color: .black.opacity(0.55), radius: active ? 16 : 9, y: active ? 8 : 4)
    }

    /// A bright rim segment radiating from one corner and fading toward the
    /// centre — masking the full-perimeter stroke down to a single glint.
    private func cornerGlint(_ corner: UnitPoint, shape: RoundedRectangle) -> some View {
        shape
            .strokeBorder(Color.white.opacity(active ? 0.98 : 0.78), lineWidth: 1.2)
            .mask(
                RadialGradient(
                    gradient: Gradient(colors: [.white, .white.opacity(0)]),
                    center: corner,
                    startRadius: 0,
                    endRadius: active ? 52 : 42
                )
            )
    }
}

/// A camera-aperture iris built from overlapping blades. At rest it sits at a
/// comfortable f-stop; on hover the blades swing inward and swirl, tightening
/// the opening — a "pull focus" gesture. Echoes the app-icon aperture mark.
/// White blades on the accent CTA; the opening lets the blue show through as
/// the iris centre.
private struct ApertureIcon: View {
    var active: Bool

    private let bladeCount = 6
    private let bladeLength: CGFloat = 8
    private let bladeThickness: CGFloat = 3.5
    // Tangential lean gives the blades their pinwheel/iris cant rather than
    // pointing straight at the centre like spokes.
    private let bladeLean: CGFloat = 2.2

    // Centre-to-blade-midpoint distance. Smaller = tighter opening (focused).
    private var reach: CGFloat { active ? 4.5 : 6 }
    private var spin: Double { active ? -24 : 0 }

    var body: some View {
        ZStack {
            // Faint lens ring framing the iris.
            Circle()
                .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                .frame(width: 23, height: 23)

            ForEach(0..<bladeCount, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: bladeThickness, height: bladeLength)
                    .offset(x: bladeLean, y: -reach)
                    .rotationEffect(.degrees(Double(i) / Double(bladeCount) * 360 + spin))
            }
        }
        .frame(width: 24, height: 24)
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: active)
    }
}

/// Press-to-dip scaling, matching the Uiverse button's `:active` transform.
private struct PressableScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
#endif
