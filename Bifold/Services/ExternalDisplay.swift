//
//  ExternalDisplay.swift
//  Bifold
//
//  TV mode: an external display (AirPlay or cable) gets its own scene
//  showing the DS top screen full-size, while the phone keeps the touch
//  screen and controls. Engages automatically on connect.
//

import SwiftUI
import UIKit

/// Bridges the externally-created scene to the app's single model/session
/// (the scene delegate is instantiated by UIKit, outside SwiftUI's graph).
enum TVLink {
    static weak var model: AppModel?
    static weak var session: EmulatorSession?

    static func setConnected(_ connected: Bool) {
        DispatchQueue.main.async {
            model?.tvConnected = connected
        }
    }
}

/// Delegate for the external display scene: one window, one view — the top
/// screen on black, or a card when nothing is running.
final class ExternalSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: TVScreenView())
        window.isHidden = false
        self.window = window
        TVLink.setConnected(true)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        TVLink.setConnected(false)
    }
}

/// What the TV shows: the top screen while a game runs, the Bifold card
/// otherwise.
struct TVScreenView: View {
    var body: some View {
        if let model = TVLink.model, let session = TVLink.session {
            TVContentView(model: model, session: session)
        } else {
            TVIdleCard()
        }
    }
}

private struct TVContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: EmulatorSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if session.isRunning {
                EmulatorScreen(frameStore: session.topStore, filter: model.settings.filter)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .padding(24)
            } else {
                TVIdleCard()
            }
        }
    }
}

private struct TVIdleCard: View {
    var body: some View {
        ZStack {
            Color(hex: 0x0C1017).ignoresSafeArea()
            VStack(spacing: 16) {
                FoldedShellGlyph()
                    .frame(width: 120, height: 96)
                Text("Bifold")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                Text("Open a game · the top screen plays here")
                    .font(Typography.meta13)
                    .foregroundColor(Palette.textTertiary)
            }
        }
    }
}
