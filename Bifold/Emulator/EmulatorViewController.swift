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

    func apply(filter: ScreenFilter) {
        renderer?.filter = filter
    }
}

/// SwiftUI wrapper for one DS screen. Give it a 4:3 frame.
struct EmulatorScreen: UIViewControllerRepresentable {
    let frameStore: FrameStore
    var filter: ScreenFilter

    func makeUIViewController(context: Context) -> EmulatorViewController {
        let vc = EmulatorViewController(frameStore: frameStore)
        vc.apply(filter: filter)
        return vc
    }

    func updateUIViewController(_ vc: EmulatorViewController, context: Context) {
        vc.apply(filter: filter)
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
    var showsCursor: Bool = true

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
        view.showsCursor = showsCursor
    }
}

final class StylusView: UIView {
    var onStylus: (((x: Int, y: Int)?) -> Void)?
    /// Vertical offset in DS pixels: the tap lands this far above the finger.
    var offsetDSPixels: Int = 0
    var showsCursor = true

    private var activeTouch: UITouch?
    private let cursor = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Ring + centre dot, white over a soft dark halo so it reads on any game.
        let path = UIBezierPath(ovalIn: CGRect(x: -9, y: -9, width: 18, height: 18))
        path.append(UIBezierPath(ovalIn: CGRect(x: -1.5, y: -1.5, width: 3, height: 3)))
        cursor.path = path.cgPath
        cursor.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        cursor.fillColor = UIColor.clear.cgColor
        cursor.lineWidth = 2
        cursor.shadowColor = UIColor.black.cgColor
        cursor.shadowOpacity = 0.8
        cursor.shadowRadius = 2
        cursor.shadowOffset = .zero
        cursor.isHidden = true
        // The cursor must track the finger instantly, not glide.
        cursor.actions = ["position": NSNull(), "hidden": NSNull()]
        layer.addSublayer(cursor)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
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
        onStylus?(nil)
    }

    private func report(_ touch: UITouch) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        var p = touch.location(in: self)
        p.y -= CGFloat(offsetDSPixels) * bounds.height / 192
        // The offset must not let the pen slide off the digitiser's top edge.
        p.y = max(0, min(bounds.height, p.y))
        if showsCursor {
            cursor.position = p
            cursor.isHidden = false
        }
        let x = Int((p.x / bounds.width) * 256)
        let y = Int((p.y / bounds.height) * 192)
        onStylus?((x: min(255, max(0, x)), y: min(191, max(0, y))))
    }
}
