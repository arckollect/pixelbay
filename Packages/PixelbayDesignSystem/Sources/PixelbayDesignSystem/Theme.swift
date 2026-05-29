import SwiftUI
import AppKit

// Pixelbay design tokens.
//
// One file, two parallel namespaces — `Theme.Color` for SwiftUI and
// `Theme.NSColor` for AppKit/CALayer (the timeline lives in AppKit). Both
// derive from the same hex literals defined in `Palette` below, so the two
// sides never drift: edit a hex once and both namespaces follow.
//
// PALETTE TONE — the whole app's tone is the `Palette` enum below. To retone
// (e.g. warm neutral → neutral graphite → cool slate) edit those hex strings
// and nothing else. The starting palette is "warm neutral".
//
// UPGRADE PATH — these are static `enum` tokens, so they do NOT react to a
// runtime palette switch. If a Settings palette toggle is ever wanted, refactor
// `Palette` into an `@Observable ThemeProvider` injected through the
// environment and read these tokens from it. Until then static is simpler and
// the app is dark-locked, so there's nothing to react to.

public enum Theme {}

// MARK: - Palette (the single retoning surface)

extension Theme {
    /// Raw hex literals — the one place to change the app's tone.
    /// Alternatives noted inline (neutral graphite / cool slate).
    enum Palette {
        // Surfaces — warm neutral. Graphite: 1E1E1E/181818/2A2A2A. Slate: 1A1D21/141619/24282E.
        static let bgBase      = "#262624"
        static let bgDeep      = "#1F1F1E"
        static let bgElevated  = "#2F2F2D"
        static let bgInsetCard = "#222220"

        // Borders
        static let borderSubtle = "#3A3A37"
        static let borderStrong = "#4A4A46"

        // Text
        static let textPrimary   = "#F0EFE6"
        static let textSecondary = "#B8B5A8"
        static let textTertiary  = "#83817A"

        // Accent + status
        static let accent       = "#D97757"
        static let accentMuted  = "#A85C42"
        static let success      = "#7FB069"
        static let warning      = "#E0A458"
        static let danger       = "#D96A5B"
        static let recordingRed = "#E5484D"

        // Track roles (timeline lanes). Tuned to read on the dark surfaces
        // while keeping the original hue semantics (video=blue, mic=green…).
        static let trackVideo       = "#5B8DEF"
        static let trackWebcam      = "#46C3C9"
        static let trackMic         = "#6FBF73"
        static let trackSystemAudio = "#54C7A0"
        static let trackVoiceover   = "#E0A458"
        static let trackOverlay     = "#9D7CD8"
        static let trackEffects     = "#E06C9F"

        // Effect-keyframe roles
        static let effectZoomAuto   = "#E3C04B"
        static let effectZoomManual = "#56C2D6"
        static let effectTalkingHead = "#7C83D8"

        // Timeline chrome
        static let timelineRuler    = "#1A1A19"
        static let timelinePlayhead = "#D97757"
        static let waveformFill     = "#8A887E"
    }
}

// MARK: - SwiftUI Color tokens

extension Theme {
    public enum Color {
        // Surfaces
        public static let bgBase      = SwiftUI.Color(hex: Palette.bgBase)
        public static let bgDeep      = SwiftUI.Color(hex: Palette.bgDeep)
        public static let bgElevated  = SwiftUI.Color(hex: Palette.bgElevated)
        public static let bgInsetCard = SwiftUI.Color(hex: Palette.bgInsetCard)

        // Borders
        public static let borderSubtle = SwiftUI.Color(hex: Palette.borderSubtle)
        public static let borderStrong = SwiftUI.Color(hex: Palette.borderStrong)

        // Text
        public static let textPrimary   = SwiftUI.Color(hex: Palette.textPrimary)
        public static let textSecondary = SwiftUI.Color(hex: Palette.textSecondary)
        public static let textTertiary  = SwiftUI.Color(hex: Palette.textTertiary)

