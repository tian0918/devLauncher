import AppKit
import SwiftUI

enum LauncherPreferences {
    static let showMenuBarExtraKey = "showMenuBarExtra"
}

enum ConsoleTypography {
    static let storageKey = "consoleFontSize"
    static let defaultSize: Double = 12
    static let minSize: Double = 10
    static let maxSize: Double = 20
    static let step: Double = 1

    static func clamp(_ value: Double) -> Double {
        min(max(value, minSize), maxSize)
    }
}

enum LauncherPalette {
    static let canvas = adaptive(0xF5F7FA, 0x1B2026, highContrastLight: 0xFFFFFF, highContrastDark: 0x12161A)
    static let surface = adaptive(0xFFFFFF, 0x252C34, highContrastLight: 0xFFFFFF, highContrastDark: 0x222931)
    static let surfaceSubtle = adaptive(0xF3F6FA, 0x1F252D, highContrastLight: 0xEDF1F7, highContrastDark: 0x191E25)
    static let surfaceHover = adaptive(0xEBF0F7, 0x2D3641, highContrastLight: 0xE2E9F2, highContrastDark: 0x35404D)

    static let line = adaptive(0xD8E0EA, 0x37424F, highContrastLight: 0x9AA8B8, highContrastDark: 0x677789)
    static let lineSubtle = adaptive(0xE6ECF4, 0x2E3843, highContrastLight: 0xB4C0CE, highContrastDark: 0x526173)

    // Neutral metadata badge tokens (kept distinct from interactive accent color per HIG)
    static let badgeInk = adaptive(0x4A5868, 0xB8C5D4, highContrastLight: 0x25313E, highContrastDark: 0xE2EAF2)
    static let badgeFill = adaptive(0xEDF1F6, 0x2B333D, highContrastLight: 0xE3E9F0, highContrastDark: 0x323C48)
    static let badgeEdge = adaptive(0xD5DEE8, 0x3D4957, highContrastLight: 0x96A5B7, highContrastDark: 0x68798C)

    // Interactive system accent helpers
    static let accentHover = Color(nsColor: NSColor(name: nil) { appearance in
        let base = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let target: NSColor = isDark ? .white : .black
        return base.blended(withFraction: 0.10, of: target) ?? base
    })

    static let accentLabel = Color(nsColor: NSColor(name: nil) { _ in
        let resolved = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor
        let luminance = 0.2126 * resolved.redComponent
            + 0.7152 * resolved.greenComponent
            + 0.0722 * resolved.blueComponent
        return luminance > 0.62
            ? NSColor(srgbRed: 0.10, green: 0.12, blue: 0.15, alpha: 1)
            : .white
    })

    // Semantic status tokens
    static let running = adaptive(0x1F6B49, 0x86D4A8, highContrastLight: 0x124E33, highContrastDark: 0xA5E8C1)
    static let runningFill = adaptive(0xE2F3EA, 0x223B31, highContrastLight: 0xD4EDE0, highContrastDark: 0x27473B)
    static let runningEdge = adaptive(0xBCE0CC, 0x355E4D, highContrastLight: 0x6CA888, highContrastDark: 0x5E9E82)

    static let pending = adaptive(0x8A5A19, 0xE5BE84, highContrastLight: 0x69420B, highContrastDark: 0xF3D3A2)
    static let pendingFill = adaptive(0xF8EFE1, 0x3C3224, highContrastLight: 0xF3E4CE, highContrastDark: 0x473B29)
    static let pendingEdge = adaptive(0xE7D3B5, 0x5A4932, highContrastLight: 0xB5905B, highContrastDark: 0x8C734F)

    static let stop = adaptive(0x9C3540, 0xF5A8AA, highContrastLight: 0x7A1E28, highContrastDark: 0xFFC2C4)
    static let stopFill = adaptive(0xF8E7E9, 0x452C32, highContrastLight: 0xF3D8DC, highContrastDark: 0x52333A)
    static let stopFillHover = adaptive(0xF2D7DB, 0x54353C, highContrastLight: 0xEBC2C8, highContrastDark: 0x633E47)
    static let stopEdge = adaptive(0xE6C3C8, 0x6B444C, highContrastLight: 0xB87A83, highContrastDark: 0x9E6873)

