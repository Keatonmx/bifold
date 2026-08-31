//
//  SaveStatesSheet.swift
//  Bifold
//
//  Ten slots (Auto, Slot 1–9) with 84×63 top-screen thumbnails, timestamp and
//  the accent action: "Load" for filled slots, "Save here" for empty ones.
//

import SwiftUI

struct SaveStatesSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        BottomSheet(maxHeightFraction: 0.84, onDismiss: { model.closeSheet() }) {
            SheetHeader(title: "Save States", onBack: { model.openSheet(.quickMenu) }) {
                TintPill(title: "Import") { model.importKind = .saveState }
            }
            Text(model.currentGame?.title ?? "")
                .font(Typography.meta13)
                .foregroundColor(Palette.text40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            HuggingScrollView {
                VStack(spacing: 0) {
                    ForEach(model.gameData.slots) { slot in
                        SlotRow(slot: slot,
                                thumbnail: slot.isFilled ? GameLibraryStore.shared.thumbnail(gameID: model.currentGame?.id ?? "", slot: slot.index) : nil,
                                isLast: slot.index == SaveSlot.count - 1) {
                            if slot.isFilled { model.load(fromSlot: slot.index) } else { model.save(toSlot: slot.index) }
                        } onOverwrite: {
                            model.save(toSlot: slot.index)
                        } onDelete: {
                            model.deleteState(inSlot: slot.index)
                        }
                    }
                }
                .background(theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("Tap to load · hold a slot to overwrite or delete it")
                    .font(Typography.meta)
                    .foregroundColor(Palette.text40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
            }
        }
    }
}

private struct SlotRow: View {
    @Environment(\.theme) private var theme
    let slot: SaveSlot
    let thumbnail: UIImage?
    let isLast: Bool
    let action: () -> Void
    let onOverwrite: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button {
                ButtonHaptics.shared.tap()
                action()
            } label: {
                HStack(spacing: 14) {
                    thumb
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slot.name).font(Typography.rowSemibold).foregroundColor(.white)
                        Text(slot.savedAt?.slotTimestampString ?? "Empty")
                            .font(Typography.meta13)
                            .foregroundColor(Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(slot.isFilled ? "Load" : "Save here")
                        .font(Typography.detailSemibold)
                        .foregroundColor(theme.accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            .contextMenu {
                if slot.isFilled {
                    Button { onOverwrite() } label: { Label("Overwrite with current state", systemImage: "square.and.arrow.down") }
                    Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
                }
            }
            if !isLast { RowSeparator() }
        }
    }

    @ViewBuilder
    private var thumb: some View {
        if slot.isFilled {
            ZStack {
                theme.well
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().interpolation(.none).scaledToFill()
                } else {
                    StripedPlaceholder(stripe: theme.stripe2, period: 16, width: 6)
                    Text("snapshot").font(Typography.mono9).foregroundColor(.white.opacity(0.3))
                }
            }
            .frame(width: 84, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.hairline08, lineWidth: 0.5))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .foregroundColor(Color(rgba: 235, 235, 245, 0.15))
                .overlay(Text("empty").font(Typography.mono9).foregroundColor(.white.opacity(0.2)))
                .frame(width: 84, height: 63)
        }
    }
}
