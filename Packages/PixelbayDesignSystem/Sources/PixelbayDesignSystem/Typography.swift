import SwiftUI

// Semantic type scale. SF Pro Display for large display/title sizes, SF Pro
// Text (the system default) for body/caption, SF Mono for timecodes and
// numeric readouts. Use these instead of `.font(.headline)` etc. so weight and
// size stay consistent across surfaces.

extension Theme {
    public enum Font {
        /// 34pt bold — onboarding/welcome hero.
        public static let displayTitle = SwiftUI.Font.system(size: 34, weight: .bold, design: .default)
        /// 34pt heavy — hero titles that need extra presence (Scene Recording header).
        public static let displayTitleHeavy = SwiftUI.Font.system(size: 34, weight: .heavy, design: .default)
        /// 24pt bold — page/window titles (Scenes header, New Recording).
        public static let pageTitle = SwiftUI.Font.system(size: 24, weight: .bold, design: .default)
        /// 17pt semibold — section titles inside panes.
        public static let sectionTitle = SwiftUI.Font.system(size: 17, weight: .semibold, design: .default)
        /// 13pt semibold — card titles, inspector group headers.
        public static let cardTitle = SwiftUI.Font.system(size: 13, weight: .semibold, design: .default)
        /// 13pt regular — body text.
        public static let body = SwiftUI.Font.system(size: 13, weight: .regular, design: .default)
        /// 13pt medium — emphasized body.
        public static let bodyEmphasized = SwiftUI.Font.system(size: 13, weight: .medium, design: .default)
        /// 11pt regular — captions, secondary labels.
        public static let caption = SwiftUI.Font.system(size: 11, weight: .regular, design: .default)
        /// 11pt monospaced — inline timecodes / numeric values in inspectors.
        public static let monoTimecode = SwiftUI.Font.system(size: 11, weight: .regular, design: .monospaced)
        /// 16pt monospaced medium — prominent transport / HUD timecode.
        public static let monoTimecodeLarge = SwiftUI.Font.system(size: 16, weight: .medium, design: .monospaced)
    }
}
