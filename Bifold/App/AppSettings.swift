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
    /// Sharp-bilinear: crisp pixels without shimmer at non-integer scales.
    case crisp = "Crisp"
    case crt = "CRT"
    case grid = "Grid"
    /// Edge-directed upscaler (xBR-lv2).
    case xbr = "xBR"
    var id: String { rawValue }

    static let options: [ScreenFilter] = [.none, .crisp, .crt, .grid, .xbr]

    /// Index passed to the Metal fragment shader.
    var shaderIndex: Int32 {
        switch self {
        case .none: return 0
        case .crt: return 1
        case .grid: return 2
        case .xbr: return 4
        case .crisp: return 5
        }
    }
}

/// Sideways "book" games (Brain Age, Hotel Dusk): both screens rotate 90°
/// into facing pages. Righty puts the touch page on the right.
enum BookMode: String, CaseIterable, Codable, Identifiable {
    case off = "Off"
    case rightHanded = "Righty"
    case leftHanded = "Lefty"
    var id: String { rawValue }

    /// Renderer/stylus rotation: 1 = device turned counter-clockwise (righty),
    /// 2 = clockwise (lefty).
    var rotation: Int {
        switch self {
        case .off: return 0
        case .rightHanded: return 1
        case .leftHanded: return 2
        }
    }
}

/// How a touched control lights up: a white wash, or the theme's accent colour.
enum PressGlow: String, CaseIterable, Codable, Identifiable {
    case white = "White"
    case accent = "Accent"
    var id: String { rawValue }
}

/// Bookmark cadences offered in Settings (minutes of play).
enum BookmarkInterval {
    static let options = [2, 5, 10]
}

/// Fast-forward presets. DS emulation is heavy; the ceiling is modest.
enum SpeedSteps {
    static let presets: [Double] = [1.5, 2, 3, 4]

    static func label(_ speed: Double) -> String {
        if speed == speed.rounded() { return "\(Int(speed))×" }
        return "\(speed)×"
    }
}

/// Portrait screen sizing: even, or one screen dominant for precision.
enum PortraitLayout: String, CaseIterable, Codable, Identifiable {
    case balanced = "Even"
    case touchFocus = "Touch big"
    case topFocus = "Top big"
    var id: String { rawValue }

    /// Width fraction for a screen, by role.
    func fraction(isTouchScreen: Bool) -> CGFloat {
        switch self {
        case .balanced: return 1
        case .touchFocus: return isTouchScreen ? 1 : 0.58
        case .topFocus: return isTouchScreen ? 0.58 : 1
        }
    }

    /// Sum of both screens' height factors (height = width × 0.75 × fraction).
    var totalHeightFactor: CGFloat {
        switch self {
        case .balanced: return 0.75 * 2
        case .touchFocus, .topFocus: return 0.75 * 1.58
        }
    }
}

/// Whether screens keep the DS's true 4:3 or stretch to use every point.
enum ScreenFit: String, CaseIterable, Codable, Identifiable {
    case aspect = "4:3"
    case fill = "Fill"
    var id: String { rawValue }
}

/// What marks the stylus contact point on the touch screen.
enum StylusStyle: String, CaseIterable, Codable, Identifiable {
    case off = "Off"
    case ring = "Ring"
    case stylus = "Stylus"
    var id: String { rawValue }
}

/// How far above the fingertip a stylus tap lands, in DS pixels — so the
/// finger stops hiding the spot it presses.
enum StylusOffset: String, CaseIterable, Codable, Identifiable {
    case off = "Off"
    case slight = "Slight"
    case high = "High"
    var id: String { rawValue }

