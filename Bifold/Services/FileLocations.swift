//
//  FileLocations.swift
//  Bifold
//
//  Everything lives under Documents so it is visible in the Files app
//  (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace).
//

import Foundation

enum FileLocations {
    static let documents: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    static let roms = documents.appendingPathComponent("ROMs", isDirectory: true)
    static let saves = documents.appendingPathComponent("Saves", isDirectory: true)
    static let states = documents.appendingPathComponent("States", isDirectory: true)
    static let covers = documents.appendingPathComponent("Covers", isDirectory: true)
    static let library = documents.appendingPathComponent("Library", isDirectory: true)
    /// melonDS's own local files (Wi-Fi settings and similar).
    static let system = documents.appendingPathComponent("System", isDirectory: true)

    static let all: [URL] = [roms, saves, states, covers, library, system]

    static func createAll() {
        for url in all {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func stateDirectory(for gameID: String) -> URL {
        let url = states.appendingPathComponent(gameID, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func stateFile(gameID: String, slot: Int) -> URL {
        stateDirectory(for: gameID).appendingPathComponent("slot\(slot).ss")
    }

    static func stateThumbnail(gameID: String, slot: Int) -> URL {
        stateDirectory(for: gameID).appendingPathComponent("slot\(slot).png")
    }

    static func suspendState(gameID: String) -> URL {
        stateDirectory(for: gameID).appendingPathComponent("suspend.ss")
    }

    static func gameDataFile(gameID: String) -> URL {
        stateDirectory(for: gameID).appendingPathComponent("game.json")
    }

    static func coverImage(gameID: String) -> URL {
        covers.appendingPathComponent("\(gameID).png")
    }

    static let romExtensions: Set<String> = ["nds"]
    static let stateExtensions: Set<String> = ["ss", "sst", "state", "mln"]
    static let batteryExtensions: Set<String> = ["sav"]

    /// Returns a URL in `directory` that does not collide with an existing file.
    static func uniqueURL(in directory: URL, preferredName: String) -> URL {
        var candidate = directory.appendingPathComponent(preferredName)
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return candidate
    }
}

extension Int64 {
    var fileSizeString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter.string(fromByteCount: self)
    }
}

extension Date {
    /// "2h ago", "Yesterday", "Tuesday", "Aug 18" — the library meta style.
    var relativeLibraryString: String {
        let now = Date()
        let seconds = now.timeIntervalSince(self)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 && Calendar.current.isDateInToday(self) { return "\(Int(seconds / 3600))h ago" }
        if Calendar.current.isDateInYesterday(self) { return "Yesterday" }
        if seconds < 6 * 86_400 {
            let f = DateFormatter(); f.dateFormat = "EEEE"; return f.string(from: self)
        }
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: self)
    }

    /// "Today, 14:02" / "Aug 18, 22:37" — the save-state timestamp style.
    var slotTimestampString: String {
        let time = DateFormatter(); time.dateFormat = "HH:mm"
        if Calendar.current.isDateInToday(self) { return "Today, \(time.string(from: self))" }
        if Calendar.current.isDateInYesterday(self) { return "Yesterday, \(time.string(from: self))" }
        let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"
        return f.string(from: self)
    }
}
