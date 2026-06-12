import SwiftUI
import AppKit

/// A color that resolves to `lightHex`/`darkHex` per the current appearance.
extension Color {
    init(lightHex: String, darkHex: String) {
        let ns = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? darkHex : lightHex)
        }
        self = Color(nsColor: ns)
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1)
    }
}

/// The "calm private recording studio" palette from the signed-off mockup
/// (docs/design/hub-mockup.html): warm paper, ember accent that echoes the
/// recording dot, New York serif for display text. Every color adapts to
/// light/dark.
enum Palette {
    static let pane     = Color(lightHex: "F3EFEA", darkHex: "1B1813")
    static let pane2    = Color(lightHex: "ECE7E0", darkHex: "211D18")
    static let card     = Color(lightHex: "FFFFFF", darkHex: "26211B")
    static let ink      = Color(lightHex: "221F1B", darkHex: "F1ECE4")
    static let inkSoft  = Color(lightHex: "5B554C", darkHex: "C3BBAE")
    static let muted    = Color(lightHex: "938B7E", darkHex: "897F70")
    static let ember    = Color(lightHex: "CF4F27", darkHex: "F4703F")
    static let gold     = Color(lightHex: "B6863A", darkHex: "D8A851")
    static let raw      = Color(lightHex: "B3A89A", darkHex: "6F6657")

    static var hair: Color { ink.opacity(0.10) }
    static var hairStrong: Color { ink.opacity(0.16) }
    static var emberSoft: Color { ember.opacity(0.13) }
    static var sel: Color { ember.opacity(0.12) }
}

/// New York (Apple's system serif) for display text — native, no font bundling,
/// and the warm editorial voice the mockup's Fraunces stood in for.
enum Typo {
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
