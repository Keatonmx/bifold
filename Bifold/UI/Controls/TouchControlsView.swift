//
//  TouchControlsView.swift
//  Bifold
//
//  Lays out the drawn controls from a ControlLayout and puts a transparent
//  UIKit multi-touch layer on top. The touch layer turns touches into a
//  DSKeyMask (several buttons at once, rolling between the ABXY diamond,
//  8-way d-pad) and reports pressed controls back so the visuals can react.
//  The MIC button is not a key: holding it feeds blow noise to the core.
//

import SwiftUI
import UIKit

/// Press state lives in an object so taps re-render only the individual
/// control views, never the container that positions them.
final class ControlPressState: ObservableObject {
    @Published var pressed: Set<ControlID> = []
    @Published var dpadHighlight: DSKeyMask = []
}

struct TouchControlsView: View {
    let layout: ControlLayout
    let metrics: ControlMetrics
    let size: CGSize
    let showBlow: Bool
    let onKeys: (DSKeyMask) -> Void
    let onMenu: () -> Void
    /// The MIC button's held state changed.
    let onMic: (Bool) -> Void

    @StateObject private var press = ControlPressState()
    /// Last size that looked like a real controls area. Mid-relayout SwiftUI can
    /// propose a degenerate size for a frame or two; positioning from a fraction
    /// of such a height squeezed every control into a band at the top of the
    /// screen. Positions therefore always come from the latched size.
    @State private var stableSize: CGSize = .zero

    private static func isPlausible(_ s: CGSize) -> Bool {
        s.width.isFinite && s.height.isFinite && s.width >= 200 && s.height >= 180
    }

    var body: some View {
        let effective = TouchControlsView.isPlausible(size) ? size : stableSize
        let frames = ControlGeometry.frames(layout: layout, metrics: metrics, in: effective, showBlow: showBlow)
        ZStack(alignment: .topLeading) {
            // Purely visual; the UIKit layer below does all input. They must
            // never swallow touches, or the stylus screen underneath (landscape
            // overlays the game) goes deaf.
            Group {
                ForEach(ControlID.allCases) { control in
                    if let frame = frames[control] {
                        ControlSlot(control: control, metrics: metrics, press: press)
                            .frame(width: frame.width, height: frame.height)
                            .scaleEffect(CGFloat(layout[control].scale), anchor: .center)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
            .allowsHitTesting(false)
            MultiTouchInputView(frames: frames,
                                dpadSize: metrics.dpad * CGFloat(layout[.dpad].scale),
                                onKeys: { [press] keys, highlight in
                                    onKeys(keys)
                                    if press.dpadHighlight != highlight { press.dpadHighlight = highlight }
                                },
                                onPressed: { [press] in press.pressed = $0 },
                                onTap: { control in
                                    if control == .menu { onMenu() }
                                },
                                onMic: onMic)
                .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        // Positions must never animate — not from a first zero-size pass, and
        // not from sheet-spring transactions passing through.
        .transaction { $0.animation = nil }
        .onChange(of: size) { s in
            if TouchControlsView.isPlausible(s) { stableSize = s }
        }
        .onAppear {
            if TouchControlsView.isPlausible(size) { stableSize = size }
        }
    }
}

/// One control, drawn at its base size; observes press state and the session
/// on its own so the positioning container above never re-renders on input.
private struct ControlSlot: View {
    @EnvironmentObject private var session: EmulatorSession
    let control: ControlID
    let metrics: ControlMetrics
    @ObservedObject var press: ControlPressState

    var body: some View {
        let base = metrics.baseSize(of: control)
        let pressed = press.pressed
        Group {
            switch control {
            case .dpad:
                DPadView(metrics: metrics, pressed: pressed.contains(.dpad), highlight: press.dpadHighlight)
            case .a:
                FaceButtonView(label: "A", metrics: metrics, pressed: pressed.contains(.a))
            case .b:
                FaceButtonView(label: "B", metrics: metrics, pressed: pressed.contains(.b))
            case .x:
                FaceButtonView(label: "X", metrics: metrics, pressed: pressed.contains(.x))
            case .y:
                FaceButtonView(label: "Y", metrics: metrics, pressed: pressed.contains(.y))
            case .l:
                ShoulderPillView(label: "L", metrics: metrics, pressed: pressed.contains(.l))
            case .r:
                ShoulderPillView(label: "R", metrics: metrics, pressed: pressed.contains(.r))
            case .select:
                BottomPillView(label: "SELECT", metrics: metrics, pressed: pressed.contains(.select))
            case .start:
                BottomPillView(label: "START", metrics: metrics, pressed: pressed.contains(.start))
            case .menu:
                // LED like the hardware: green running, amber paused.
                BottomPillView(label: "MENU", metrics: metrics, pressed: pressed.contains(.menu), accent: true,
                               led: session.isRunning && !session.isPaused ? Color(hex: 0x58CC52) : Color(hex: 0xE0A835))
            case .blow:
                BlowButtonView(metrics: metrics, pressed: pressed.contains(.blow))
            }
        }
        .frame(width: base.width, height: base.height)
    }
}

// MARK: - UIKit multi-touch layer

struct MultiTouchInputView: UIViewRepresentable {
    let frames: [ControlID: CGRect]
    let dpadSize: CGFloat
    let onKeys: (DSKeyMask, DSKeyMask) -> Void
    let onPressed: (Set<ControlID>) -> Void
    let onTap: (ControlID) -> Void
    let onMic: (Bool) -> Void

    func makeUIView(context: Context) -> TouchLayerView {
        let view = TouchLayerView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        update(view)
        return view
    }

    func updateUIView(_ view: TouchLayerView, context: Context) {
        update(view)
    }

    private func update(_ view: TouchLayerView) {
        view.frames = frames
        view.dpadSize = dpadSize
        view.onKeys = onKeys
        view.onPressed = onPressed
        view.onTap = onTap
        view.onMic = onMic
    }
}

final class TouchLayerView: UIView {
    var frames: [ControlID: CGRect] = [:]
    var dpadSize: CGFloat = 142
    var onKeys: ((DSKeyMask, DSKeyMask) -> Void)?
    var onPressed: ((Set<ControlID>) -> Void)?
    var onTap: ((ControlID) -> Void)?
    var onMic: ((Bool) -> Void)?

    private var touchControls: [ObjectIdentifier: ControlID] = [:]
    private var lastKeys: DSKeyMask = []
    private var lastPressed: Set<ControlID> = []
    private var micHeld = false

    /// Extra slop around each control so a finger that drifts slightly keeps the button held.
    private let slop: CGFloat = 14

    /// Claim only touches that land on a control. Everything else falls
    /// through to whatever is underneath — in landscape that is the DS touch
    /// screen, which must keep receiving the stylus.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        control(at: point, slop: 0) != nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            if let hit = control(at: point, slop: 0) {
                touchControls[ObjectIdentifier(touch)] = hit
                ButtonHaptics.shared.tap()
            }
        }
        recompute(touches: event?.allTouches ?? touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            let point = touch.location(in: self)
            let current = touchControls[id]
            // A touch that started on the d-pad stays on it (sliding between directions).
            if current == .dpad { continue }
            // The MIC button keeps its touch: blowing is a hold, not a roll.
            if current == .blow { continue }
            // Rolling from one face button onto another.
            if let next = control(at: point, slop: slop), next != current,
               next != .dpad, next != .menu, next != .blow {
                touchControls[id] = next
                ButtonHaptics.shared.tap()
            } else if current != nil, control(at: point, slop: slop) == nil {
                touchControls[id] = nil
            }
        }
        recompute(touches: event?.allTouches ?? touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if touchControls[id] == .menu, let frame = frames[.menu],
               frame.insetBy(dx: -slop, dy: -slop).contains(touch.location(in: self)) {
                onTap?(.menu)
            }
            touchControls[id] = nil
        }
        recompute(touches: (event?.allTouches ?? []).subtracting(touches))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            touchControls[ObjectIdentifier(touch)] = nil
        }
        recompute(touches: (event?.allTouches ?? []).subtracting(touches))
    }

