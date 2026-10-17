import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Semantic colors from DESIGN.md section 3 (the same tokens as the web
/// stylesheet), resolved for light and dark appearance.
public enum Brand {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #else
        return Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #endif
    }

    public static let background = dynamic(0xFEF8EA, 0x0E2444)
    public static let surface = dynamic(0xFFFDF7, 0x173354)
    public static let surfaceRaised = dynamic(0xFCEFD2, 0x214466)
    public static let text = dynamic(0x0E2444, 0xFCEFD2)
    public static let textMuted = dynamic(0x56616C, 0xB1CDDF)
    public static let border = dynamic(0x887861, 0x809BB0)
    public static let primary = dynamic(0x0E2444, 0xF8926E)
    public static let onPrimary = dynamic(0xFEF8EA, 0x0E2444)
    public static let link = dynamic(0xA43E28, 0xFFA887)
    public static let success = dynamic(0x0D3F2E, 0x9CD4B4)
    public static let warning = dynamic(0x795600, 0xF5BC2F)
    public static let danger = dynamic(0x9F3028, 0xFFB09E)
    public static let highlight = Color(hex: 0xF5BC2F)
    public static let onHighlight = Color(hex: 0x0E2444)

    /// Notebook identifying colors offered by the apps (same palette as the web).
    public static let notebookColors: [(hex: String, name: String)] = [
        ("#0e2444", "Navy"), ("#2f6f9f", "Blue"), ("#0d3f2e", "Green"), ("#5b3a8c", "Purple"),
        ("#a43e28", "Brick"), ("#c2185b", "Rose"), ("#f5bc2f", "Gold"), ("#887861", "Stone"),
    ]
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// `#RRGGBB`, or nil.
    init?(notebookHex: String?) {
        guard let text = notebookHex, text.hasPrefix("#"), text.count == 7, let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
        self.init(hex: value)
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// System / Light / Dark (section 3).
public enum ThemePreference: String, CaseIterable, Sendable {
    case system, light, dark
    public var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
    public var label: String { rawValue.capitalized }
}
