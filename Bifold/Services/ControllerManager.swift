//
//  ControllerManager.swift
//  Bifold
//
//  GameController framework, standard mapping. Nintendo positions win: the
//  physical bottom button is DS B, right is A, top is X, left is Y (which is
//  Xbox/PS A→B, B→A, Y→X, X→Y). L1/R1 = L/R, menu = Start, options = Select,
//  d-pad and left stick = d-pad.
//

import Foundation
import GameController
import Combine

final class ControllerManager: ObservableObject {
    static let shared = ControllerManager()

    @Published private(set) var isConnected = false
    @Published private(set) var controllerName: String = "None connected"

    /// Called on whatever thread GameController delivers on.
    var onKeysChanged: ((DSKeyMask) -> Void)?
    /// Fired when the controller's menu/home button should open the Quick Menu.
    var onMenuPressed: (() -> Void)?

    private var current: GCController?
    private var keys: DSKeyMask = [] {
        didSet { if keys != oldValue { onKeysChanged?(keys) } }
    }

    private init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if let controller = note.object as? GCController { self?.attach(controller) }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let controller = note.object as? GCController, controller == self.current else { return }
            self.current = nil
            self.keys = []
            self.isConnected = false
            self.controllerName = "None connected"
            if let next = GCController.controllers().first { self.attach(next) }
        }
        if let controller = GCController.controllers().first {
            attach(controller)
        }
    }

    /// Starts Bluetooth discovery (iOS shows the system pairing UI for new devices).
    func startDiscovery() {
        GCController.startWirelessControllerDiscovery {}
    }

    private func attach(_ controller: GCController) {
        current = controller
        isConnected = true
        controllerName = controller.vendorName ?? "Controller"
        controller.playerIndex = .index1

        guard let gamepad = controller.extendedGamepad else { return }
        gamepad.valueChangedHandler = { [weak self] pad, _ in
            self?.readKeys(from: pad)
        }
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.onMenuPressed?() }
        }
        if let home = gamepad.buttonHome {
            home.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.onMenuPressed?() }
            }
        }
    }

    private func readKeys(from pad: GCExtendedGamepad) {
        var mask: DSKeyMask = []
        // GCExtendedGamepad positions: buttonA = bottom, buttonB = right,
        // buttonX = left, buttonY = top. Map by position to the DS diamond.
        if pad.buttonA.isPressed { mask.insert(.b) }
        if pad.buttonB.isPressed { mask.insert(.a) }
        if pad.buttonX.isPressed { mask.insert(.y) }
        if pad.buttonY.isPressed { mask.insert(.x) }
        if pad.leftShoulder.isPressed { mask.insert(.l) }
        if pad.rightShoulder.isPressed { mask.insert(.r) }
        if pad.leftTrigger.isPressed { mask.insert(.l) }
        if pad.rightTrigger.isPressed { mask.insert(.r) }
        if pad.buttonOptions?.isPressed == true { mask.insert(.select) }
        if pad.buttonMenu.isPressed { mask.insert(.start) }

        let dpad = pad.dpad
        let stick = pad.leftThumbstick
        let dead: Float = 0.45
        if dpad.up.isPressed || stick.yAxis.value > dead { mask.insert(.up) }
        if dpad.down.isPressed || stick.yAxis.value < -dead { mask.insert(.down) }
        if dpad.left.isPressed || stick.xAxis.value < -dead { mask.insert(.left) }
        if dpad.right.isPressed || stick.xAxis.value > dead { mask.insert(.right) }
        keys = mask
    }
}