    static let warning = adaptive(0x995813, 0xECBA78, highContrastLight: 0x733F06, highContrastDark: 0xF8D19B)
    static let warningFill = adaptive(0xFCF2E4, 0x3A3022, highContrastLight: 0xF7E5CC, highContrastDark: 0x463927)
    static let warningEdge = adaptive(0xEBD4B5, 0x5C4830, highContrastLight: 0xB89260, highContrastDark: 0x8F724D)

    // Language & Git sync badges
    static let nodeInk = adaptive(0x276849, 0x8AD0A6, highContrastLight: 0x164B32, highContrastDark: 0xA8E5C0)
    static let nodeFill = adaptive(0xE4F2EB, 0x233930, highContrastLight: 0xD5EBDF, highContrastDark: 0x29453A)
    static let nodeEdge = adaptive(0xC6E1D3, 0x355647, highContrastLight: 0x7BB095, highContrastDark: 0x5D947B)

    static let pythonInk = adaptive(0x305B84, 0x8EBBE6, highContrastLight: 0x1D4163, highContrastDark: 0xB0D4F5)
    static let pythonFill = adaptive(0xE3EEF8, 0x233547, highContrastLight: 0xD3E4F4, highContrastDark: 0x2A4057)
    static let pythonEdge = adaptive(0xC4DAEE, 0x36506B, highContrastLight: 0x7B9FC2, highContrastDark: 0x5E88B3)

    static let pushInk = adaptive(0x52479E, 0xBEB7F2, highContrastLight: 0x392E7D, highContrastDark: 0xD5D0FA)
    static let pushFill = adaptive(0xECEAF9, 0x2E2B46, highContrastLight: 0xDFDCF5, highContrastDark: 0x383457)
    static let pushEdge = adaptive(0xD2CEF0, 0x48436E, highContrastLight: 0x958EC9, highContrastDark: 0x746CA8)

    // Console dark surface tokens
    static let consoleBody = Color(nsColor: rgb(0x1C222A))
    static let consoleHeader = Color(nsColor: rgb(0x242C36))
    static let consoleLine = Color(nsColor: rgb(0x343F4D))
    static let consoleBorder = adaptive(0xC8D3E0, 0x3A4654, highContrastLight: 0x8F9FB2, highContrastDark: 0x68798C)
    static let consoleText = rgb(0xE0E7F1)
    static let consoleMuted = rgb(0x94A3B8)
    static let consoleActionHover = Color.white.opacity(0.10)
    static let consoleErrorFill = Color(nsColor: rgb(0x38262B))
    static let consoleErrorInk = Color(nsColor: rgb(0xF6BDBE))
    static let consoleInfoFill = Color(nsColor: rgb(0x25303D))

    static func cardShadow(_ scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> Color {
        guard contrast == .standard else { return .clear }
        return Color.black.opacity(scheme == .dark ? 0.20 : 0.035)
    }

    static func sidebarRowFill(
        selected: Bool,
        hovering: Bool,
        focused: Bool,
        appearsActive: Bool,
        scheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> Color {
        if selected {
            if appearsActive && focused {
                let baseOpacity = scheme == .dark ? 0.24 : 0.15
                return Color.accentColor.opacity(contrast == .increased ? baseOpacity + 0.08 : baseOpacity)
            }
            let unfocusedOpacity = scheme == .dark ? 0.13 : 0.085
            return Color.primary.opacity(contrast == .increased ? unfocusedOpacity + 0.06 : unfocusedOpacity)
        }
        if hovering {
            return Color.primary.opacity(scheme == .dark ? 0.06 : 0.045)
        }
        return .clear
    }

    static func sidebarRowBorder(
        selected: Bool,
        focused: Bool,
        appearsActive: Bool,
        contrast: ColorSchemeContrast
    ) -> Color {
        guard selected else { return .clear }
        if appearsActive && focused {
            return Color.accentColor.opacity(contrast == .increased ? 0.65 : 0.36)
        }
        return Color.primary.opacity(contrast == .increased ? 0.28 : 0.10)
    }

    private static func adaptive(
        _ light: UInt32,
        _ dark: UInt32,
        highContrastLight: UInt32? = nil,
        highContrastDark: UInt32? = nil
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastAqua,
                .darkAqua,
                .aqua,
            ])
            switch match {
            case .accessibilityHighContrastDarkAqua:
                return rgb(highContrastDark ?? dark)
            case .accessibilityHighContrastAqua:
                return rgb(highContrastLight ?? light)
            case .darkAqua:
                return rgb(dark)
            default:
                return rgb(light)
            }
        })
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
