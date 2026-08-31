//
//  AppSettings.swift
//  Bifold
//
//  All user settings, persisted as one Codable blob in UserDefaults.
//  Decoding is tolerant: new fields fall back to defaults instead of
//  throwing the whole blob away.
//

import Foundation

enum LibrarySort: String, CaseIterable, Codable, Identifiable {
    case recent = "Recent"
    case title = "A–Z"
    case size = "Size"
    var id: String { rawValue }
}

enum ScreenFilter: String, CaseIterable, Codable, Identifiable {
    case none = "None"
    case crt = "CRT"
    case grid = "Grid"
    /// Edge-directed upscaler (xBR-lv2).
    case xbr = "xBR"
    var id: String { rawValue }

    static let options: [ScreenFilter] = [.none, .crt, .grid, .xbr]

    /// Index passed to the Metal fragment shader.
    var shaderIndex: Int32 {
        switch self {
        case .none: return 0
        case .crt: return 1
        case .grid: return 2
        case .xbr: return 4
        }
    }
}

/// How a touched control lights up: a white wash, or the theme's accent colour.
enum PressGlow: String, CaseIterable, Codable, Identifiable {
    case white = "White"
    case accent = "Accent"
    var id: String { rawValue }
}

/// Fast-forward presets. DS emulation is heavy; the ceiling is modest.
enum SpeedSteps {
    static let presets: [Double] = [1.5, 2, 3, 4]

    static func label(_ speed: Double) -> String {
        if speed == speed.rounded() { return "\(Int(speed))×" }
        return "\(speed)×"
    }
}

/// Portrait gap between the two screens, in points.
enum ScreenGap: String, CaseIterable, Codable, Identifiable {
    case none = "None"
    case slim = "Slim"
    case hinge = "Hinge"
    var id: String { rawValue }

    var points: CGFloat {
        switch self {
        case .none: return 0
        case .slim: return 10
        case .hinge: return 26
        }
    }
}

struct AppSettings: Codable, Equatable {
    // Appearance
    var theme: ThemeName = .slate
    var skin: ControllerSkinName = .graphite

    // Playback
    var ffSpeed: Double = 2
    var bootAnimationEnabled: Bool = true
    var backgroundAudioMixing: Bool = false
    var volume: Int = 100

    // Video
    var filter: ScreenFilter = .none
    var screenGap: ScreenGap = .slim
    /// Bottom screen rendered on top (portrait) / left (landscape).
    var swapScreens: Bool = false

    // Controls
    var hapticsEnabled: Bool = true
    var pressGlow: PressGlow = .accent
    /// 0.30…1.00 — landscape overlay opacity.
    var controlOpacity: Double = 0.65
    /// Show the hold-to-blow MIC button.
    var showMicButton: Bool = true

    // Library
    var librarySort: LibrarySort = .recent
    var hiddenGameIDs: [String] = []

    // Remembered state
    var lastPlayedGameID: String?
    var toggledSections: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        theme = try c.decodeIfPresent(ThemeName.self, forKey: .theme) ?? d.theme
        skin = try c.decodeIfPresent(ControllerSkinName.self, forKey: .skin) ?? d.skin
        ffSpeed = try c.decodeIfPresent(Double.self, forKey: .ffSpeed) ?? d.ffSpeed
        bootAnimationEnabled = try c.decodeIfPresent(Bool.self, forKey: .bootAnimationEnabled) ?? d.bootAnimationEnabled
        backgroundAudioMixing = try c.decodeIfPresent(Bool.self, forKey: .backgroundAudioMixing) ?? d.backgroundAudioMixing
        volume = try c.decodeIfPresent(Int.self, forKey: .volume) ?? d.volume
        filter = try c.decodeIfPresent(ScreenFilter.self, forKey: .filter) ?? d.filter
        screenGap = try c.decodeIfPresent(ScreenGap.self, forKey: .screenGap) ?? d.screenGap
        swapScreens = try c.decodeIfPresent(Bool.self, forKey: .swapScreens) ?? d.swapScreens
        hapticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? d.hapticsEnabled
        pressGlow = try c.decodeIfPresent(PressGlow.self, forKey: .pressGlow) ?? d.pressGlow
        controlOpacity = try c.decodeIfPresent(Double.self, forKey: .controlOpacity) ?? d.controlOpacity
        showMicButton = try c.decodeIfPresent(Bool.self, forKey: .showMicButton) ?? d.showMicButton
        librarySort = try c.decodeIfPresent(LibrarySort.self, forKey: .librarySort) ?? d.librarySort
        hiddenGameIDs = try c.decodeIfPresent([String].self, forKey: .hiddenGameIDs) ?? []
        lastPlayedGameID = try c.decodeIfPresent(String.self, forKey: .lastPlayedGameID)
        toggledSections = try c.decodeIfPresent([String].self, forKey: .toggledSections) ?? d.toggledSections
    }
}

final class SettingsStore {
    static let shared = SettingsStore()
    private let key = "bifold.settings.v1"
    private let defaults = UserDefaults.standard

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
