//
//  BookmarkStore.swift
//  Bifold
//
//  Bookmarks: automatic playthrough snapshots. While you play, Bifold slips
//  a bookmark in every few minutes — a compressed save state plus a
//  top-screen thumbnail — so any stretch of a session can be reopened like
//  a page. Stored under States/<game>/Bookmarks/ and thinned so long
//  sessions never eat the phone.
//

import Foundation
import UIKit

struct Bookmark: Identifiable, Equatable {
    /// Unix milliseconds of the capture; doubles as the file name.
    let id: Int64
    let gameID: String

    var date: Date { Date(timeIntervalSince1970: Double(id) / 1000) }
    var stateURL: URL { BookmarkStore.directory(for: gameID).appendingPathComponent("bm-\(id).ssz") }
    var imageURL: URL { BookmarkStore.directory(for: gameID).appendingPathComponent("bm-\(id).png") }
}

final class BookmarkStore {
    static let shared = BookmarkStore()

    /// Bookmarks kept per game: the newest `keepDense` stay untouched; beyond
    /// `cap` the oldest half is thinned every-other so history stays broad
    /// but sparse, like a well-used novel.
    private let cap = 30
    private let keepDense = 12

    static func directory(for gameID: String) -> URL {
        let url = FileLocations.stateDirectory(for: gameID).appendingPathComponent("Bookmarks", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func bookmarks(for gameID: String) -> [Bookmark] {
        let dir = BookmarkStore.directory(for: gameID)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> Bookmark? in
            guard url.pathExtension == "ssz", url.lastPathComponent.hasPrefix("bm-") else { return nil }
            let base = url.deletingPathExtension().lastPathComponent.dropFirst(3)
            guard let id = Int64(base) else { return nil }
            return Bookmark(id: id, gameID: gameID)
        }
        .sorted { $0.id > $1.id }
    }

    func count(for gameID: String) -> Int {
        bookmarks(for: gameID).count
    }

    /// Writes one bookmark: LZFSE-compressed state + PNG thumbnail.
    /// `state` is a raw (uncompressed) melonDS savestate.
    func write(state: Data, thumbnail rgba: Data, gameID: String) -> Bookmark? {
        let bookmark = Bookmark(id: Int64(Date().timeIntervalSince1970 * 1000), gameID: gameID)
        guard let compressed = try? (state as NSData).compressed(using: .lzfse) else { return nil }
        do {
            try (compressed as Data).write(to: bookmark.stateURL, options: .atomic)
        } catch {
            return nil
        }
        if let image = UIImage.fromRGBA(rgba, width: 256, height: 192),
           let png = image.pngData() {
            try? png.write(to: bookmark.imageURL, options: .atomic)
        }
        return bookmark
    }

    /// Reads a bookmark's state back, decompressed and ready for the core.
    func state(of bookmark: Bookmark) -> Data? {
        guard let compressed = try? Data(contentsOf: bookmark.stateURL) else { return nil }
        return (try? (compressed as NSData).decompressed(using: .lzfse)) as Data?
    }

    func thumbnail(of bookmark: Bookmark) -> UIImage? {
        UIImage(contentsOfFile: bookmark.imageURL.path)
    }

    func delete(_ bookmark: Bookmark) {
        try? FileManager.default.removeItem(at: bookmark.stateURL)
        try? FileManager.default.removeItem(at: bookmark.imageURL)
    }

    /// Keeps the shelf tidy: newest `keepDense` always survive; while over
    /// the cap, drop every other one from the old end.
    func thinIfNeeded(gameID: String) {
        var all = bookmarks(for: gameID)     // newest first
        while all.count > cap {
            let old = all.suffix(from: keepDense)
            var removed = false
            for (index, bookmark) in old.enumerated() where index % 2 == 1 {
                delete(bookmark)
                removed = true
            }
            if !removed, let last = all.last {
                delete(last)
            }
            all = bookmarks(for: gameID)
        }
    }
}
