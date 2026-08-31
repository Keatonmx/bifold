//
//  SettingsSheet.swift
//  Bifold
//
//  Collapsible sections of cards: Appearance, Playback, Video, Controls,
//  Library, About.
//

import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: EmulatorSession
    @Environment(\.theme) private var theme

    var body: some View {
        BottomSheet(maxHeightFraction: 0.92, onDismiss: { model.closeSheet() }) {
            SheetHeader(title: "Settings") {
                AccentPill(title: "Done") { model.closeSheet() }
            }
            HuggingScrollView { VStack(spacing: 0) {

                section("Appearance") {
                    Card {
                        VStack(spacing: 0) {
                            ForEach(ThemeName.allCases) { name in
                                themeRow(name, isLast: false)
                            }
                            SettingsRow(title: "Buttons", subtitle: model.settings.skin.rawValue) {
                                SegmentedPill(options: ControllerSkinName.allCases,
                                              label: { String($0.rawValue.prefix(4)) },
                                              selection: $model.settings.skin,
                                              fontSize: 11, horizontalPadding: 8)
                            }
                            SettingsRow(title: "Press glow", subtitle: "How touched controls light up", showsSeparator: false) {
                                SegmentedPill(options: PressGlow.allCases, label: { $0.rawValue }, selection: $model.settings.pressGlow)
                            }
                        }
                    }
                }

                section("Playback") {
                    Card {
                        SettingsRow(title: "Fast-forward speed", subtitle: "Used when fast-forward is on") {
                            SpeedChips(current: model.settings.ffSpeed) { model.setSpeed($0) }
                        }
                        SettingsRow(title: "Volume", subtitle: "\(model.settings.volume)%") {
                            Slider(value: Binding(get: { Double(model.settings.volume) },
                                                  set: { model.settings.volume = Int($0.rounded()) }),
                                   in: 0...100, step: 5)
                                .frame(width: 140)
                                .tint(theme.accent)
                        }
                        SettingsRow(title: "Mix with other audio", subtitle: "Keep music apps playing underneath") {
                            BifoldToggle(isOn: $model.settings.backgroundAudioMixing)
                        }
                        SettingsRow(title: "Unfold animation", subtitle: "The clamshell opens when a game boots", showsSeparator: false) {
                            BifoldToggle(isOn: $model.settings.bootAnimationEnabled)
                        }
                    }
                }

                section("Video") {
                    Card {
                        SettingsRow(title: "Portrait layout", subtitle: "Big touch screen helps aimed taps") {
                            SegmentedPill(options: PortraitLayout.allCases, label: { $0.rawValue }, selection: $model.settings.portraitLayout, fontSize: 11, horizontalPadding: 8)
                        }
                        SettingsRow(title: "Filter", subtitle: "Applied to both screens") {
                            SegmentedPill(options: ScreenFilter.options, label: { $0.rawValue }, selection: $model.settings.filter)
                        }
                        SettingsRow(title: "Screen gap", subtitle: "Space between the screens in portrait") {
                            SegmentedPill(options: ScreenGap.allCases, label: { $0.rawValue }, selection: $model.settings.screenGap)
                        }
                        SettingsRow(title: "Swap screens", subtitle: "Touch screen on top instead", showsSeparator: false) {
                            BifoldToggle(isOn: $model.settings.swapScreens)
                        }
                    }
                }

                section("Stylus") {
                    Card {
                        SettingsRow(title: "Tap offset", subtitle: "Land taps a little above your fingertip") {
                            SegmentedPill(options: StylusOffset.allCases, label: { $0.rawValue }, selection: $model.settings.stylusOffset)
                        }
                        SettingsRow(title: "Stylus cursor", subtitle: "Ring showing where the tap lands", showsSeparator: false) {
                            BifoldToggle(isOn: $model.settings.stylusCursor)
                        }
                    }
                }

                section("Controls") {
                    Card {
                        SettingsRow(title: "Haptics", subtitle: "Tap feedback and the Rumble Pak motor") {
                            BifoldToggle(isOn: $model.settings.hapticsEnabled)
                        }
                        SettingsRow(title: "Rumble Pak", subtitle: "Slot-2 rumble cart · applies at next boot") {
                            BifoldToggle(isOn: $model.settings.rumblePakEnabled)
                        }
                        SettingsRow(title: "Face-down sleep", subtitle: "Place the phone face down to close the lid") {
                            BifoldToggle(isOn: $model.settings.faceDownSleep)
                        }
                        SettingsRow(title: "MIC button", subtitle: "Hold it to blow into the microphone") {
                            BifoldToggle(isOn: $model.settings.showMicButton)
                        }
                        SettingsRow(title: "Real microphone", subtitle: "Blow or talk at the phone itself") {
                            BifoldToggle(isOn: $model.settings.realMicEnabled)
                        }
                        SettingsRow(title: "Landscape control opacity", subtitle: "\(Int(model.settings.controlOpacity * 100))%") {
                            Slider(value: $model.settings.controlOpacity, in: 0.3...1)
                                .frame(width: 140)
                                .tint(theme.accent)
                        }
                        SettingsRow(title: "Controller", subtitle: ControllerManager.shared.controllerName, showsSeparator: false) {
                            TintPill(title: "Pair") { ControllerManager.shared.startDiscovery() }
                        }
                    }
                }

                section("Library") {
                    Card {
                        NavRow(title: "Import ROMs", subtitle: "Copy .nds files into the library") {
                            model.importKind = .rom
                        }
                        SettingsRow(title: "ROM folder", subtitle: "Bifold › ROMs, visible in the Files app", showsSeparator: false) {
                            Text("\(model.games.count) games").font(Typography.detail).foregroundColor(Palette.text40)
                        }
                    }
                }

                Card {
                    NavRow(title: "About Bifold", subtitle: "Version, credits and licenses", showsSeparator: false) {
                        model.openSheet(.about)
                    }
                }

            } }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        CollapsibleSection(title: name,
                           collapsed: model.isSectionCollapsed(name),
                           onToggle: { model.toggleSectionCollapsed(name) }) {
            content()
        }
    }

    private func themeRow(_ name: ThemeName, isLast: Bool) -> some View {
        let tokens = ThemeTokens.tokens(for: name)
        let selected = model.settings.theme == name
        return VStack(spacing: 0) {
            Button {
                ButtonHaptics.shared.tap()
                model.settings.theme = name
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tokens.bg)
                        Circle().fill(tokens.accent).frame(width: 14, height: 14)
                    }
                    .frame(width: 34, height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.hairline12, lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name.rawValue).font(Typography.row).foregroundColor(.white)
                        Text(name.tagline).font(Typography.rowSubtitle).foregroundColor(Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundColor(theme.accent)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            if !isLast { RowSeparator() }
        }
    }
}
