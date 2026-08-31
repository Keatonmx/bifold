//
//  Models.swift
//  Bifold
//

import Foundation
import CoreGraphics

// MARK: - Library

struct Game: Identifiable, Codable, Equatable, Hashable {
    /// Stable identifier derived from the ROM file name (used for state folders).
    let id: String
    /// File name inside Documents/ROMs (e.g. "Chrono Racers.nds").
    var fileName: String
    var title: String
    var fileSize: Int64
    var addedAt: Date
    var lastPlayed: Date?
    /// Header info, filled in on first boot.
    var internalTitle: String?
    var gameCode: String?
    /// The banner's English title (up to three lines), from the cart.
    var bannerTitle: String?
    /// Deterministic hue for the placeholder cover.
    var coverHue: Double

    var romURL: URL { FileLocations.roms.appendingPathComponent(fileName) }

    static func makeID(fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(cleaned).trimmingCharacters(in: .whitespaces)
    }

    static func prettyTitle(fromFileName fileName: String) -> String {
        var base = (fileName as NSString).deletingPathExtension
        // Strip common ROM tags: "(USA)", "[!]", "(Rev 1)" …
        base = base.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        base = base.replacingOccurrences(of: "_", with: " ")
        base = base.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return base.trimmingCharacters(in: .whitespaces).capitalizedWords
    }
}

extension String {
    var capitalizedWords: String {
        split(separator: " ").map { word -> String in
            let w = String(word)
            if w.uppercased() == w && w.count <= 3 { return w } // keep "DS", "II"
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
}

// MARK: - Save states

struct SaveSlot: Identifiable, Codable, Equatable {
    /// 0 == Auto, 1…9 == Slot 1…9
    let index: Int
    var savedAt: Date?

    var id: Int { index }
    var name: String { index == 0 ? "Auto" : "Slot \(index)" }
    var isFilled: Bool { savedAt != nil }

    static let count = 10
    static var empty: [SaveSlot] { (0..<count).map { SaveSlot(index: $0, savedAt: nil) } }

    static func padded(_ slots: [SaveSlot]) -> [SaveSlot] {
        var out = slots
        while out.count < count { out.append(SaveSlot(index: out.count, savedAt: nil)) }
        return Array(out.prefix(count))
    }
}

// MARK: - Per-game persisted data

struct GameData: Codable, Equatable {
    var slots: [SaveSlot] = SaveSlot.empty

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = SaveSlot.padded(try c.decodeIfPresent([SaveSlot].self, forKey: .slots) ?? SaveSlot.empty)
    }
}

// MARK: - Controls layout

enum ControlID: String, CaseIterable, Codable, Identifiable {
    case dpad, a, b, x, y, l, r, select, start, menu, blow
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dpad: return "D-pad"
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .l: return "L"
        case .r: return "R"
        case .select: return "SELECT"
        case .start: return "START"
        case .menu: return "MENU"
        case .blow: return "MIC"
        }
    }
}

/// Position of one control. `x`/`y` are normalised (0…1) within the controls
/// area of the current orientation; `scale` multiplies the design size.
struct ControlPlacement: Codable, Equatable {
    var x: Double
    var y: Double
    var scale: Double = 1
}

struct ControlLayout: Codable, Equatable {
    var placements: [ControlID: ControlPlacement]

    subscript(id: ControlID) -> ControlPlacement {
        get { placements[id] ?? ControlLayout.portraitDefault.placements[id] ?? ControlPlacement(x: 0.5, y: 0.5) }
        set { placements[id] = newValue }
    }

    /// Portrait: controls live in the band below the two screens. D-pad left,
    /// A B X Y diamond right (X top, Y left, A right, B bottom, like the
    /// hardware), L/R pills in the top corners, MIC between the clusters,
    /// SELECT · MENU · START along the bottom.
    static let portraitDefault = ControlLayout(placements: [
        .l:      ControlPlacement(x: 0.12, y: 0.09),
        .r:      ControlPlacement(x: 0.88, y: 0.09),
        .dpad:   ControlPlacement(x: 0.20, y: 0.50),
        .x:      ControlPlacement(x: 0.795, y: 0.26),
        .y:      ControlPlacement(x: 0.645, y: 0.48),
        .a:      ControlPlacement(x: 0.945, y: 0.48),
        .b:      ControlPlacement(x: 0.795, y: 0.70),
        .blow:   ControlPlacement(x: 0.475, y: 0.42),
        .select: ControlPlacement(x: 0.24, y: 0.93),
        .menu:   ControlPlacement(x: 0.50, y: 0.93),
        .start:  ControlPlacement(x: 0.76, y: 0.93),
    ])

    /// Landscape overlay (coordinates relative to the area inside the safe
    /// insets). MENU sits top-centre so nothing covers the screens' bottoms.
    static let landscapeDefault = ControlLayout(placements: [
        .l:      ControlPlacement(x: 0.10, y: 0.10),
        .r:      ControlPlacement(x: 0.90, y: 0.10),
        .menu:   ControlPlacement(x: 0.50, y: 0.08),
        .dpad:   ControlPlacement(x: 0.115, y: 0.56),
        .x:      ControlPlacement(x: 0.895, y: 0.335),
        .y:      ControlPlacement(x: 0.828, y: 0.52),
        .a:      ControlPlacement(x: 0.962, y: 0.52),
        .b:      ControlPlacement(x: 0.895, y: 0.705),
        .blow:   ControlPlacement(x: 0.045, y: 0.92),
        .select: ControlPlacement(x: 0.30, y: 0.94),
        .start:  ControlPlacement(x: 0.70, y: 0.94),
    ])
}