        // Accent + status
        public static let accent       = SwiftUI.Color(hex: Palette.accent)
        public static let accentMuted  = SwiftUI.Color(hex: Palette.accentMuted)
        public static let success      = SwiftUI.Color(hex: Palette.success)
        public static let warning      = SwiftUI.Color(hex: Palette.warning)
        public static let danger       = SwiftUI.Color(hex: Palette.danger)
        public static let recordingRed = SwiftUI.Color(hex: Palette.recordingRed)

        // Track roles
        public static let trackVideo       = SwiftUI.Color(hex: Palette.trackVideo)
        public static let trackWebcam      = SwiftUI.Color(hex: Palette.trackWebcam)
        public static let trackMic         = SwiftUI.Color(hex: Palette.trackMic)
        public static let trackSystemAudio = SwiftUI.Color(hex: Palette.trackSystemAudio)
        public static let trackVoiceover   = SwiftUI.Color(hex: Palette.trackVoiceover)
        public static let trackOverlay     = SwiftUI.Color(hex: Palette.trackOverlay)
        public static let trackEffects     = SwiftUI.Color(hex: Palette.trackEffects)

        // Timeline chrome
        public static let timelineRuler    = SwiftUI.Color(hex: Palette.timelineRuler)
        public static let timelinePlayhead = SwiftUI.Color(hex: Palette.timelinePlayhead)
        public static let waveformFill     = SwiftUI.Color(hex: Palette.waveformFill)
    }
}

// MARK: - AppKit NSColor tokens

extension Theme {
    public enum NSColor {
        // Surfaces
        public static let bgBase      = AppKit.NSColor(hex: Palette.bgBase)
        public static let bgDeep      = AppKit.NSColor(hex: Palette.bgDeep)
        public static let bgElevated  = AppKit.NSColor(hex: Palette.bgElevated)
        public static let bgInsetCard = AppKit.NSColor(hex: Palette.bgInsetCard)

        // Borders
        public static let borderSubtle = AppKit.NSColor(hex: Palette.borderSubtle)
        public static let borderStrong = AppKit.NSColor(hex: Palette.borderStrong)

        // Text
        public static let textPrimary   = AppKit.NSColor(hex: Palette.textPrimary)
        public static let textSecondary = AppKit.NSColor(hex: Palette.textSecondary)
        public static let textTertiary  = AppKit.NSColor(hex: Palette.textTertiary)

        // Accent + status
        public static let accent       = AppKit.NSColor(hex: Palette.accent)
        public static let accentMuted  = AppKit.NSColor(hex: Palette.accentMuted)
        public static let success      = AppKit.NSColor(hex: Palette.success)
        public static let warning      = AppKit.NSColor(hex: Palette.warning)
        public static let danger       = AppKit.NSColor(hex: Palette.danger)
        public static let recordingRed = AppKit.NSColor(hex: Palette.recordingRed)

        // Track roles
        public static let trackVideo       = AppKit.NSColor(hex: Palette.trackVideo)
        public static let trackWebcam      = AppKit.NSColor(hex: Palette.trackWebcam)
        public static let trackMic         = AppKit.NSColor(hex: Palette.trackMic)
        public static let trackSystemAudio = AppKit.NSColor(hex: Palette.trackSystemAudio)
        public static let trackVoiceover   = AppKit.NSColor(hex: Palette.trackVoiceover)
        public static let trackOverlay     = AppKit.NSColor(hex: Palette.trackOverlay)
        public static let trackEffects     = AppKit.NSColor(hex: Palette.trackEffects)

        // Effect-keyframe roles
        public static let effectZoomAuto    = AppKit.NSColor(hex: Palette.effectZoomAuto)
        public static let effectZoomManual  = AppKit.NSColor(hex: Palette.effectZoomManual)
        public static let effectTalkingHead = AppKit.NSColor(hex: Palette.effectTalkingHead)

        // Timeline chrome
        public static let timelineRuler    = AppKit.NSColor(hex: Palette.timelineRuler)
        public static let timelinePlayhead = AppKit.NSColor(hex: Palette.timelinePlayhead)
        public static let waveformFill     = AppKit.NSColor(hex: Palette.waveformFill)
    }
}
