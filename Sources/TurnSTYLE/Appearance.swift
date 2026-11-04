import AppKit
import SwiftUI

/// One persisted preference drives SwiftUI, native menus, sheets and tooltip panels.
enum AppAppearance: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var scheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
    var native: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    @MainActor func apply() { NSApp.appearance = native }
}

/// Named adaptive surfaces keep source identity and contrast consistent in both modes.
enum AppPalette {
    static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 255) / 255,
                    green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
            })
    }
    static let text = color(0x16191F, 0xEBEBEB)
    static let secondary = color(0x626C79, 0xADADAD)
    static let chrome = color(0xF7F8FA, 0x191919)
    static let canvas = color(0xE9ECF1, 0x101010)
    static let surface = color(0xFFFFFF, 0x222222)
    static let header = color(0xEFF2F6, 0x2B2B2B)
    static let workingHeader = color(0xE5EEFC, 0x303030)
    static let border = color(0x98A4B5, 0x686868)
    static let grid = color(0xD8DFE8, 0x3D3D3D)
    static let blue = color(0x245FC2, 0xDEDEDE)
    // Prominent native buttons keep sufficient contrast with white labels.
    static let button = color(0x245FC2, 0x505050)
    static let codexRow = color(0xE8F2FE, 0x242424)
    static let claudeRow = color(0xFFF0E1, 0x292929)
    static let codexText = color(0x335E8A, 0xC5DFFF)
    static let claudeText = color(0x884E2C, 0xFFDBBA)
    static let approval = color(0x935113, 0xF4C27A)
    static let input = color(0x6256A5, 0xC1B6FA)
    static let ready = color(0x286B51, 0x8CD6B1)
    static let failed = color(0xA13D3B, 0xFFA7A4)
    static let running = color(0x326784, 0x97CCE9)
    static let errorSurface = color(0xFFE3DA, 0x502D2B)
    static let successSurface = color(0xE2F0E8, 0x253C33)
}
