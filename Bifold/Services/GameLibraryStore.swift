//
//  GameLibraryStore.swift
//  Bifold
//
//  Scans Documents/ROMs, merges with persisted metadata, and stores per-game
//  data (save slots) as JSON next to the states. Cover art is the cart's own
//  32×32 banner icon, written as a PNG on first boot.
//

import Foundation
import UIKit

final class GameLibraryStore {
    static let shared = GameLibraryStore()

    private var indexURL: URL { FileLocations.library.appendingPathComponent("library.json") }
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    // MARK: Library index

    func loadGames() -> [Game] {
        FileLocations.createAll()
        var known: [String: Game] = [:]
        if let data = try? Data(contentsOf: indexURL),
           let games = try? decoder.decode([Game].self, from: data) {
            for g in games { known[g.id] = g }
        }

        // Merge with what is actually on disk (the user may have added files
        // via the Files app).
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: FileLocations.roms, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey], options: [.skipsHiddenFiles])) ?? []
        var result: [Game] = []
        var seen = Set<String>()
        for url in files where FileLocations.romExtensions.contains(url.pathExtension.lowercased()) {
            let fileName = url.lastPathComponent
            let id = Game.makeID(fileName: fileName)
            if seen.contains(id) { continue }
            seen.insert(id)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            if var existing = known[id] {
                existing.fileName = fileName
                existing.fileSize = size
                result.append(existing)
            } else {
                result.append(Game(
                    id: id,
                    fileName: fileName,
                    title: Game.prettyTitle(fromFileName: fileName),
                    fileSize: size,
                    addedAt: values?.creationDate ?? Date(),
                    lastPlayed: nil,
                    internalTitle: nil,
                    gameCode: nil,
                    bannerTitle: nil,
                    coverHue: Self.hue(for: id)))
            }
        }
        result.sort { ($0.lastPlayed ?? $0.addedAt) > ($1.lastPlayed ?? $1.addedAt) }
        saveGames(result)
        return result
    }

    func saveGames(_ games: [Game]) {
        if let data = try? encoder.encode(games) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// Copies a picked ROM into Documents/ROMs. The original stays put.
    func importROM(from sourceURL: URL) throws -> Game {
        FileLocations.createAll()
        let ext = sourceURL.pathExtension.lowercased()
        guard FileLocations.romExtensions.contains(ext) else {
            throw ImportError.unsupportedType(ext)
        }
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        // Already inside the library folder? Just register it.
        if sourceURL.standardizedFileURL.deletingLastPathComponent() == FileLocations.roms.standardizedFileURL {
            return makeGame(for: sourceURL)
        }

        let dest = FileLocations.uniqueURL(in: FileLocations.roms, preferredName: sourceURL.lastPathComponent)
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: sourceURL, options: [], error: &coordinatorError) { readURL in
            do { try FileManager.default.copyItem(at: readURL, to: dest) } catch { copyError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        return makeGame(for: dest)
    }

    private func makeGame(for url: URL) -> Game {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let fileName = url.lastPathComponent
        let id = Game.makeID(fileName: fileName)
        return Game(id: id, fileName: fileName, title: Game.prettyTitle(fromFileName: fileName),
                    fileSize: size, addedAt: Date(), lastPlayed: nil,
                    internalTitle: nil, gameCode: nil, bannerTitle: nil, coverHue: Self.hue(for: id))
    }

    /// Removes the ROM file and its states.
    func deleteGame(_ game: Game) {
        try? FileManager.default.removeItem(at: game.romURL)
        try? FileManager.default.removeItem(at: FileLocations.stateDirectory(for: game.id))
        try? FileManager.default.removeItem(at: FileLocations.coverImage(gameID: game.id))
    }

    enum ImportError: LocalizedError {
        case unsupportedType(String)
        var errorDescription: String? {
            switch self {
            case .unsupportedType(let ext): return "Unsupported file type .\(ext) · Bifold plays .nds"
            }
        }
    }

    // MARK: Per-game data

    func loadGameData(for gameID: String) -> GameData {
        let url = FileLocations.gameDataFile(gameID: gameID)
        guard let data = try? Data(contentsOf: url),
              var gameData = try? decoder.decode(GameData.self, from: data) else {
            return GameData()
        }
        // Reconcile with files on disk (states may have been imported via Files).
        for i in 0..<SaveSlot.count {
            let file = FileLocations.stateFile(gameID: gameID, slot: i)
            let exists = FileManager.default.fileExists(atPath: file.path)
            if exists, gameData.slots[i].savedAt == nil {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                gameData.slots[i].savedAt = date
            } else if !exists {
                gameData.slots[i].savedAt = nil
            }
        }
        return gameData
    }

    func saveGameData(_ gameData: GameData, for gameID: String) {
        if let data = try? encoder.encode(gameData) {
            try? data.write(to: FileLocations.gameDataFile(gameID: gameID), options: .atomic)
        }
    }

    // MARK: Thumbnails / covers

    func thumbnail(gameID: String, slot: Int) -> UIImage? {
        UIImage(contentsOfFile: FileLocations.stateThumbnail(gameID: gameID, slot: slot).path)
    }

    func writeThumbnail(_ rgba: Data, width: Int, height: Int, gameID: String, slot: Int) {
        guard let image = UIImage.fromRGBA(rgba, width: width, height: height),
              let png = image.pngData() else { return }
        try? png.write(to: FileLocations.stateThumbnail(gameID: gameID, slot: slot), options: .atomic)
    }

    /// Writes the cart's 32×32 banner icon as the game's cover.
    func writeBannerIcon(_ rgba: Data, gameID: String) {
        guard let image = UIImage.fromRGBA(rgba, width: 32, height: 32, opaque: false),
              let png = image.pngData() else { return }
        try? png.write(to: FileLocations.coverImage(gameID: gameID), options: .atomic)
    }

    func coverImage(for game: Game) -> UIImage? {
        UIImage(contentsOfFile: FileLocations.coverImage(gameID: game.id).path)
    }

    private static func hue(for id: String) -> Double {
        var h: UInt32 = 2166136261
        for byte in id.utf8 { h = (h ^ UInt32(byte)) &* 16777619 }
        return Double(h % 360)
    }
}

extension UIImage {
    /// Builds an image from the core's 32-bit RGBA buffer (R in the low byte).
    static func fromRGBA(_ data: Data, width: Int, height: Int, opaque: Bool = true) -> UIImage? {
        guard data.count >= width * height * 4 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        let bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo,
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
