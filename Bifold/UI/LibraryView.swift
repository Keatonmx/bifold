//
//  LibraryView.swift
//  Bifold
//
//  "BIFOLD" eyebrow over the "Library" large title, settings button, 2-column
//  grid of covers (the carts' own banner icons) and the dashed import tile.
//

import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme

    // Top-aligned so the Import tile lines up with covers, not with cover + title.
    private let columns = [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)]

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    if model.games.count > 4 || !model.searchText.isEmpty {
                        searchBar
                    }
                    if model.searchText.isEmpty, let recent = model.recentGame {
                        ContinueCard(game: recent, coverVersion: model.coverVersion)
                    }
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.visibleGames) { game in
                            GameTile(game: game, coverVersion: model.coverVersion)
                                .onTapGesture {
                                    ButtonHaptics.shared.tap()
                                    model.select(game)
                                }
                                .contextMenu {
                                    Button { model.open(game) } label: { Label("Play", systemImage: "play.fill") }
                                    Button { model.select(game) } label: { Label("Options…", systemImage: "ellipsis.circle") }
                                }
                        }
                        if model.searchText.isEmpty {
                            importTile
                        }
                    }
                    if !model.searchText.isEmpty, model.visibleGames.isEmpty {
                        Text("No games match")
                            .font(Typography.meta13)
                            .foregroundColor(Palette.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    }
                    if model.games.isEmpty {
                        VStack(spacing: 12) {
                            FoldedShellGlyph()
                                .frame(width: 96, height: 76)
                                .opacity(0.9)
                            Text("Nothing folded in yet")
                                .font(Typography.cardTitle)
                                .foregroundColor(Palette.text55)
                            Text("Add .nds files from the Files app. They go into Bifold › ROMs, which you can also open in Files.")
                                .font(Typography.meta13)
                                .foregroundColor(Palette.textTertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 60)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(theme.bg.ignoresSafeArea())
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(Palette.text40)
                TextField("", text: $model.searchText, prompt: Text("Search games").foregroundColor(Palette.textQuaternary))
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !model.searchText.isEmpty {
                    Button { model.searchText = ""; searchFocused = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(Palette.text40)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(theme.chip)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline08, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Menu {
                Picker("Sort", selection: $model.settings.librarySort) {
                    ForEach(LibrarySort.allCases) { sort in Text(sort.rawValue).tag(sort) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 12, weight: .semibold))
                    Text(model.settings.librarySort.rawValue).font(Typography.segment)
                }
                .foregroundColor(Palette.text70)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(theme.chip)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline08, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                BifoldStamp()
                Text("Library")
                    .font(Typography.largeTitle)
                    .tracking(0.3)
                    .foregroundColor(.white)
            }
            Spacer()
            CircleIconButton(size: 44, action: { model.openSheet(.settings) }) {
                SettingsGlyph()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var importTile: some View {
        Button {
            ButtonHaptics.shared.tap()
            model.importKind = .rom
        } label: {
            ZStack {
                Color.clear
                VStack(spacing: 6) {
                    Text("+").font(.system(size: 26, weight: .regular)).foregroundColor(theme.accent)
                    Text("Import ROM").font(.system(size: 13, weight: .semibold)).foregroundColor(Palette.text55)
                        .lineLimit(1)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundColor(Color(rgba: 235, 235, 245, 0.2))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(FadePressStyle())
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// The "BIFOLD" eyebrow as a stamped brand lozenge, debossed like the
/// embossing on a leather wallet.
struct BifoldStamp: View {
    var body: some View {
        HStack(alignment: .top, spacing: 1.5) {
            Text("BIFOLD")
                .font(Typography.eyebrow)
                .tracking(2)
            Text("®")
                .font(.system(size: 6.5, weight: .semibold))
                .padding(.top, -0.5)
        }
        .foregroundColor(Palette.textTertiary)
        .shadow(color: .white.opacity(0.18), radius: 0, y: 0.7)
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .padding(.vertical, 3.5)
        .overlay(Capsule().stroke(Palette.textQuaternary, lineWidth: 1.5))
        .rotationEffect(.degrees(-3), anchor: .bottomLeading)
    }
}

/// The two-line "hamburger with accent dots" glyph.
struct SettingsGlyph: View {
    @Environment(\.theme) private var theme
    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                Capsule().fill(Palette.text70).frame(width: 20, height: 2)
                Capsule().fill(Palette.text70).frame(width: 20, height: 2)
            }
            Circle().fill(theme.accent).frame(width: 6, height: 6).offset(x: -4, y: -5)
            Circle().fill(theme.accent).frame(width: 6, height: 6).offset(x: 4, y: 5)
        }
        .frame(width: 20, height: 16)
    }
}

/// A little open clamshell, drawn: two rounded screens and a hinge.
/// The empty-library mascot.
struct FoldedShellGlyph: View {
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.textQuaternary, lineWidth: 2)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(theme.tint)
                        .padding(6))
            Capsule().fill(Palette.textQuaternary).frame(width: 26, height: 3)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.textQuaternary, lineWidth: 2)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay(
                    Circle()
                        .fill(theme.accent.opacity(0.5))
                        .frame(width: 8, height: 8))
        }
    }
}

struct GameTile: View {
    @Environment(\.theme) private var theme
    let game: Game
    /// Changes when a cover is (re)written so the image reloads from disk.
    var coverVersion: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverArt(game: game, coverVersion: coverVersion)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.hairline07, lineWidth: 0.5))
                .overlay(alignment: .topTrailing) {
                    Text("NDS")
                        .font(Typography.mono8Bold)
                        .tracking(0.5)
                        .foregroundColor(Palette.text70)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                        .padding(6)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(game.title)
                    .font(Typography.cardTitle)
                    .tracking(-0.2)
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(meta)
                    .font(Typography.meta)
                    .foregroundColor(Palette.textTertiary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
    }

    private var meta: String {
        let when = (game.lastPlayed ?? game.addedAt).relativeLibraryString
        return "\(game.fileSize.fileSizeString) · \(when)"
    }
}

