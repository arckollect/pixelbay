import CoreGraphics

// Layout metrics — corner radii, spacing scale, stroke widths. Use these
// instead of magic numbers so the geometry reads consistently and a global
// tweak is one edit.

extension Theme {
    public enum Radius {
        public static let small: CGFloat = 4
        public static let medium: CGFloat = 8
        public static let large: CGFloat = 12
        public static let pill: CGFloat = 999
    }

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public enum Stroke {
        public static let hairline: CGFloat = 0.5
        public static let regular: CGFloat = 1
    }
}
