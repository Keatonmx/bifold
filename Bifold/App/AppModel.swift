//
//  AppModel.swift
//  Bifold
//
//  Single source of truth for the UI: settings, library, session routing,
//  sheets and toasts. Views only talk to this object and to EmulatorSession.
//

import SwiftUI
import Combine
import UIKit

enum Screen: Equatable {
    case library
    case game
}

enum ActiveSheet: Equatable, Identifiable {
    case quickMenu
    case saveStates
    case bookmarks
    case settings
    /// Play / continue / import save / remove for `AppModel.selectedGame`.
    case gameActions
    case about
    var id: Self { self }
}

/// Main-thread only (not actor-annotated so plain closures can call it in Swift 5 mode).
final class AppModel: ObservableObject {

    // MARK: Persistent state
    @Published var settings: AppSettings {
        didSet {
            SettingsStore.shared.save(settings)
            session.settings = settings
            ButtonHaptics.shared.enabled = settings.hapticsEnabled
        }
    }
    @Published private(set) var games: [Game] = []

    // MARK: Session state
    let session: EmulatorSession
    @Published private(set) var screen: Screen = .library
    @Published private(set) var currentGame: Game?
    /// Game whose action sheet is open (tapped in the library).
    @Published private(set) var selectedGame: Game?
    @Published var gameData = GameData()
    @Published var activeSheet: ActiveSheet?
    @Published var importKind: ImportKind?
    @Published var toast: String?
    /// Bumped whenever a cover image changes so tiles reload from disk.
    @Published var coverVersion = 0
    /// Library search text.
    @Published var searchText = ""

    var theme: ThemeTokens { ThemeTokens.tokens(for: settings.theme) }
    var skin: ControllerSkin { ControllerSkin.skin(named: settings.skin) }

    private var toastWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let settings = SettingsStore.shared.load()
        self.settings = settings
        self.session = EmulatorSession(settings: settings)
        ButtonHaptics.shared.enabled = settings.hapticsEnabled
        refreshLibrary()

