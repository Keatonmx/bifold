//
//  EmulatorSession.swift
//  Bifold
//
//  Owns one DSEmulatorCore and drives it from a dedicated thread with a
//  CADisplayLink pinned to 60 Hz. The DS runs at 59.826 fps; the accumulator
//  paces emulation against real time and the audio engine's rate control
//  absorbs the small drift.
//
//  Thread safety: every call into the core goes through `EmulationRunner.lock`.
//  The Metal renderers never touch the core — they read from the two
//  FrameStores, which the emulation thread publishes into after each frame.
//

import Foundation
import QuartzCore
import UIKit
import Combine

/// The DS's real frame rate.
private let dsFrameRate = 59.8260982880808

// MARK: - FrameStore

/// Latest completed frame for one screen, shared between the emulation thread
/// (writer) and a Metal renderer (reader).
final class FrameStore: @unchecked Sendable {
    let width: Int
    let height: Int
    private let lock = NSLock()
    private let pixels: UnsafeMutablePointer<UInt32>
    private var frameIndex: UInt64 = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = .allocate(capacity: width * height)
        pixels.initialize(repeating: 0xFF000000, count: width * height)
    }

    deinit { pixels.deallocate() }

    func publish(from source: UnsafePointer<UInt32>) {
        lock.lock()
        pixels.update(from: source, count: width * height)
        frameIndex &+= 1
        lock.unlock()
    }

    /// Calls `body` with the pixel buffer while holding the lock and returns the
    /// frame index so callers can skip redundant texture uploads.
    @discardableResult
    func read(_ body: (UnsafePointer<UInt32>, Int, Int) -> Void) -> UInt64 {
        lock.lock()
        body(pixels, width, height)
        let index = frameIndex
        lock.unlock()
        return index
    }

    var latestFrameIndex: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return frameIndex
    }
}

// MARK: - EmulationRunner (emulation thread side)

/// Everything the emulation thread touches. Not main-actor isolated on purpose.
final class EmulationRunner: NSObject, @unchecked Sendable {
    let core: DSEmulatorCore
    let lock = NSLock()
    let topStore = FrameStore(width: 256, height: 192)
    let bottomStore = FrameStore(width: 256, height: 192)
    let audio: AudioEngine
    let rumble = RumbleHaptics()
    private var wasRumbling = false

    // Written from the main thread, read on the emulation thread. Individual
    // word-sized writes; torn reads are harmless here.
    var running = false
    var paused = false
    /// Speed chosen in the menu (1 when fast-forward is off).
    var speed: Double = 1
    var touchKeys: DSKeyMask = []
    var controllerKeys: DSKeyMask = []

    /// Stylus state, packed into one word so a read never tears x from y:
    /// bit 31 = down, bits 16-23 = y, bits 0-8 = x.
    private let packedTouch = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    private var lastAppliedTouch: UInt32 = 0

    private var accumulator: Double = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var wasSilent = false

    /// Scratch pixels the core copies into before publishing (emulation thread only).
    private let topScratch = UnsafeMutablePointer<UInt32>.allocate(capacity: 256 * 192)
    private let bottomScratch = UnsafeMutablePointer<UInt32>.allocate(capacity: 256 * 192)

    /// Fired when the game writes its battery save (emulation thread).
    var onSaveData: (() -> Void)?
    /// Fired when the emulated console stops itself (emulation thread).
    var onConsoleStopped: ((DSStopReason) -> Void)?

    init(core: DSEmulatorCore, audio: AudioEngine) {
        self.core = core
        self.audio = audio
        packedTouch.initialize(to: 0)
        super.init()
        core.delegate = self
    }

    deinit {
        packedTouch.deallocate()
        topScratch.deallocate()
        bottomScratch.deallocate()
    }

    func resetTiming() {
        accumulator = 0
        lastTimestamp = 0
        touchKeys = []
        setTouch(nil)
        lastAppliedTouch = 0
    }

    /// Serialised access to the core.
    @discardableResult
    func withCore<T>(_ body: (DSEmulatorCore) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(core)
    }

    /// Main thread: stylus position in DS coordinates, nil = pen up.
    func setTouch(_ point: (x: Int, y: Int)?) {
        if let point {
            let x = UInt32(max(0, min(255, point.x)))
            let y = UInt32(max(0, min(191, point.y)))
            packedTouch.pointee = 0x8000_0000 | (y << 16) | x
        } else {
            packedTouch.pointee = 0
        }
    }

