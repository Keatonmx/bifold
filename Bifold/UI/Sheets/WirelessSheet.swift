//
//  WirelessSheet.swift
//  Bifold
//
//  DS local wireless between phones on the same Wi-Fi, powered by melonDS's
//  LAN multiplayer stack. One phone hosts, others see the session appear and
//  join; then everyone opens the same game and the DS-side wireless menus
//  work like two consoles side by side.
//

import SwiftUI
import UIKit

struct WirelessSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @State private var sessions: [WirelessSession] = []
    @State private var playerCount = 0
    @State private var pollTimer: Timer?

    struct WirelessSession: Identifiable, Equatable {
        let name: String
        let address: String
        let players: Int
        let maxPlayers: Int
        var id: String { address }
    }

    var body: some View {
        BottomSheet(maxHeightFraction: 0.88, onDismiss: { model.closeSheet() }) {
            SheetHeader(title: "Local Wireless", onBack: { model.openSheet(.quickMenu) }) {
                if model.wirelessInSession {
                    SecondaryPill(title: "Leave") { leave() }
                } else {
                    AccentPill(title: "Host") { host() }
                }
            }
            Text("Two phones · same Wi-Fi · same game. This is the experimental one.")
                .font(Typography.meta13)
                .foregroundColor(Palette.text40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.bottom, 10)

            if model.wirelessInSession {
                Card {
                    SettingsRow(title: model.wirelessHosting ? "Hosting as \(UIDevice.current.name)" : "In session",
                                subtitle: playerCount == 1 ? "1 player · waiting for the other phone" : "\(playerCount) players connected",
                                showsSeparator: false) {
                        Circle()
                            .fill(playerCount > 1 ? Color(hex: 0x58CC52) : Color(hex: 0xE0A835))
                            .frame(width: 10, height: 10)
                            .shadow(color: (playerCount > 1 ? Color(hex: 0x58CC52) : Color(hex: 0xE0A835)).opacity(0.8), radius: 4)
                    }
                }
                Text("Now open the same game on every phone and use its own wireless menu, like Download Play or a friend lobby. Keep fast-forward off.")
                    .font(Typography.meta13)
                    .foregroundColor(Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            } else {
                Card {
                    if sessions.isEmpty {
                        SettingsRow(title: "Looking for sessions", subtitle: "Host on the other phone and it appears here", showsSeparator: false) {
                            ProgressView().tint(theme.accent)
                        }
                    } else {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            NavRow(title: session.name,
                                   subtitle: "\(session.players) of \(session.maxPlayers) players · \(session.address)",
                                   detail: "Join",
                                   showsSeparator: index < sessions.count - 1,
                                   showsChevron: false) {
                                join(session)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { begin() }
        .onDisappear { end() }
    }

    private func begin() {
        DSEmulatorCore.wirelessSetEnabled(true)
        if !model.wirelessInSession {
            _ = DSEmulatorCore.wirelessStartDiscovery()
        }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in poll() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        poll()
    }

    private func end() {
        pollTimer?.invalidate()
        pollTimer = nil
        DSEmulatorCore.wirelessEndDiscovery()
        // A live session stays alive when the sheet closes; idle browsing
        // does not keep the radio on.
        if !model.wirelessInSession {
            DSEmulatorCore.wirelessSetEnabled(false)
        }
    }

    private func poll() {
        sessions = DSEmulatorCore.wirelessDiscoveryList().compactMap { entry in
            guard let name = entry[DSWirelessSessionName] as? String,
                  let address = entry[DSWirelessSessionAddress] as? String,
                  let players = entry[DSWirelessSessionPlayers] as? Int,
                  let maxPlayers = entry[DSWirelessSessionMaxPlayers] as? Int else { return nil }
            return WirelessSession(name: name, address: address, players: players, maxPlayers: maxPlayers)
        }
        playerCount = Int(DSEmulatorCore.wirelessNumPlayers())
    }

    private func host() {
        ButtonHaptics.shared.tap()
        DSEmulatorCore.wirelessEndDiscovery()
        if DSEmulatorCore.wirelessHost(withName: UIDevice.current.name, maxPlayers: 16) {
            model.wirelessInSession = true
            model.wirelessHosting = true
            model.showToast("Hosting · visible to phones on this Wi-Fi")
        } else {
            model.showToast("Couldn't start hosting")
            _ = DSEmulatorCore.wirelessStartDiscovery()
        }
        poll()
    }

    private func join(_ session: WirelessSession) {
        ButtonHaptics.shared.tap()
        DSEmulatorCore.wirelessEndDiscovery()
        if DSEmulatorCore.wirelessJoin(withName: UIDevice.current.name, hostAddress: session.address) {
            model.wirelessInSession = true
            model.wirelessHosting = false
            model.showToast("Joined \(session.name)")
        } else {
            model.showToast("Couldn't join \(session.name)")
            _ = DSEmulatorCore.wirelessStartDiscovery()
        }
        poll()
    }

    private func leave() {
        ButtonHaptics.shared.tap()
        DSEmulatorCore.wirelessEndSession()
        DSEmulatorCore.wirelessSetEnabled(false)
        model.wirelessInSession = false
        model.wirelessHosting = false
        model.showToast("Left the session")
        DSEmulatorCore.wirelessSetEnabled(true)
        _ = DSEmulatorCore.wirelessStartDiscovery()
        poll()
    }
}