        ControllerManager.shared.onMenuPressed = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.screen == .game else { return }
                if self.activeSheet == nil { self.openSheet(.quickMenu) }
            }
        }

        session.$controllerConnected
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] connected in
                self?.showToast(connected ? "Controller connected" : "Controller disconnected")
            }
            .store(in: &cancellables)

        // Feature discovery: the first bookmark ever placed announces itself.
        session.onBookmarkCaptured = { [weak self] in
            guard let self, !self.settings.hasSeenBookmarkHint else { return }
            self.settings.hasSeenBookmarkHint = true
            self.showToast("Bookmark placed · find them in the Quick Menu")
        }

        // Face-down sleep: placing the phone face down closes the lid, like
        // closing a real DS; picking it back up opens it.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.handleDeviceOrientation()
        }

        #if DEBUG
        // Debug builds only (CI simulator screenshots); compiled out of Release.
        // `-bifold-theme <Name>`, `-bifold-sheet <name>`, `-bifold-sections A,B`,
        // `-bifold-autoplay`, `-bifold-landscape`, `-bifold-swap`.
        let args = CommandLine.arguments
        // CI passes -bifold-reset on every launch so screenshot runs never
        // inherit settings a previous shot's arguments persisted.
        if args.contains("-bifold-reset") {
            self.settings = AppSettings()
        }
        if let i = args.firstIndex(of: "-bifold-theme"), i + 1 < args.count, let t = ThemeName(rawValue: args[i + 1]) {
            self.settings.theme = t
        }
        if let i = args.firstIndex(of: "-bifold-skin"), i + 1 < args.count, let s = ControllerSkinName(rawValue: args[i + 1]) {
            self.settings.skin = s
        }
        if let i = args.firstIndex(of: "-bifold-sections"), i + 1 < args.count {
            self.settings.toggledSections = args[i + 1].split(separator: ",").map(String.init)
        }
        if args.contains("-bifold-swap") {
            self.settings.swapScreens = true
        }
        if args.contains("-bifold-touchbig") {
            self.settings.portraitLayout = .touchFocus
        }
        if args.contains("-bifold-fill") {
            self.settings.screenFit = .fill
        }
        if args.contains("-bifold-ffbutton") {
            self.settings.showFastForwardButton = true
        }
        if args.contains("-bifold-book") {
            self.settings.bookMode = .rightHanded
        }
        if let i = args.firstIndex(of: "-bifold-sheet"), i + 1 < args.count {
            let name = args[i + 1]
            // In-game sheets need the ROM booted first (autoplay opens it at 0.5 s).
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                switch name {
                case "settings": self.openSheet(.settings)
                case "about": self.openSheet(.about)
                case "gameActions": if let g = self.games.first { self.select(g) }
                case "quickMenu": self.openSheet(.quickMenu)
                case "bookmarks":
                    self.session.captureBookmark()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.session.captureBookmark()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            self?.openSheet(.bookmarks)
                        }
                    }
                case "saveStates":
                    self.saveToAutoSlot()
                    self.save(toSlot: 1)
                    self.openSheet(.saveStates)
                default: break
                }
            }
        }
        // CI smoke test: `-bifold-autoplay` boots the first ROM in Documents/ROMs
        // so a simulator screenshot shows real emulator output.
        if args.contains("-bifold-autoplay"), let first = games.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.open(first)
                if CommandLine.arguments.contains("-bifold-landscape") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        OrientationLock.set(mask: .landscape, rotateTo: .landscapeRight)
                    }
                }
            }
        }
        #endif
    }

    // MARK: Library

    func refreshLibrary() {
        let hidden = Set(settings.hiddenGameIDs)
        games = GameLibraryStore.shared.loadGames().filter { !hidden.contains($0.id) }
    }

    /// Games as the Library shows them: search filter + chosen sort.
    var visibleGames: [Game] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var list = games
        if !query.isEmpty {
            list = list.filter { $0.title.lowercased().contains(query) || $0.fileName.lowercased().contains(query) }
        }
        switch settings.librarySort {
        case .recent: list.sort { ($0.lastPlayed ?? $0.addedAt) > ($1.lastPlayed ?? $1.addedAt) }
        case .title: list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .size: list.sort { $0.fileSize > $1.fileSize }
        }
        return list
    }

    /// The most recently played game, for the Library's Continue card.
    var recentGame: Game? {
        games.filter { $0.lastPlayed != nil }.max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
    }

    func latestSaveDescription(for game: Game) -> String? {
        let data = GameLibraryStore.shared.loadGameData(for: game.id)
        guard let newest = data.slots.filter({ $0.isFilled }).max(by: { ($0.savedAt ?? .distantPast) < ($1.savedAt ?? .distantPast) }),
              let date = newest.savedAt else { return nil }
        return "\(newest.name) · \(date.slotTimestampString)"
    }

    // MARK: Open / close games

    /// Tapping a library tile opens the game's action sheet.
    func select(_ game: Game) {
        selectedGame = game
        activeSheet = .gameActions
    }

    /// "Continue" from the action sheet: boot and load the newest save state.
    func openAndContinue(_ game: Game) {
        open(game)
        guard currentGame?.id == game.id else { return }
        let slots = gameData.slots.filter { $0.isFilled }
        guard let newest = slots.max(by: { ($0.savedAt ?? .distantPast) < ($1.savedAt ?? .distantPast) }) else { return }
        if session.loadState(slot: newest.index) {
            showToast("Continued from \(newest.name)")
        }
    }

    func open(_ game: Game) {
        var game = game
        let data = GameLibraryStore.shared.loadGameData(for: game.id)
        do {
            try session.load(game)
        } catch {
            showToast("Couldn't load \(game.title)")
            return
        }
        // Header + banner info on first boot: the cart's icon becomes the cover.
        let info = session.loadedGameInfo()
        game.internalTitle = info.title
        game.gameCode = info.code
        game.bannerTitle = info.bannerTitle
        if let icon = info.icon, GameLibraryStore.shared.coverImage(for: game) == nil {
            GameLibraryStore.shared.writeBannerIcon(icon, gameID: game.id)
            coverVersion += 1
        }
        game.lastPlayed = Date()
        updateGame(game)
        settings.lastPlayedGameID = game.id

        currentGame = game
        gameData = data
        activeSheet = nil
        selectedGame = nil
        screen = .game
        session.start()
        if settings.dsiEnabled && !session.bootedAsDSi {
            showToast("DSi files incomplete · booted as a DS")
        }

        // Auto-suspend recovery: if the app was killed mid-session, resume it.
        let suspend = FileLocations.suspendState(gameID: game.id)
        if FileManager.default.fileExists(atPath: suspend.path) {
            if session.loadState(from: suspend) {
                showToast("Picked up where you left off")
            }
            try? FileManager.default.removeItem(at: suspend)
        }
    }

    func exitGame() {
        guard let game = currentGame else { return }
        var autosaved = false
        if session.isRunning {
            // The session's final page belongs on the shelf too.
            session.captureBookmark()
            autosaved = session.saveState(slot: 0)
            if autosaved {
                gameData.slots[0].savedAt = Date()
                persistGameData()
            }
        }
        session.stop()
        // A normal exit supersedes any emergency snapshot from an app switch.
        try? FileManager.default.removeItem(at: FileLocations.suspendState(gameID: game.id))
        activeSheet = nil
        screen = .library
        currentGame = nil
        OrientationLock.set(mask: .portrait, rotateTo: .portrait)
        refreshLibrary()
        if autosaved { showToast("Auto-saved \(game.title)") }
    }

    private func updateGame(_ game: Game) {
        if let i = games.firstIndex(where: { $0.id == game.id }) {
            games[i] = game
        } else {
            games.insert(game, at: 0)
        }
        GameLibraryStore.shared.saveGames(games)
    }

    func deleteGame(_ game: Game) {
        GameLibraryStore.shared.deleteGame(game)
        games.removeAll { $0.id == game.id }
        GameLibraryStore.shared.saveGames(games)
        if selectedGame?.id == game.id { selectedGame = nil; activeSheet = nil }
        showToast("Removed \(game.title)")
    }

    private func persistGameData() {
        guard let game = currentGame else { return }
        GameLibraryStore.shared.saveGameData(gameData, for: game.id)
    }

    // MARK: Sheets / toasts

    func openSheet(_ sheet: ActiveSheet) {
        if screen == .game, activeSheet == nil {
            session.pause()
        }
        activeSheet = sheet
    }

    func closeSheet() {
        activeSheet = nil
        if screen == .game {
            session.resume()
        }
    }

    func showToast(_ message: String) {
        toastWork?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { toast = message }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.25)) { self?.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    // MARK: Quick menu actions

    func saveToAutoSlot() {
        if session.saveState(slot: 0) {
            gameData.slots[0].savedAt = Date()
            persistGameData()
            closeSheet()
            showToast("State saved · Auto")
        } else {
            showToast("Couldn't save state")
        }
    }

    func save(toSlot index: Int) {
        if session.saveState(slot: index) {
            gameData.slots[index].savedAt = Date()
            persistGameData()
            showToast("Saved to \(gameData.slots[index].name)")
        } else {
            showToast("Couldn't save state")
        }
    }

    func deleteState(inSlot index: Int) {
        guard let game = currentGame else { return }
        try? FileManager.default.removeItem(at: FileLocations.stateFile(gameID: game.id, slot: index))
        try? FileManager.default.removeItem(at: FileLocations.stateThumbnail(gameID: game.id, slot: index))
        gameData.slots[index].savedAt = nil
        persistGameData()
        showToast("Deleted \(gameData.slots[index].name)")
    }

    func load(fromSlot index: Int) {
        if session.loadState(slot: index) {
            closeSheet()
            showToast("Loaded \(gameData.slots[index].name)")
        } else {
            showToast("Couldn't load state")
        }
    }

    /// Quick Menu "Load": the most recently saved slot, one tap.
    func loadLatestState() {
        guard let slot = gameData.slots.filter({ $0.isFilled }).max(by: { ($0.savedAt ?? .distantPast) < ($1.savedAt ?? .distantPast) }) else {
            showToast("No saved state yet · use Save first")
            return
        }
        load(fromSlot: slot.index)
    }

    /// Subtitle for the Quick Menu "Load" tile.
    var latestStateDescription: String {
        guard let slot = gameData.slots.filter({ $0.isFilled }).max(by: { ($0.savedAt ?? .distantPast) < ($1.savedAt ?? .distantPast) }),
              let date = slot.savedAt else { return "Nothing saved yet" }
        return "\(slot.name) · \(date.slotTimestampString)"
    }

    func toggleFastForward() {
        session.isFastForward.toggle()
    }

    /// Set when the lid was closed by the face-down gesture (so only the
    /// gesture reopens it, never a lid the user closed on purpose).
    private var lidClosedByFaceDown = false

    private func handleDeviceOrientation() {
        guard settings.faceDownSleep, screen == .game, session.isRunning else { return }
        let faceDown = UIDevice.current.orientation == .faceDown
        if faceDown, !session.lidClosed {
            session.setLid(closed: true)
            lidClosedByFaceDown = true
        } else if !faceDown, lidClosedByFaceDown {
            session.setLid(closed: false)
            lidClosedByFaceDown = false
        }
    }

    func toggleSwapScreens() {
        settings.swapScreens.toggle()
        showToast(settings.swapScreens ? "Touch screen on top" : "Touch screen below")
    }

    /// Turns back to a bookmark — after stashing the current spot in the
    /// Auto slot so jumping into the past never loses the present.
    func jumpToBookmark(_ bookmark: Bookmark) {
        if session.saveState(slot: 0) {
            gameData.slots[0].savedAt = Date()
            persistGameData()
        }
        if session.loadBookmark(bookmark) {
            closeSheet()
            showToast("Turned back · your spot was saved to Auto")
        } else {
            showToast("Couldn't open that bookmark")
        }
    }

    /// Quick Menu: cycle Off → Righty → Lefty.
    func cycleBookMode() {
        switch settings.bookMode {
        case .off: settings.bookMode = .rightHanded
        case .rightHanded: settings.bookMode = .leftHanded
        case .leftHanded: settings.bookMode = .off
        }
        switch settings.bookMode {
        case .off: showToast("Book mode off")
        case .rightHanded: showToast("Book mode · touch page on the right")
        case .leftHanded: showToast("Book mode · touch page on the left")
        }
    }

    func setSpeed(_ speed: Double) {
        settings.ffSpeed = speed
        session.ffSpeed = speed
    }

    /// Sections that start closed; everything else starts open.
    static let sectionsCollapsedByDefault: Set<String> = ["Library"]

    func isSectionCollapsed(_ name: String) -> Bool {
        let byDefault = AppModel.sectionsCollapsedByDefault.contains(name)
        let toggled = settings.toggledSections.contains(name)
        return byDefault != toggled
    }

    func toggleSectionCollapsed(_ name: String) {
        if let i = settings.toggledSections.firstIndex(of: name) {
            settings.toggledSections.remove(at: i)
        } else {
            settings.toggledSections.append(name)
        }
    }

    // MARK: Imports

    func handlePicked(_ urls: [URL], kind: ImportKind) {
        importKind = nil
        switch kind {
        case .rom:
            importROMs(urls)
        case .saveState:
            guard let game = currentGame else { return }
            let loaded = importSaveFiles(urls, for: game, running: true)
            if loaded.state != nil || loaded.battery { activeSheet = .saveStates }
        case .saveForGame:
            guard let game = selectedGame else { return }
            let loaded = importSaveFiles(urls, for: game, running: false)
            if loaded.battery || loaded.state != nil {
                open(game)
                if let slot = loaded.state, currentGame?.id == game.id {
                    _ = session.loadState(slot: slot)
                }
            }
        }
    }

    private func importROMs(_ urls: [URL]) {
        var imported = 0
        for url in urls {
            do {
                let game = try GameLibraryStore.shared.importROM(from: url)
                settings.hiddenGameIDs.removeAll { $0 == game.id }
                if !games.contains(where: { $0.id == game.id }) {
                    games.insert(game, at: 0)
                }
                imported += 1
            } catch {
                showToast(error.localizedDescription)
            }
        }
        if imported > 0 {
            GameLibraryStore.shared.saveGames(games)
            showToast(imported == 1 ? "Added to the library" : "Added \(imported) games")
        }
    }

    /// Imports .sav (battery) / .ss (state) files for `game`. Returns what was
    /// imported; `state` is the slot index a save state landed in.
    @discardableResult
    private func importSaveFiles(_ urls: [URL], for game: Game, running: Bool) -> (battery: Bool, state: Int?) {
        var data = running ? gameData : GameLibraryStore.shared.loadGameData(for: game.id)
        var battery = false
        var stateSlot: Int?
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if FileLocations.batteryExtensions.contains(ext) {
                // Battery save: replace <rom base>.sav in the save dir.
                let base = (game.fileName as NSString).deletingPathExtension
                let dest = FileLocations.saves.appendingPathComponent("\(base).sav")
                if running { session.pause() }
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    battery = true
                    if running {
                        // Reload so the core maps the new file.
                        try? session.load(game)
                        session.start()
                    }
                    showToast("Loaded in-game save")
                }
                if running { session.resume() }
            } else if FileLocations.stateExtensions.contains(ext) {
                guard let slot = data.slots.first(where: { !$0.isFilled }) ?? data.slots.last else { continue }
                let dest = FileLocations.stateFile(gameID: game.id, slot: slot.index)
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    data.slots[slot.index].savedAt = Date()
                    stateSlot = slot.index
                    showToast("Save state placed in \(slot.name)")
                }
            } else {
                showToast("Only .sav and .ss files")
            }
        }
        if running {
            gameData = data
            persistGameData()
        } else {
            GameLibraryStore.shared.saveGameData(data, for: game.id)
        }
        return (battery, stateSlot)
    }

    // MARK: Scene phase

    func sceneDidBecomeInactive() {
        guard screen == .game, session.isRunning else { return }
        session.writeSuspendState()
        session.flushSaveData()
        if activeSheet == nil { session.pause() }
    }

    func sceneDidBecomeActive() {
        // Still alive, so the emergency snapshot is no longer needed.
        if let game = currentGame {
            try? FileManager.default.removeItem(at: FileLocations.suspendState(gameID: game.id))
        }
        guard screen == .game, session.isRunning, activeSheet == nil else { return }
        session.resume()
    }

    func sceneDidEnterBackground() {
        session.flushSaveData()
    }
}

// MARK: - Orientation helper

enum OrientationLock {
    /// Sets the orientations the app currently allows (read by AppDelegate) and
    /// optionally asks the window scene to rotate right away.
    static func set(mask: UIInterfaceOrientationMask, rotateTo preferred: UIInterfaceOrientationMask? = nil) {
        AppDelegate.orientationMask = mask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if let preferred {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: preferred)) { _ in }
        }
    }
}