    /// Called on the emulation thread at 60 Hz with the display link timestamp.
    func tick(timestamp: CFTimeInterval) {
        guard running, !paused else { lastTimestamp = 0; return }

        // Pace against real time so a dropped display-link frame is caught up
        // rather than slowing the game. Audio drift (59.83 vs 60 Hz) is
        // absorbed by the audio engine's rate control.
        let elapsed = lastTimestamp > 0 ? min(timestamp - lastTimestamp, 0.05) : (1.0 / 60.0)
        lastTimestamp = timestamp
        let currentSpeed = speed
        accumulator += elapsed * dsFrameRate * currentSpeed

        // Audio is only meaningful at 1×.
        let silent = currentSpeed != 1
        if silent != wasSilent {
            audio.reset()
            wasSilent = silent
        }

        let budgetEnd = CACurrentMediaTime() + 0.0145
        var framesRun = 0
        lock.lock()
        while accumulator >= 1 {
            core.setKeys(DSKeyMask(rawValue: touchKeys.rawValue | controllerKeys.rawValue))
            let touch = packedTouch.pointee
            if touch != lastAppliedTouch {
                lastAppliedTouch = touch
                if touch & 0x8000_0000 != 0 {
                    core.touchScreen(x: Int(touch & 0x1FF), y: Int((touch >> 16) & 0xFF))
                } else {
                    core.releaseScreen()
                }
            } else if touch & 0x8000_0000 != 0 {
                // Held touch: keep reporting the position (games poll per frame).
                core.touchScreen(x: Int(touch & 0x1FF), y: Int((touch >> 16) & 0xFF))
            }
            core.runFrame()
            accumulator -= 1
            framesRun += 1
            if silent {
                core.clearAudio()
            } else {
                drainAudioLocked()
            }
            if CACurrentMediaTime() > budgetEnd {
                // Can't keep up with the requested speed this tick; cap the backlog.
                accumulator = min(accumulator, 1)
                break
            }
        }
        if framesRun > 0, core.copyTopScreen(topScratch, bottomScreen: bottomScratch) {
            topStore.publish(from: topScratch)
            bottomStore.publish(from: bottomScratch)
        }
        let rumbling = core.rumbleActive
        lock.unlock()
        if rumbling != wasRumbling {
            wasRumbling = rumbling
            rumble.setRumbling(rumbling)
        }
    }

    /// Kill the motor when emulation pauses or stops (a game left it on).
    func stopRumble() {
        wasRumbling = false
        rumble.setRumbling(false)
    }

    /// Moves whatever the core produced this frame into the audio ring buffer.
    private func drainAudioLocked() {
        let available = Int(core.availableAudioFrames())
        guard available > 0 else { return }
        audio.ring.write(maxFrames: available) { dst, capacity in
            Int(core.readAudioFrames(dst, count: UInt(capacity)))
        }
        // Whatever did not fit (buffer full) is discarded on the core side.
        if core.availableAudioFrames() > 0 {
            core.clearAudio()
        }
    }
}

extension EmulationRunner: DSEmulatorCoreDelegate {
    func emulatorCoreDidWriteSaveData(_ core: DSEmulatorCore) {
        onSaveData?()
    }

    func emulatorCore(_ core: DSEmulatorCore, didStopWith reason: DSStopReason) {
        onConsoleStopped?(reason)
    }
}

// MARK: - EmulatorSession (main thread API)

/// Main-thread only (not actor-annotated so plain closures can call it in Swift 5 mode).
final class EmulatorSession: ObservableObject {

    @Published private(set) var game: Game?
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published var isFastForward = false { didSet { syncSpeed() } }
    @Published var ffSpeed: Double = 2 { didSet { syncSpeed() } }
    @Published private(set) var controllerConnected = false
    /// The DS lid: closing it puts most games to sleep.
    @Published private(set) var lidClosed = false
    /// Bumped whenever the game writes its battery save.
    @Published private(set) var saveFlash = 0
    /// The clamshell unfold plays once per game load.
    var foldShown = false

    var speedBadgeLabel: String? {
        isFastForward ? "» \(SpeedSteps.label(ffSpeed))" : nil
    }

    let runner: EmulationRunner
    var topStore: FrameStore { runner.topStore }
    var bottomStore: FrameStore { runner.bottomStore }
    var audio: AudioEngine { runner.audio }
    private let thread: EmulationThread
    private let micMonitor = MicMonitor()
    private var cancellables = Set<AnyCancellable>()

    var settings: AppSettings { didSet { applySettings() } }

    init(settings: AppSettings) {
        self.settings = settings
        FileLocations.createAll()
        let core = DSEmulatorCore(saveDirectory: FileLocations.saves,
                                  systemDirectory: FileLocations.system)
        let audio = AudioEngine(sampleRate: Double(core.audioSampleRate))
        runner = EmulationRunner(core: core, audio: audio)
        thread = EmulationThread()

        let runner = self.runner
        thread.tick = { timestamp in runner.tick(timestamp: timestamp) }
        thread.start()

        ControllerManager.shared.onKeysChanged = { [weak runner] mask in runner?.controllerKeys = mask }
        ControllerManager.shared.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in self?.controllerConnected = connected }
            .store(in: &cancellables)

        runner.onSaveData = { [weak self] in
            DispatchQueue.main.async { self?.saveFlash &+= 1 }
        }

        // Real-microphone samples go straight into the core's ring, lock-free.
        micMonitor.onSamples = { samples, count in
            core.submitMicSamples(samples, count: UInt(count))
        }

