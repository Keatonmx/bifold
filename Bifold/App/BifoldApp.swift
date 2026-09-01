//
//  BifoldApp.swift
//  Bifold — a Nintendo DS emulator by Redfern's Outpost.
//

import SwiftUI
import UIKit

@main
struct BifoldApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.session)
                .environment(\.theme, model.theme)
                .environment(\.skin, model.skin)
                .environment(\.pressGlow, model.settings.pressGlow)
                .preferredColorScheme(.dark)
                .statusBarHidden(model.screen == .game)
                .persistentSystemOverlays(model.screen == .game ? .hidden : .automatic)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .inactive: model.sceneDidBecomeInactive()
            case .active: model.sceneDidBecomeActive()
            case .background: model.sceneDidEnterBackground()
            @unknown default: break
            }
        }
    }
}

/// Makes the orientation mask dynamic (portrait in the library, anything in
/// game) and routes external displays to the TV-mode scene.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationMask: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationMask
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            let config = UISceneConfiguration(name: "TV", sessionRole: connectingSceneSession.role)
            config.delegateClass = ExternalSceneDelegate.self
            return config
        }
        // The main scene stays SwiftUI's.
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                theme.bg.ignoresSafeArea()

                switch model.screen {
                case .library:
                    LibraryView()
                        .transition(.opacity)
                case .game:
                    GameContainerView()
                        .transition(.opacity)
                }

                sheetHost()

                if let toast = model.toast {
                    VStack {
                        Spacer()
                        ToastView(message: toast)
                            .padding(.bottom, landscape ? 60 : 110)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(60)
                    .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: model.screen)
            .animation(.spring(response: 0.35, dampingFraction: 0.9), value: model.activeSheet)
        }
        .sheet(item: Binding(get: { model.importKind.map(ImportRequest.init) }, set: { if $0 == nil { model.importKind = nil } })) { request in
            DocumentPicker(kind: request.kind,
                           onPick: { model.handlePicked($0, kind: request.kind) },
                           onCancel: { model.importKind = nil })
                .ignoresSafeArea()
        }
        .onChange(of: model.screen) { screen in
            if screen == .game {
                OrientationLock.set(mask: .allButUpsideDown)
            } else {
                OrientationLock.set(mask: .portrait, rotateTo: .portrait)
            }
        }
    }

    @ViewBuilder
    private func sheetHost() -> some View {
        if let sheet = model.activeSheet {
            Group {
                switch sheet {
                case .quickMenu: QuickMenuSheet()
                case .saveStates: SaveStatesSheet()
                case .bookmarks: BookmarksSheet()
                case .wireless: WirelessSheet()
                case .settings: SettingsSheet()
                case .gameActions: GameActionsSheet()
                case .about: AboutSheet()
                }
            }
            .zIndex(40)
        }
    }
}

private struct ImportRequest: Identifiable {
    let kind: ImportKind
    var id: String { kind.title }
}
