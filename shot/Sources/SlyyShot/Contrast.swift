import AppKit

// WCAG 2 relative luminance and contrast ratio, as in
// https://www.accessibility-developer-guide.com/knowledge/colours-and-contrast/how-to-calculate/
// Used by the Number tool: the digit on a colored badge is black or white,
// whichever contrasts more with the badge color.

extension NSColor {
    /// Relative luminance L (0 = black, 1 = white) of the color in sRGB.
    /// Per channel: c = value 0…1; linear = c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)^2.4;
    /// L = 0.2126 R + 0.7152 G + 0.0722 B. Alpha ignored (badges are opaque).
    var relativeLuminance: CGFloat {
        // Color well may hand out P3, generic, gray or catalog colors: compare in sRGB.
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        func linear(_ v: CGFloat) -> CGFloat {
            let v = min(max(v, 0), 1) // extended-range sRGB (P3 colors) can leave 0…1
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    /// Contrast ratio (1…21) between two luminances: (L_lighter + 0.05) / (L_darker + 0.05).
    static func contrastRatio(_ l1: CGFloat, _ l2: CGFloat) -> CGFloat {
        (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// WCAG AA minimum for large text (>= 14 pt bold); badge digits are always that (Thin = 14.4 pt bold).
    static let largeTextMinimum: CGFloat = 3

    /// White or black text on this color. White wins whenever it reaches AA for large text (3:1,
    /// i.e. L <= ~0.30: red, system blue, magenta, mid grey), even if black would contrast a bit more;
    /// below that, the higher contrast wins (black on orange, green, yellow, white).
    var contrastingTextColor: NSColor {
        let l = relativeLuminance
        let white = Self.contrastRatio(l, 1)
        return white >= Self.largeTextMinimum || white >= Self.contrastRatio(l, 0) ? .white : .black
    }
}