        applySettings()
    }

    // MARK: Lifecycle

    func load(_ game: Game) throws {
        stop()
        foldShown = false
        let rumblePak = settings.rumblePakEnabled
        try runner.withCore { core in
            core.insertRumblePak = rumblePak
            try core.loadROM(at: game.romURL)
        }
        self.game = game
        lidClosed = false
        runner.resetTiming()
        applySettings()
    }

    /// Header + banner info captured by the core at load (for the library).
    func loadedGameInfo() -> (title: String, code: String, bannerTitle: String?, icon: Data?) {
        runner.withCore { core in
            (core.gameTitle, core.gameCode, core.bannerTitle, core.bannerIconRGBA())
        }
    }

    func start() {
        guard game != nil else { return }
        isRunning = true
        isPaused = false
        runner.paused = false
        runner.running = true
        audio.start(mixWithOthers: settings.backgroundAudioMixing)
        if settings.realMicEnabled { micMonitor.start() }
        syncSpeed()
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        runner.paused = true
        runner.stopRumble()
        audio.pause()
    }

    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        runner.withCore { $0.clearAudio() }
        audio.reset()
        runner.paused = false
        audio.start(mixWithOthers: settings.backgroundAudioMixing)
        if settings.realMicEnabled { micMonitor.start() }
    }

    /// Stops emulation and unloads the ROM (the battery save is flushed).
    func stop() {
        runner.running = false
        runner.paused = false
        isRunning = false
        isPaused = false
        isFastForward = false
        lidClosed = false
        runner.stopRumble()
        micMonitor.stop()
        audio.stop()
        runner.withCore { $0.unloadROM() }
        game = nil
    }

    // MARK: Input

    func setTouchKeys(_ mask: DSKeyMask) {
        runner.touchKeys = mask
    }

    /// Stylus in DS touchscreen coordinates (0…255, 0…191); nil = pen up.
    func setStylus(_ point: (x: Int, y: Int)?) {
        runner.setTouch(point)
    }

    /// The MIC button: while held, blow noise feeds the emulated microphone.
    func setMicHeld(_ held: Bool) {
        runner.core.setMicActive(held)
    }

    func setLid(closed: Bool) {
        guard lidClosed != closed else { return }
        lidClosed = closed
        runner.withCore { $0.setLidClosed(closed) }
    }

    func toggleLid() {
        setLid(closed: !lidClosed)
    }

    func openLid() {
        setLid(closed: false)
    }

    // MARK: Save states

    /// Writes slot `index` (0 == Auto) plus a PNG thumbnail next to it.
    func saveState(slot index: Int) -> Bool {
        guard let game else { return false }
        let url = FileLocations.stateFile(gameID: game.id, slot: index)
        let (ok, pixels) = runner.withCore { core -> (Bool, Data) in
            (core.saveState(to: url), core.copyTopScreenData())
        }
        if ok {
            let id = game.id
            DispatchQueue.global(qos: .utility).async {
                GameLibraryStore.shared.writeThumbnail(pixels, width: 256, height: 192, gameID: id, slot: index)
            }
        }
        return ok
    }

    func loadState(slot index: Int) -> Bool {
        guard let game else { return false }
        return loadState(from: FileLocations.stateFile(gameID: game.id, slot: index))
    }

    func loadState(from url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let ok = runner.withCore { $0.loadState(from: url) }
        if ok { audio.reset() }
        return ok
    }

    /// Emergency state written on resign-active / incoming call.
    func writeSuspendState() {
        guard let game, isRunning else { return }
        _ = runner.withCore { $0.saveState(to: FileLocations.suspendState(gameID: game.id)) }
    }

    func flushSaveData() {
        runner.withCore { $0.flushSaveData() }
    }

    // MARK: Settings → core

    private func applySettings() {
        if ffSpeed != settings.ffSpeed { ffSpeed = settings.ffSpeed }
        audio.setMixWithOthers(settings.backgroundAudioMixing)
        audio.volume = Float(settings.volume) / 100
        runner.rumble.enabled = settings.hapticsEnabled
        runner.core.micMode = settings.realMicEnabled ? .external : .blow
        if isRunning, !isPaused, settings.realMicEnabled {
            micMonitor.start()
        } else if !settings.realMicEnabled {
            micMonitor.stop()
        }
    }

    private func syncSpeed() {
        runner.speed = isFastForward ? ffSpeed : 1
    }
}

// MARK: - Emulation thread

/// A thread whose run loop hosts the CADisplayLink that paces emulation.
final class EmulationThread: Thread {
    var tick: ((CFTimeInterval) -> Void)?
    private var displayLink: CADisplayLink?

    override init() {
        super.init()
        name = "com.redfernsoutpost.bifold.emulation"
        qualityOfService = .userInteractive
    }

    override func main() {
        let link = CADisplayLink(target: self, selector: #selector(onDisplayLink(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .current, forMode: .common)
        displayLink = link
        while !isCancelled {
            RunLoop.current.run(mode: .default, before: .distantFuture)
        }
        link.invalidate()
    }

    @objc private func onDisplayLink(_ link: CADisplayLink) {
        tick?(link.timestamp)
    }
}
