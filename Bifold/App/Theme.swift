//
//  Theme.swift
//  Bifold
//
//  Semantic colour tokens in the Redfern's Outpost component style. Bifold's
//  family is cooler than Tinbox's: glacier blue by default, with a leather
//  "Wallet" theme for the namesake.
//

import SwiftUI

enum ThemeName: String, CaseIterable, Codable, Identifiable {
    case slate = "Slate"
    case wallet = "Wallet"
    case hinge = "Hinge"
    case fern = "Fern"
    case plum = "Plum"
    var id: String { rawValue }

    var tagline: String {
        switch self {
        case .slate: return "Glacier blue on cool slate"
        case .wallet: return "Worn leather and brass"
        case .hinge: return "Brushed silver, like the shell"
        case .fern: return "Deep green undergrowth"
        case .plum: return "Magenta on midnight"
        }
    }
}

struct ThemeTokens: Equatable {
    let name: ThemeName

    let accent: Color
    let accentText: Color
    let accentText2: Color
    let tint: Color
    let tint2: Color
    let tint3: Color
    let tintBorder: Color
    let tintBorder2: Color
    let badge: Color
    let stripe: Color
    let stripe2: Color

    let bg: Color
    let sheet: Color
    let card: Color
    let well: Color
    let chip: Color
    let secondaryButton: Color
    let trackOff: Color

    /// Builds a full token set from an accent and a background family. Accent
    /// text is a lighter tint of the accent so it stays legible on dark cards.
    static func make(name: ThemeName, accent: UInt32, accentText: UInt32, accentText2: UInt32,
                     badge: (Int, Int, Int), bg: UInt32, sheet: UInt32, card: UInt32, well: UInt32,
                     chip: UInt32, button: UInt32) -> ThemeTokens {
        let r = Int((accent >> 16) & 0xFF), g = Int((accent >> 8) & 0xFF), b = Int(accent & 0xFF)
        return ThemeTokens(
            name: name,
            accent: Color(hex: accent),
            accentText: Color(hex: accentText),
            accentText2: Color(hex: accentText2),
            tint: Color(rgba: r, g, b, 0.16),
            tint2: Color(rgba: r, g, b, 0.22),
            tint3: Color(rgba: r, g, b, 0.12),
            tintBorder: Color(rgba: r, g, b, 0.5),
            tintBorder2: Color(rgba: r, g, b, 0.55),
            badge: Color(rgba: badge.0, badge.1, badge.2, 0.92),
            stripe: Color(rgba: r, g, b, 0.08),
            stripe2: Color(rgba: r, g, b, 0.11),
            bg: Color(hex: bg), sheet: Color(hex: sheet), card: Color(hex: card), well: Color(hex: well),
            chip: Color(hex: chip), secondaryButton: Color(hex: button), trackOff: Color(hex: button))
    }

    /// Default: glacier blue over a cool, slightly blue slate.
    static let slate = make(name: .slate, accent: 0x5FA8F5, accentText: 0x93C6FF, accentText2: 0xA8D1FF,
                            badge: (58, 128, 210), bg: 0x0C1017, sheet: 0x141A24, card: 0x1C2432, well: 0x0F141C,
                            chip: 0x161D28, button: 0x2E3A4C)
    /// The bifold wallet: warm tan leather, brass snap.
    static let wallet = make(name: .wallet, accent: 0xC89158, accentText: 0xE2B487, accentText2: 0xEBC29A,
                             badge: (176, 122, 66), bg: 0x120E0A, sheet: 0x1C1610, card: 0x271E15, well: 0x15100C,
                             chip: 0x1F1811, button: 0x413528)
    /// Brushed aluminium, like the original clamshell's hinge.
    static let hinge = make(name: .hinge, accent: 0xA8B4C4, accentText: 0xC6D0DC, accentText2: 0xD3DBE5,
                            badge: (120, 132, 148), bg: 0x0E1013, sheet: 0x171A1F, card: 0x20242B, well: 0x111419,
                            chip: 0x191D23, button: 0x363D47)
    static let fern = make(name: .fern, accent: 0x6DBE84, accentText: 0x9CDCAC, accentText2: 0xAEE4BC,
                           badge: (80, 158, 102), bg: 0x0B110D, sheet: 0x131B15, card: 0x1B261E, well: 0x0E1510,
                           chip: 0x151E17, button: 0x314239)
    static let plum = make(name: .plum, accent: 0xD073C8, accentText: 0xE8A0E1, accentText2: 0xEFB2E9,
                           badge: (182, 92, 174), bg: 0x120C13, sheet: 0x1B121C, card: 0x261A27, well: 0x150E16,
                           chip: 0x1E141F, button: 0x433044)

    static func tokens(for name: ThemeName) -> ThemeTokens {
        switch name {
        case .slate: return .slate
        case .wallet: return .wallet
        case .hinge: return .hinge
        case .fern: return .fern
        case .plum: return .plum
        }
    }
}

