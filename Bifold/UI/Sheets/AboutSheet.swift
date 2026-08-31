//
//  AboutSheet.swift
//  Bifold
//
//  Version, the melonDS credit, and the licenses that come with a GPL app.
//

import SwiftUI

struct AboutSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @State private var showingLicense = false

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        BottomSheet(maxHeightFraction: 0.9, onDismiss: { model.closeSheet() }) {
            SheetHeader(title: "About", onBack: { model.openSheet(.settings) }) {
                AccentPill(title: "Done") { model.closeSheet() }
            }
            HuggingScrollView { VStack(spacing: 0) {

                VStack(spacing: 8) {
                    FoldedShellGlyph()
                        .frame(width: 72, height: 58)
                    Text("Bifold").font(Typography.sheetTitle).foregroundColor(.white)
                    Text("A Nintendo DS emulator by Redfern's Outpost")
                        .font(Typography.meta13).foregroundColor(Palette.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)

                Card {
                    SettingsRow(title: "Version") {
                        Text(appVersion).font(Typography.detail).foregroundColor(Palette.text40)
                    }
                    SettingsRow(title: "Emulator core") {
                        Text(DSEmulatorCore.coreVersion).font(Typography.detail).foregroundColor(Palette.text40)
                    }
                    SettingsRow(title: "License", subtitle: "GPL-3.0 · Bifold links the melonDS core", showsSeparator: false) {
                        TintPill(title: "Read") { showingLicense = true }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Credits")
                            .font(Typography.eyebrow).textCase(.uppercase).tracking(1)
                            .foregroundColor(theme.accentText)
                        Text("melonDS by the melonDS team. Bifold boots games with melonDS's built-in FreeBIOS and generated firmware; no Nintendo files are included. Bring your own dumps of cartridges you own.")
                            .font(Typography.meta13)
                            .foregroundColor(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }

            } }
        }
        .sheet(isPresented: $showingLicense) {
            LicenseView()
        }
    }
}

private struct LicenseView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "melonDS-GPL-3.0", withExtension: "txt"),
              let text = try? String(contentsOf: url) else {
            return "GNU General Public License v3.0 · gnu.org/licenses/gpl-3.0"
        }
        return text
    }

    var body: some View {
        NavigationView {
            ScrollView {
                Text(licenseText)
                    .font(Typography.mono11)
                    .foregroundColor(Palette.text70)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.bg.ignoresSafeArea())
            .navigationTitle("GPL-3.0")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
