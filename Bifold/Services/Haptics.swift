//
//  Haptics.swift
//  Bifold
//
//  Light impact on every control touchDown, plus the Slot-2 Rumble Pak
//  mapped to Core Haptics when a game spins its motor.
//

import UIKit
import CoreHaptics

/// Main-thread only.
final class ButtonHaptics {
    static let shared = ButtonHaptics()
    var enabled = true
    private let generator = UIImpactFeedbackGenerator(style: .light)
    private let selection = UISelectionFeedbackGenerator()

    private init() {
        generator.prepare()
        selection.prepare()
    }

    func tap() {
        guard enabled else { return }
        generator.impactOccurred(intensity: 0.8)
        generator.prepare()
    }

    /// Softer tick for d-pad direction changes while a finger is held down.
    func tick() {
        guard enabled else { return }
        selection.selectionChanged()
        selection.prepare()
    }
}

/// Called from the emulation thread when the Rumble Pak motor turns on or off.
final class RumbleHaptics: @unchecked Sendable {
    var enabled = true
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var running = false
    private let queue = DispatchQueue(label: "com.redfernsoutpost.bifold.rumble")

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        queue.async { [weak self] in self?.setUpEngine() }
    }

    private func setUpEngine() {
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak self] in
                self?.queue.async { self?.setUpEngine() }
            }
            // The DS pak is a plain on/off motor: one buzzy continuous event.
            let event = CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.85),
                                                   CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35)],
                                      relativeTime: 0, duration: 100)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            player.loopEnabled = true
            self.engine = engine
            self.player = player
        } catch {
            engine = nil
            player = nil
        }
    }

    func setRumbling(_ on: Bool) {
        guard enabled || !on, player != nil, on != running else { return }
        running = on
        queue.async { [weak self] in
            guard let self, let engine = self.engine, let player = self.player else { return }
            do {
                if on {
                    try engine.start()
                    try player.start(atTime: CHHapticTimeImmediate)
                } else {
                    try player.stop(atTime: CHHapticTimeImmediate)
                }
            } catch {
                // Haptics are best-effort.
            }
        }
    }
}
