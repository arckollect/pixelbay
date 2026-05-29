import SwiftUI
import AppKit

// Hex initializers shared by both colour namespaces (`Theme.Color` and
// `Theme.NSColor`) so a single literal like "#262624" stays the canonical
// source for both the SwiftUI and AppKit sides of a token. Keeping the two
// parallel namespaces in sync depends on these going through the same parse.
//
// Accepts "#RGB", "#RGBA", "#RRGGBB", "#RRGGBBAA" (leading "#" optional).
// Unparseable strings fall back to opaque magenta so a typo is loud, not silent.

extension Color {
    init(hex: String) {
        let (r, g, b, a) = hexComponents(hex)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let (r, g, b, a) = hexComponents(hex)
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

private func hexComponents(_ hex: String) -> (Double, Double, Double, Double) {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }

    // Expand shorthand (RGB / RGBA → RRGGBB / RRGGBBAA).
    if s.count == 3 || s.count == 4 {
        s = s.map { "\($0)\($0)" }.joined()
    }

    guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else {
        // Loud fallback — opaque magenta — so an invalid hex is obvious on screen.
        return (1, 0, 1, 1)
    }

    if s.count == 6 {
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        return (r, g, b, 1)
    } else {
        let r = Double((value & 0xFF00_0000) >> 24) / 255
        let g = Double((value & 0x00FF_0000) >> 16) / 255
        let b = Double((value & 0x0000_FF00) >> 8) / 255
        let a = Double(value & 0x0000_00FF) / 255
        return (r, g, b, a)
    }
}
