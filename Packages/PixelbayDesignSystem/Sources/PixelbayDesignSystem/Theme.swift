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
// (e.g. neutral graphite → warm neutral → cool slate) edit those hex strings
// and nothing else. The current palette is "Neutral graphite + system blue"
// for the chrome — near-black surfaces, white-led text, a system-blue accent
// used sparingly, monochrome status (blue = info, red = error/record) — with
// full-spectrum SEMANTIC hues for the timeline lanes (video blue, voice
// green, system-audio teal, camera pink, narration amber, effects violet).
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
        // Surfaces — neutral graphite (matches onboarding Tone: bg #181818,
        // row #282828). The warm variant was 262624/1F1F1E/2F2F2D/222220.
        // The deep→base→elevated ladder is deliberately wider than the old
        // 12/18/28 ramp so panes read as distinct depth planes: the preview
        // canvas and timeline sit in a visibly deeper well than the chrome.
        static let bgBase      = "#181818"   // primary window background (== Tone.bg)
        static let bgDeep      = "#101010"   // deepest: preview canvas, timeline well, inspector pane
        static let bgElevated  = "#282828"   // raised surfaces / cards / secondary buttons (== Tone.row)
        static let bgInsetCard = "#1F1F1F"   // card interiors

        // Borders — neutral. `borderStrong` marks interactive edges (drag
        // handles, focused chrome) so it carries more contrast than the old
        // #3D3D3D.
        static let borderSubtle = "#2E2E2E"
        static let borderStrong = "#454545"

        // Text — white-led neutral (matches onboarding white / white-opacity).
        // Secondary sits at ~62% white for comfortable long-form legibility
        // on the graphite surfaces (the old #9A9A9A read muddy on bgDeep).
        static let textPrimary   = "#FFFFFF"
        static let textSecondary = "#A3A3A3"
        static let textTertiary  = "#737373"

        // Accent + status — system blue accent; monochrome status (blue = info /
        // affirmative, red = error / record). No green or amber (see onboarding:
        // "Granted" is neutral, only denial/danger tints).
        static let accent       = "#0A84FF"   // macOS dark system blue
        static let accentMuted  = "#0A6FD8"
        static let success      = "#0A84FF"   // was green; now informational blue
        static let warning      = "#0A84FF"   // was amber; caution now via icon + copy
        static let danger       = "#FF453A"   // macOS system red
        static let recordingRed = "#FF453A"

        // Track roles (timeline lanes) — full-spectrum semantic hues, the
        // NLE convention (FCP / Premiere): video = blue, human audio =
        // green, system audio = teal, camera = pink, narration = amber,
        // effects = violet. Each lane is instantly tellable apart even as
        // the timeline's soft translucent tints (low alpha collapses close
        // hues into one). The earlier "cool sweep only" restriction is
        // deliberately lifted.
        static let trackVideo       = "#3B82F6"   // blue (screen)
        static let trackWebcam      = "#F472B6"   // pink (person/camera)
        static let trackMic         = "#34D399"   // emerald (voice)
        static let trackSystemAudio = "#2DD4BF"   // teal (machine audio)
        static let trackVoiceover   = "#FBBF24"   // amber (narration)
        static let trackOverlay     = "#60A5FA"   // light blue
        static let trackEffects     = "#A78BFA"   // violet

        // Effect-keyframe roles — VIVID purple→fuchsia (the timeline's most
        // saturated hues on purpose: zoom keyframes are small badges that
        // should read as the liveliest thing on the effects lane, not recede
        // like the translucent clip bodies). Auto = purple, manual = fuchsia
        // so the two are unmistakable; both distinct from the blue video lane.
        static let effectZoomAuto   = "#A855F7"   // vivid purple (auto)
        static let effectZoomManual = "#E24BE0"   // vivid fuchsia (manual / hotkey)
        static let effectTalkingHead = "#8B5CF6"  // violet

        // Timeline chrome
        static let timelineRuler    = "#101010"   // == bgDeep so the ruler fuses with the timeline well
        static let timelinePlayhead = "#FFFFFF"   // white + dark halo → pops over ANY clip content (light thumbnails or dark lanes); blue blended into the cool clips
        static let waveformFill     = "#FFFFFF"   // bright white waveform (pops on the colored audio clip, like pro editors)
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

        // Effect-keyframe roles (mirror of the NSColor tokens below)
        public static let effectZoomAuto    = SwiftUI.Color(hex: Palette.effectZoomAuto)
        public static let effectZoomManual  = SwiftUI.Color(hex: Palette.effectZoomManual)
        public static let effectTalkingHead = SwiftUI.Color(hex: Palette.effectTalkingHead)

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