    private func control(at point: CGPoint, slop: CGFloat) -> ControlID? {
        // Round controls first (their slop overlaps the pills less).
        let order: [ControlID] = [.a, .b, .x, .y, .dpad, .blow, .menu, .select, .start, .l, .r]
        for control in order {
            guard let frame = frames[control] else { continue }
            switch control {
            case .a, .b, .x, .y, .blow:
                let r = frame.width / 2 + slop
                let c = CGPoint(x: frame.midX, y: frame.midY)
                if hypot(point.x - c.x, point.y - c.y) <= r { return control }
            default:
                if frame.insetBy(dx: -slop, dy: -slop).contains(point) { return control }
            }
        }
        return nil
    }

    private func recompute(touches: Set<UITouch>) {
        var keys: DSKeyMask = []
        var dpadHighlight: DSKeyMask = []
        var pressed: Set<ControlID> = []
        let live = Set(touches.filter { $0.phase != .ended && $0.phase != .cancelled }.map { ObjectIdentifier($0) })
        touchControls = touchControls.filter { live.contains($0.key) }

        for touch in touches {
            guard let control = touchControls[ObjectIdentifier(touch)] else { continue }
            pressed.insert(control)
            switch control {
            case .a: keys.insert(.a)
            case .b: keys.insert(.b)
            case .x: keys.insert(.x)
            case .y: keys.insert(.y)
            case .l: keys.insert(.l)
            case .r: keys.insert(.r)
            case .select: keys.insert(.select)
            case .start: keys.insert(.start)
            case .dpad:
                if let frame = frames[.dpad] {
                    let p = touch.location(in: self)
                    let d = ControlGeometry.dpadKeys(dx: p.x - frame.midX, dy: p.y - frame.midY, size: dpadSize)
                    keys.formUnion(d)
                    dpadHighlight.formUnion(d)
                }
            case .menu, .blow:
                break
            }
        }
        if keys != lastKeys {
            // Direction changed while sliding on the d-pad → soft tick.
            let directions: DSKeyMask = [.up, .down, .left, .right]
            let oldDir = DSKeyMask(rawValue: lastKeys.rawValue & directions.rawValue)
            let newDir = DSKeyMask(rawValue: keys.rawValue & directions.rawValue)
            if !newDir.isEmpty, newDir != oldDir, !oldDir.isEmpty {
                ButtonHaptics.shared.tick()
            }
            lastKeys = keys
            onKeys?(keys, dpadHighlight)
        }
        let mic = pressed.contains(.blow)
        if mic != micHeld {
            micHeld = mic
            onMic?(mic)
        }
        if pressed != lastPressed {
            lastPressed = pressed
            onPressed?(pressed)
        }
    }
}
