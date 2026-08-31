//
//  EmulatorViewController.swift
//  Bifold
//
//  Hosts one MTKView per DS screen. `EmulatorScreen` wraps it for SwiftUI;
//  `TouchScreenCatcher` sits over whichever view renders the DS touch screen
//  and turns finger positions into stylus coordinates.
//

import UIKit
import MetalKit
import SwiftUI

final class EmulatorViewController: UIViewController {
    let frameStore: FrameStore
    private(set) var renderer: MetalRenderer?
    private var metalView: MTKView!

    init(frameStore: FrameStore) {
        self.frameStore = frameStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let renderer = MetalRenderer(frameStore: frameStore)
        self.renderer = renderer
        let view = MTKView(frame: .zero, device: renderer?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.backgroundColor = .black
        view.isOpaque = true
        view.delegate = renderer
        view.isUserInteractionEnabled = false
        metalView = view
        self.view = view
    }

    func apply(filter: ScreenFilter, stretch: Bool, rotation: Int) {
        renderer?.filter = filter
        renderer?.stretch = stretch
        renderer?.rotation = rotation
    }
}

/// SwiftUI wrapper for one DS screen. Give it a 4:3 frame (3:4 in book
/// mode, or any frame with `stretch`).
struct EmulatorScreen: UIViewControllerRepresentable {
    let frameStore: FrameStore
    var filter: ScreenFilter
    var stretch: Bool = false
    var rotation: Int = 0

    func makeUIViewController(context: Context) -> EmulatorViewController {
        let vc = EmulatorViewController(frameStore: frameStore)
        vc.apply(filter: filter, stretch: stretch, rotation: rotation)
        return vc
    }

    func updateUIViewController(_ vc: EmulatorViewController, context: Context) {
        vc.apply(filter: filter, stretch: stretch, rotation: rotation)
    }
}

// MARK: - Stylus input

/// Transparent view over the touch screen: converts the first touch into DS
/// touchscreen coordinates (0…255 × 0…191). Later touches are ignored — the
/// DS has one stylus. An optional offset lands taps above the fingertip and
/// a cursor ring shows exactly where they land.
struct TouchScreenCatcher: UIViewRepresentable {
    /// DS coordinates while down, nil on release.
    let onStylus: ((x: Int, y: Int)?) -> Void
    var offsetDSPixels: Int = 0
    var style: StylusStyle = .ring
    var rotation: Int = 0
    var hapticOnContact: Bool = false

    func makeUIView(context: Context) -> StylusView {
        let view = StylusView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        update(view)
        return view
    }

    func updateUIView(_ view: StylusView, context: Context) {
        update(view)
    }

    private func update(_ view: StylusView) {
        view.onStylus = onStylus
        view.offsetDSPixels = offsetDSPixels
        view.style = style
        view.rotation = rotation
        view.hapticOnContact = hapticOnContact
    }
}

final class StylusView: UIView {
    var onStylus: (((x: Int, y: Int)?) -> Void)?
    /// Vertical offset in DS pixels: the tap lands this far above the finger.
    var offsetDSPixels: Int = 0
    var style: StylusStyle = .ring
    /// Book mode: 0 upright, 1 device turned CCW (righty), 2 CW (lefty).
    var rotation: Int = 0
    var hapticOnContact = false

    private var activeTouch: UITouch?
    private let cursor = CAShapeLayer()
    private let pen = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Ring + centre dot, white over a soft dark halo so it reads on any game.
        let ring = UIBezierPath(ovalIn: CGRect(x: -9, y: -9, width: 18, height: 18))
        ring.append(UIBezierPath(ovalIn: CGRect(x: -1.5, y: -1.5, width: 3, height: 3)))
        cursor.path = ring.cgPath
        cursor.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        cursor.fillColor = UIColor.clear.cgColor
        cursor.lineWidth = 2
        cursor.shadowColor = UIColor.black.cgColor
        cursor.shadowOpacity = 0.8
        cursor.shadowRadius = 2
        cursor.shadowOffset = .zero
        cursor.isHidden = true
        // The markers must track the finger instantly, not glide.
        cursor.actions = ["position": NSNull(), "hidden": NSNull()]
        layer.addSublayer(cursor)

        // A little silver DS stylus, tip exactly at the contact point, body
        // angled up-right like a pen in the hand. Drawn, not an image.
        let penPath = UIBezierPath()
        penPath.move(to: CGPoint(x: 0, y: 0))
        penPath.addLine(to: CGPoint(x: 12.1, y: -8.2))
        penPath.addLine(to: CGPoint(x: 31.4, y: -31.2))
        penPath.addLine(to: CGPoint(x: 25.2, y: -36.3))
        penPath.addLine(to: CGPoint(x: 5.9, y: -13.3))
        penPath.close()
        pen.path = penPath.cgPath
        pen.fillColor = UIColor(white: 0.93, alpha: 0.95).cgColor
        pen.strokeColor = UIColor(white: 0.25, alpha: 0.8).cgColor
        pen.lineWidth = 1
        pen.lineJoin = .round
        pen.shadowColor = UIColor.black.cgColor
        pen.shadowOpacity = 0.5
        pen.shadowRadius = 2
        pen.shadowOffset = CGSize(width: 1, height: 1)
        pen.isHidden = true
        pen.actions = ["position": NSNull(), "hidden": NSNull()]
        layer.addSublayer(pen)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        if hapticOnContact { ButtonHaptics.shared.tick() }
        report(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        report(touch)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endIfActive(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endIfActive(touches)
    }

    private func endIfActive(_ touches: Set<UITouch>) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        activeTouch = nil
        cursor.isHidden = true
        pen.isHidden = true
        onStylus?(nil)
    }

    private func report(_ touch: UITouch) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        var p = touch.location(in: self)
        p.y -= CGFloat(offsetDSPixels) * bounds.height / (rotation == 0 ? 192 : 256)
        // The offset must not let the pen slide off the digitiser's top edge.
        p.y = max(0, min(bounds.height, p.y))
        switch style {
        case .off:
            break
        case .ring:
            cursor.position = p
            cursor.isHidden = false
        case .stylus:
            pen.position = p
            pen.isHidden = false
        }
        let u = p.x / bounds.width
        let v = p.y / bounds.height
        let x: Int
        let y: Int
        switch rotation {
        case 1:   // device turned CCW: view right = DS down, view down = DS left
            x = Int((1 - v) * 256)
            y = Int(u * 192)
        case 2:   // device turned CW
            x = Int(v * 256)
            y = Int((1 - u) * 192)
        default:
            x = Int(u * 256)
            y = Int(v * 192)
        }
        onStylus?((x: min(255, max(0, x)), y: min(191, max(0, y))))
    }
}
