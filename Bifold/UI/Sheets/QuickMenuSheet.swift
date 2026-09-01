//
//  QuickMenuSheet.swift
//  Bifold
//
//  Action tiles (Save / Load / Swap screens), Speed card (FF toggle + preset
//  chips), navigation card (states, close lid, settings), Exit.
//

import SwiftUI

struct QuickMenuSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: EmulatorSession
    @Environment(\.theme) private var theme

    var body: some View {
        BottomSheet(maxHeightFraction: 0.92, onDismiss: { model.closeSheet() }) {
            SheetHeader(title: "Quick Menu") {
                AccentPill(title: "Resume") { model.closeSheet() }
            }
            HuggingScrollView { VStack(spacing: 0) {

            // Action tiles
            HStack(spacing: 10) {
                actionTile(title: "Save", subtitle: "To Auto slot") { model.saveToAutoSlot() }
                actionTile(title: "Load", subtitle: model.latestStateDescription) { model.loadLatestState() }
                Button {
                    ButtonHaptics.shared.tap()
                    model.toggleSwapScreens()
                } label: {
                    VStack(spacing: 3) {
                        Text("⇅ Swap").font(.system(size: 15, weight: .bold)).foregroundColor(theme.accentText)
                        Text(model.settings.swapScreens ? "Touch on top" : "Touch below")
                            .font(.system(size: 11)).foregroundColor(theme.accentText.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .background(theme.tint)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.tintBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(FadePressStyle(opacity: 0.75))
            }
            .padding(.bottom, 12)

            // Speed card
            Card {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Fast-forward").font(Typography.row).foregroundColor(.white)
                            Text(fastForwardSubtitle)
                                .font(Typography.rowSubtitle).foregroundColor(Palette.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        BifoldToggle(isOn: Binding(get: { session.isFastForward },
                                                   set: { session.isFastForward = $0 }))
                    }
                    HStack {
                        SpeedChips(current: session.ffSpeed) { model.setSpeed($0) }
                        Spacer(minLength: 0)
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }

            // Navigation
            Card {
                NavRow(title: "All save states", detail: "\(model.gameData.slots.filter(\.isFilled).count) of \(SaveSlot.count) used") { model.openSheet(.saveStates) }
                NavRow(title: "Bookmarks", detail: bookmarkDetail) { model.openSheet(.bookmarks) }
                NavRow(title: "Local wireless", subtitle: "Experimental · two phones on one Wi-Fi",
                       detail: model.wirelessInSession ? (model.wirelessHosting ? "Hosting" : "Joined") : "Off") {
                    model.openSheet(.wireless)
                }
                NavRow(title: "Book mode", subtitle: "Sideways games · hold the phone landscape",
                       detail: model.settings.bookMode.rawValue, showsChevron: false) {
                    model.cycleBookMode()
                }
                NavRow(title: "Close the lid", subtitle: "Most games doze off until it opens", showsChevron: false) {
                    session.toggleLid()
                    model.closeSheet()
                }
                NavRow(title: "Settings", showsSeparator: false) { model.openSheet(.settings) }
            }

            // Exit
            Button {
                ButtonHaptics.shared.tap()
                model.exitGame()
            } label: {
                Text("Exit Game")
                    .font(Typography.rowSemibold)
                    .foregroundColor(Palette.destructive)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 54)
                    .background(theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(ExitPressStyle())

            } }
        }
    }

    private var bookmarkDetail: String {
        guard let id = model.currentGame?.id else { return "" }
        let n = BookmarkStore.shared.count(for: id)
        return n == 1 ? "1 page" : "\(n) pages"
    }

    private var fastForwardSubtitle: String {
        let speed = SpeedSteps.label(session.ffSpeed)
        if session.isFastForward { return "Running at \(speed) until you turn this off" }
        return "Turn on for \(speed) · audio mutes while fast"
    }

    private func actionTile(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button {
            ButtonHaptics.shared.tap()
            action()
        } label: {
            VStack(spacing: 3) {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                Text(subtitle).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundColor(Palette.textTertiary).padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(theme.card)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.hairline08, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(FadePressStyle(opacity: 0.75))
    }
}

struct ExitPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(configuration.isPressed ? Palette.destructive.opacity(0.12) : Color.clear))
    }
}