/// "Jump back in" card for the most recently played game.
struct ContinueCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    let game: Game
    let coverVersion: Int

    var body: some View {
        Button {
            ButtonHaptics.shared.tap()
            model.openAndContinue(game)
        } label: {
            HStack(spacing: 14) {
                CoverArt(game: game, coverVersion: coverVersion)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline07, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Continue")
                        .font(Typography.eyebrow).textCase(.uppercase).tracking(1)
                        .foregroundColor(theme.accentText)
                    Text(game.title).font(Typography.rowSemibold).foregroundColor(.white).lineLimit(1)
                    Text(model.latestSaveDescription(for: game) ?? "Played \((game.lastPlayed ?? Date()).relativeLibraryString)")
                        .font(Typography.meta).foregroundColor(Palette.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                ZStack {
                    Circle().fill(theme.accent)
                    Image(systemName: "play.fill").font(.system(size: 14, weight: .bold)).foregroundColor(.white).offset(x: 1)
                }
                .frame(width: 40, height: 40)
            }
            .padding(12)
            .background(theme.card)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.tintBorder.opacity(0.6), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(FadePressStyle(opacity: 0.8))
        .contextMenu {
            Button { model.open(game) } label: { Label("Play from the start", systemImage: "play") }
            Button { model.select(game) } label: { Label("Options…", systemImage: "ellipsis.circle") }
        }
    }
}

/// The cart's own banner icon (32×32, upscaled nearest-neighbour so it stays
/// crisp pixel art) over the tinted well; a striped placeholder before the
/// game's first boot.
struct CoverArt: View {
    @Environment(\.theme) private var theme
    let game: Game
    var coverVersion: Int = 0

    var body: some View {
        ZStack {
            theme.chip
            if let image = GameLibraryStore.shared.coverImage(for: game) {
                StripedPlaceholder(stripe: Color(hue: game.coverHue / 360, saturation: 0.35, brightness: 0.6).opacity(0.08),
                                   period: 20, width: 8)
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(18)
                    .id(coverVersion)
            } else {
                StripedPlaceholder(stripe: Color(hue: game.coverHue / 360, saturation: 0.4, brightness: 0.65).opacity(0.13),
                                   period: 20, width: 8)
                Text(initials)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(Palette.text40)
            }
        }
    }

    private var initials: String {
        let words = game.title.split(separator: " ").prefix(2)
        return words.map { String($0.prefix(1)).uppercased() }.joined()
    }
}