    var dsPixels: Int {
        switch self {
        case .off: return 0
        case .slight: return 7
        case .high: return 14
        }
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
    /// Optional on-screen » control; tap toggles fast-forward.
    var showFastForwardButton: Bool = false
    /// Automatic playthrough bookmarks while you play.
    var bookmarksEnabled: Bool = true
    var bookmarkMinutes: Int = 5
    var bootAnimationEnabled: Bool = true
    var backgroundAudioMixing: Bool = false
    var volume: Int = 100

    // Video
    var filter: ScreenFilter = .none
    var screenFit: ScreenFit = .aspect
    var screenGap: ScreenGap = .slim
    /// Landscape becomes two facing book pages for sideways games.
    var bookMode: BookMode = .off
    /// Bottom screen rendered on top (portrait) / left (landscape).
    var swapScreens: Bool = false
    var portraitLayout: PortraitLayout = .balanced

    // Stylus
    var stylusOffset: StylusOffset = .off
    /// Marker at the tap point: nothing, a ring, or a drawn DS stylus.
    var stylusStyle: StylusStyle = .ring
    /// Haptic tick when the stylus makes contact.
    var stylusHaptic: Bool = false

    // Controls
    var hapticsEnabled: Bool = true
    var pressGlow: PressGlow = .accent
    /// 0.30…1.00 — landscape overlay opacity.
    var controlOpacity: Double = 0.65
    /// Show the hold-to-blow MIC button.
    var showMicButton: Bool = true
    /// Feed the phone's real microphone to the emulated one.
    var realMicEnabled: Bool = false
    /// Slot-2 Rumble Pak, felt as phone haptics (applies at boot).
    var rumblePakEnabled: Bool = true
    /// Placing the phone face down closes the lid (DS sleep mode).
    var faceDownSleep: Bool = true

    // Library
    var librarySort: LibrarySort = .recent
    var hiddenGameIDs: [String] = []

    // Remembered state
    var lastPlayedGameID: String?
    var toggledSections: [String] = []
    /// One-time toast when the very first bookmark is placed.
    var hasSeenBookmarkHint: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        theme = try c.decodeIfPresent(ThemeName.self, forKey: .theme) ?? d.theme
        skin = try c.decodeIfPresent(ControllerSkinName.self, forKey: .skin) ?? d.skin
        ffSpeed = try c.decodeIfPresent(Double.self, forKey: .ffSpeed) ?? d.ffSpeed
        showFastForwardButton = try c.decodeIfPresent(Bool.self, forKey: .showFastForwardButton) ?? d.showFastForwardButton
        bookmarksEnabled = try c.decodeIfPresent(Bool.self, forKey: .bookmarksEnabled) ?? d.bookmarksEnabled
        bookmarkMinutes = try c.decodeIfPresent(Int.self, forKey: .bookmarkMinutes) ?? d.bookmarkMinutes
        bootAnimationEnabled = try c.decodeIfPresent(Bool.self, forKey: .bootAnimationEnabled) ?? d.bootAnimationEnabled
        backgroundAudioMixing = try c.decodeIfPresent(Bool.self, forKey: .backgroundAudioMixing) ?? d.backgroundAudioMixing
        volume = try c.decodeIfPresent(Int.self, forKey: .volume) ?? d.volume
        filter = try c.decodeIfPresent(ScreenFilter.self, forKey: .filter) ?? d.filter
        screenFit = try c.decodeIfPresent(ScreenFit.self, forKey: .screenFit) ?? d.screenFit
        screenGap = try c.decodeIfPresent(ScreenGap.self, forKey: .screenGap) ?? d.screenGap
        bookMode = try c.decodeIfPresent(BookMode.self, forKey: .bookMode) ?? d.bookMode
        swapScreens = try c.decodeIfPresent(Bool.self, forKey: .swapScreens) ?? d.swapScreens
        portraitLayout = try c.decodeIfPresent(PortraitLayout.self, forKey: .portraitLayout) ?? d.portraitLayout
        stylusOffset = try c.decodeIfPresent(StylusOffset.self, forKey: .stylusOffset) ?? d.stylusOffset
        stylusStyle = try c.decodeIfPresent(StylusStyle.self, forKey: .stylusStyle) ?? d.stylusStyle
        stylusHaptic = try c.decodeIfPresent(Bool.self, forKey: .stylusHaptic) ?? d.stylusHaptic
        hapticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? d.hapticsEnabled
        pressGlow = try c.decodeIfPresent(PressGlow.self, forKey: .pressGlow) ?? d.pressGlow
        controlOpacity = try c.decodeIfPresent(Double.self, forKey: .controlOpacity) ?? d.controlOpacity
        showMicButton = try c.decodeIfPresent(Bool.self, forKey: .showMicButton) ?? d.showMicButton
        realMicEnabled = try c.decodeIfPresent(Bool.self, forKey: .realMicEnabled) ?? d.realMicEnabled
        rumblePakEnabled = try c.decodeIfPresent(Bool.self, forKey: .rumblePakEnabled) ?? d.rumblePakEnabled
        faceDownSleep = try c.decodeIfPresent(Bool.self, forKey: .faceDownSleep) ?? d.faceDownSleep
        librarySort = try c.decodeIfPresent(LibrarySort.self, forKey: .librarySort) ?? d.librarySort
        hiddenGameIDs = try c.decodeIfPresent([String].self, forKey: .hiddenGameIDs) ?? []
        lastPlayedGameID = try c.decodeIfPresent(String.self, forKey: .lastPlayedGameID)
        toggledSections = try c.decodeIfPresent([String].self, forKey: .toggledSections) ?? d.toggledSections
        hasSeenBookmarkHint = try c.decodeIfPresent(Bool.self, forKey: .hasSeenBookmarkHint) ?? d.hasSeenBookmarkHint
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