/// Colours shared by every theme.
enum Palette {
    static let destructive = Color(hex: 0xFF6961)
    static let textPrimary = Color.white
    static let textSecondary = Color(rgba: 235, 235, 245, 0.6)
    static let textTertiary = Color(rgba: 235, 235, 245, 0.45)
    static let textQuaternary = Color(rgba: 235, 235, 245, 0.3)
    static let text40 = Color(rgba: 235, 235, 245, 0.4)
    static let text55 = Color(rgba: 235, 235, 245, 0.55)
    static let text65 = Color(rgba: 235, 235, 245, 0.65)
    static let text70 = Color(rgba: 235, 235, 245, 0.7)
    static let text75 = Color(rgba: 235, 235, 245, 0.75)
    static let text80 = Color(rgba: 235, 235, 245, 0.8)
    static let text85 = Color(rgba: 235, 235, 245, 0.85)
    static let separator = Color(rgba: 84, 84, 88, 0.5)
    static let separatorStrong = Color(rgba: 84, 84, 88, 0.65)
    static let hairline06 = Color.white.opacity(0.06)
    static let hairline07 = Color.white.opacity(0.07)
    static let hairline08 = Color.white.opacity(0.08)
    static let hairline10 = Color.white.opacity(0.10)
    static let hairline12 = Color.white.opacity(0.12)
    static let hairline14 = Color.white.opacity(0.14)
    static let backdrop = Color.black.opacity(0.55)
    static let toast = Color(rgba: 44, 44, 48, 0.95)
    static let grabber = Color(rgba: 235, 235, 245, 0.25)
    static let canvas = Color.black
    /// Physical button gradients (shared defaults; overridden by skins).
    static let buttonTop = Color(hex: 0x45454C)
    static let buttonBottom = Color(hex: 0x2C2C31)
    static let padTop = Color(hex: 0x3A3A40)
    static let padBottom = Color(hex: 0x26262B)
}

// MARK: - Controller skins

enum ControllerSkinName: String, CaseIterable, Codable, Identifiable {
    case graphite = "Graphite"
    case glacier = "Glacier"
    case walnut = "Walnut"
    case crimson = "Crimson"
    var id: String { rawValue }
}

struct ControllerSkin: Equatable {
    let name: ControllerSkinName
    let description: String
    let buttonTop: Color
    let buttonBottom: Color
    let padTop: Color
    let padBottom: Color

    var buttonGradient: LinearGradient {
        LinearGradient(colors: [buttonTop, buttonBottom], startPoint: .top, endPoint: .bottom)
    }
    var padGradient: LinearGradient {
        LinearGradient(colors: [padTop, padBottom], startPoint: .top, endPoint: .bottom)
    }

    static let graphite = ControllerSkin(
        name: .graphite, description: "Neutral graphite",
        buttonTop: Color(hex: 0x45454C), buttonBottom: Color(hex: 0x2C2C31),
        padTop: Color(hex: 0x3A3A40), padBottom: Color(hex: 0x26262B))
    static let glacier = ControllerSkin(
        name: .glacier, description: "Cool steel blue",
        buttonTop: Color(hex: 0x4A6FA5), buttonBottom: Color(hex: 0x2F4A73),
        padTop: Color(hex: 0x3E5C88), padBottom: Color(hex: 0x283D5C))
    static let walnut = ControllerSkin(
        name: .walnut, description: "Warm walnut",
        buttonTop: Color(hex: 0x6B4F35), buttonBottom: Color(hex: 0x463222),
        padTop: Color(hex: 0x5C432E), padBottom: Color(hex: 0x3E2D1F))
    static let crimson = ControllerSkin(
        name: .crimson, description: "Deep red buttons",
        buttonTop: Color(hex: 0x8C2F3A), buttonBottom: Color(hex: 0x5E1C25),
        padTop: Color(hex: 0x6E2530), padBottom: Color(hex: 0x48171F))

    static let all: [ControllerSkin] = [.graphite, .glacier, .walnut, .crimson]

    static func skin(named name: ControllerSkinName) -> ControllerSkin {
        all.first { $0.name == name } ?? .graphite
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: ThemeTokens = .slate
}

private struct SkinKey: EnvironmentKey {
    static let defaultValue: ControllerSkin = .graphite
}

extension EnvironmentValues {
    var theme: ThemeTokens {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
    var skin: ControllerSkin {
        get { self[SkinKey.self] }
        set { self[SkinKey.self] = newValue }
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    init(rgba r: Int, _ g: Int, _ b: Int, _ a: Double) {
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: a)
    }
}

// MARK: - Typography (SF Pro via system font)

enum Typography {
    static let largeTitle = Font.system(size: 34, weight: .bold)
    static let sheetTitle = Font.system(size: 20, weight: .bold)
    static let dialogTitle = Font.system(size: 17, weight: .bold)
    static let row = Font.system(size: 16, weight: .regular)
    static let rowSemibold = Font.system(size: 16, weight: .semibold)
    static let rowSubtitle = Font.system(size: 12, weight: .regular)
    static let cardTitle = Font.system(size: 15, weight: .semibold)
    static let meta = Font.system(size: 12, weight: .regular)
    static let meta13 = Font.system(size: 13, weight: .regular)
    static let detail = Font.system(size: 14, weight: .regular)
    static let detailSemibold = Font.system(size: 14, weight: .semibold)
    static let button = Font.system(size: 14, weight: .bold)
    static let buttonSemibold = Font.system(size: 14, weight: .semibold)
    static let eyebrow = Font.system(size: 12, weight: .semibold)
    static let sectionHeader = Font.system(size: 12, weight: .semibold)
    static let chip = Font.system(size: 12, weight: .bold)
    static let segment = Font.system(size: 13, weight: .bold)
    static let controlLabel = Font.system(size: 11, weight: .bold)
    static let badge = Font.system(size: 10, weight: .bold)
    static let mono12 = Font.system(size: 12, design: .monospaced)
    static let mono11 = Font.system(size: 11, design: .monospaced)
    static let mono9 = Font.system(size: 9, design: .monospaced)
    static let mono8Bold = Font.system(size: 8, weight: .bold, design: .monospaced)
}
