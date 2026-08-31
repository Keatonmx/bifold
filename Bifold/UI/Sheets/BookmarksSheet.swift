//
//  BookmarksSheet.swift
//  Bifold
//
//  The bookmark shelf: automatic playthrough snapshots, newest first, each a
//  top-screen thumbnail with its timestamp. Tap to turn back to that page
//  (the current spot is stashed in the Auto slot first); hold to delete.
//

import SwiftUI

struct BookmarksSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: EmulatorSession
    @Environment(\.theme) private var theme
    @State private var bookmarks: [Bookmark] = []

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        BottomSheet(maxHeightFraction: 0.88, onDismiss: { model.closeSheet() }) {
            SheetHeader(title: "Bookmarks", onBack: { model.openSheet(.quickMenu) }) {
                TintPill(title: "Place one") {
                    if session.captureBookmark() {
                        model.showToast("Bookmark placed")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { reload() }
                    }
                }
            }
            Text(subtitle)
                .font(Typography.meta13)
                .foregroundColor(Palette.text40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.bottom, 10)

            if bookmarks.isEmpty {
                VStack(spacing: 8) {
                    Text("No bookmarks yet")
                        .font(Typography.cardTitle)
                        .foregroundColor(Palette.text55)
                    Text("Bifold slips one in every \(model.settings.bookmarkMinutes) minutes while you play.")
                        .font(Typography.meta13)
                        .foregroundColor(Palette.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                HuggingScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(bookmarks) { bookmark in
                            BookmarkTile(bookmark: bookmark) {
                                model.jumpToBookmark(bookmark)
                            } onDelete: {
                                BookmarkStore.shared.delete(bookmark)
                                reload()
                            }
                        }
                    }
                    Text("Tap to turn back · your spot is saved to Auto first · hold to remove")
                        .font(Typography.meta)
                        .foregroundColor(Palette.text40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 10)
                }
            }
        }
        .onAppear { reload() }
    }

    private var subtitle: String {
        let title = model.currentGame?.title ?? ""
        let n = bookmarks.count
        return n == 1 ? "\(title) · 1 page marked" : "\(title) · \(n) pages marked"
    }

    private func reload() {
        guard let id = model.currentGame?.id else { bookmarks = []; return }
        bookmarks = BookmarkStore.shared.bookmarks(for: id)
    }
}

private struct BookmarkTile: View {
    @Environment(\.theme) private var theme
    let bookmark: Bookmark
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button {
            ButtonHaptics.shared.tap()
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    theme.well
                    if let image = BookmarkStore.shared.thumbnail(of: bookmark) {
                        Image(uiImage: image).resizable().interpolation(.none).scaledToFill()
                    } else {
                        StripedPlaceholder(stripe: theme.stripe2, period: 16, width: 6)
                    }
                }
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.hairline08, lineWidth: 0.5))
                .overlay(alignment: .bottomTrailing) {
                    // The ribbon: a little accent bookmark peeking off the page.
                    BookmarkRibbon()
                        .fill(theme.accent)
                        .frame(width: 12, height: 22)
                        .padding(.trailing, 10)
                        .offset(y: 3)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                }
                Text(bookmark.date.slotTimestampString)
                    .font(Typography.meta)
                    .foregroundColor(Palette.textTertiary)
                    .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(FadePressStyle(opacity: 0.8))
        .contextMenu {
            Button(role: .destructive) { onDelete() } label: { Label("Remove bookmark", systemImage: "trash") }
        }
    }
}

/// A ribbon-tail bookmark shape.
struct BookmarkRibbon: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.width * 0.55))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
