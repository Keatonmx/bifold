//
//  GameActionsSheet.swift
//  Bifold
//
//  Opens when a library tile is tapped: Play, Continue, Import save, Remove.
//

import SwiftUI

struct GameActionsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @State private var confirmingRemove = false

    var body: some View {
        BottomSheet(onDismiss: { model.closeSheet() }) {
            if let game = model.selectedGame {
                HStack(spacing: 14) {
                    CoverArt(game: game, coverVersion: model.coverVersion)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline07, lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.title).font(Typography.rowSemibold).foregroundColor(.white).lineLimit(1)
                        Text(subtitle(for: game)).font(Typography.meta13).foregroundColor(Palette.textTertiary).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.bottom, 14)

                Card {
                    NavRow(title: "Play", subtitle: "From power-on", showsChevron: false) { model.open(game) }
                    if let latest = model.latestSaveDescription(for: game) {
                        NavRow(title: "Continue", subtitle: latest, showsChevron: false) { model.openAndContinue(game) }
                    }
                    NavRow(title: "Import save file", subtitle: "Battery save (.sav) or save state", showsChevron: false, action: {
                        model.importKind = .saveForGame
                    })
                    NavRow(title: "Remove from library", titleColor: Palette.destructive, showsSeparator: false, showsChevron: false) {
                        confirmingRemove = true
                    }
                }
            }
        }
        .confirmationDialog("Remove this game?",
                            isPresented: $confirmingRemove,
                            titleVisibility: .visible) {
            Button("Remove game and its saves", role: .destructive) {
                if let game = model.selectedGame { model.deleteGame(game) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The ROM file and its save states are deleted from this phone.")
        }
    }

    private func subtitle(for game: Game) -> String {
        var parts = [game.fileSize.fileSizeString]
        if let code = game.gameCode, !code.isEmpty { parts.append(code) }
        if let played = game.lastPlayed { parts.append("Played \(played.relativeLibraryString)") }
        return parts.joined(separator: " · ")
    }
}
