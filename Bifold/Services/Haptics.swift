//
//  Haptics.swift
//  Bifold
//
//  Light impact on every control touchDown, respecting the Haptics setting.
//

import UIKit

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
