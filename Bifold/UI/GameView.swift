//
//  GameView.swift
//  Bifold
//
//  In-game screen. Portrait stacks the two DS screens above the controls;
//  landscape puts them side by side under a translucent overlay. The screen
//  showing the DS touch screen carries the stylus catcher, wherever it is.
//

import SwiftUI

struct GameContainerView: View {
    var body: some View {
        // The reader respects the safe area so its insets are SwiftUI's own.
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            if full.width > full.height {
                // Landscape is full-bleed: draw at the real screen size, shifted
                // back over the insets.
                LandscapeGameView(size: full, safeArea: insets)
                    .frame(width: full.width, height: full.height)
                    .offset(x: -insets.leading, y: -insets.top)
            } else {
                PortraitGameView()
            }
        }
    }
}

/// One DS screen with its frame store; the touch screen also catches the stylus.
private struct DSScreenView: View {
    @EnvironmentObject private var session: EmulatorSession
    @EnvironmentObject private var model: AppModel
    let store: FrameStore
    let filter: ScreenFilter
    let isTouchScreen: Bool
    var cornerRadius: CGFloat = 6
    /// Fill mode: stretch into whatever frame the layout gives, no 4:3 lock.
    var fill: Bool = false
    /// Book mode rotation (0 upright, 1 righty, 2 lefty): pages are 3:4.
    var bookRotation: Int = 0

    var body: some View {
        Group {
            if fill {
                EmulatorScreen(frameStore: store, filter: filter, stretch: true, rotation: bookRotation)
            } else {
                EmulatorScreen(frameStore: store, filter: filter, rotation: bookRotation)
                    .aspectRatio(bookRotation == 0 ? 4.0 / 3.0 : 3.0 / 4.0, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Palette.hairline06, lineWidth: 1))
        .overlay {
            if isTouchScreen {
                TouchScreenCatcher(onStylus: { point in session.setStylus(point) },
                                   offsetDSPixels: model.settings.stylusOffset.dsPixels,
                                   style: model.settings.stylusStyle,
                                   rotation: bookRotation,
                                   hapticOnContact: model.settings.stylusHaptic)
            }
        }
    }
}

// MARK: - Portrait

struct PortraitGameView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: EmulatorSession
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Boot flourish: the clamshell unfolds — both screens hinge open from
    /// the gap between them.
    @State private var unfolded = false

    private let metrics = ControlMetrics(isLandscape: false)
    private let minControlsHeight: CGFloat = 210

    var body: some View {
        GeometryReader { geo in
            let gap = model.settings.screenGap.points
            let fill = model.settings.screenFit == .fill
            // No top bar in-game: a floating back bubble rides the top screen,
            // so the screens get every point the controls don't need. With a
            // focused layout one screen shrinks, so the base width can grow;
            // Fill ignores 4:3 and hands the screens all of it.
            let available = geo.size.height - minControlsHeight - gap - 28
            let maxByHeight = available / model.settings.portraitLayout.totalHeightFactor
            let screenWidth = fill ? max(200, geo.size.width - 8)
                                   : max(200, min(geo.size.width - 8, maxByHeight))
            VStack(spacing: 0) {
                screenBand(width: screenWidth, gap: gap, fill: fill, availableHeight: available)
                controlsArea
            }
        }
        .background(theme.bg.ignoresSafeArea())
    }

    private func screenBand(width: CGFloat, gap: CGFloat, fill: Bool, availableHeight: CGFloat) -> some View {
        let swap = model.settings.swapScreens
        let layout = model.settings.portraitLayout
        // Which role each display slot shows, and how wide it is (a focused
        // layout gives the emphasised role the full width). In Fill mode the
        // fractions divide the height instead and both slots span the width.
        let slot1IsTouch = swap
        let slot2IsTouch = !swap
        let f1 = layout.fraction(isTouchScreen: slot1IsTouch)
        let f2 = layout.fraction(isTouchScreen: slot2IsTouch)
        let fillHeight = max(100, availableHeight - gap)
        return VStack(spacing: gap) {
            DSScreenView(store: slot1IsTouch ? session.bottomStore : session.topStore,
                         filter: model.settings.filter,
                         isTouchScreen: slot1IsTouch,
                         fill: fill)
                .frame(width: fill ? width : width * f1,
                       height: fill ? fillHeight * f1 / (f1 + f2) : nil)
                .rotation3DEffect(.degrees(unfolded ? 0 : -68), axis: (x: 1, y: 0, z: 0),
                                  anchor: .bottom, perspective: 0.5)
            DSScreenView(store: slot2IsTouch ? session.bottomStore : session.topStore,
                         filter: model.settings.filter,
                         isTouchScreen: slot2IsTouch,
                         fill: fill)
                .frame(width: fill ? width : width * f2,
                       height: fill ? fillHeight * f2 / (f1 + f2) : nil)
                .rotation3DEffect(.degrees(unfolded ? 0 : 68), axis: (x: 1, y: 0, z: 0),
                                  anchor: .top, perspective: 0.5)
        }
        .frame(width: width)
        // Without this the VStack splits height with the greedy controls
        // area and quietly shrinks the screens below their computed size.
        .fixedSize(horizontal: false, vertical: true)
        .opacity(unfolded ? 1 : 0.35)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .overlay {
            if session.lidClosed {
                lidOverlay
            }
        }
        .overlay(alignment: .topLeading) {
            floatingCircle(action: { model.exitGame() }) {
                ChevronShape(direction: .left)
                    .stroke(Palette.text80, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 9, height: 15)
            }
            .padding(.leading, 12)
            .padding(.top, 12)
        }
        .overlay(alignment: .topTrailing) {
            if let label = session.speedBadgeLabel {
                FFBadge(label: label)
                    .padding(.trailing, 14)
                    .padding(.top, 16)
            }
        }
        .onAppear {
            if session.foldShown || !model.settings.bootAnimationEnabled || reduceMotion {
                unfolded = true          // off, Reduce Motion, rotation or menu return
                session.foldShown = true
            } else {
                session.foldShown = true
                withAnimation(.spring(response: 0.6, dampingFraction: 0.82).delay(0.12)) {
                    unfolded = true
                }
            }
        }
    }

    /// Closing the lid puts the game to sleep; holding wakes it back up.
    private var lidOverlay: some View {
        LidClosedOverlay(fullScreen: false)
            .padding(.top, 6)
            .padding(.bottom, 8)
    }

    /// Translucent round button floating over game pixels (portrait's back
    /// bubble; matches landscape's corner circles).
    private func floatingCircle<Icon: View>(action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            ButtonHaptics.shared.tap()
            action()
        } label: {
            ZStack {
                Circle().fill(Color(rgba: 28, 28, 30, 0.8))
                Circle().stroke(Palette.hairline12, lineWidth: 0.5)
                icon()
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(ScalePressStyle())
    }

    private var controlsArea: some View {
        GeometryReader { geo in
            TouchControlsView(layout: .portraitDefault,
                              metrics: metrics,
                              size: geo.size,
                              showBlow: model.settings.showMicButton,
                              showFastForward: model.settings.showFastForwardButton,
                              onKeys: { session.setTouchKeys($0) },
                              onMenu: { model.openSheet(.quickMenu) },
                              onMic: { session.setMicHeld($0) },
                              onFastForward: { model.toggleFastForward() })
        }
        .padding(.top, 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// The sleeping-lid cover. Waking takes a deliberate half-second hold — a
/// stray tap must never reopen a lid you closed on purpose. The zZz swells
/// while the hold charges. (Face-down sleep still reopens on pickup.)
private struct LidClosedOverlay: View {
    @EnvironmentObject private var session: EmulatorSession
    @Environment(\.theme) private var theme
    let fullScreen: Bool
    @GestureState private var holding = false

    var body: some View {
        ZStack {
            if fullScreen {
                Color.black.opacity(0.88)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.well.opacity(0.97))
            }
            VStack(spacing: 8) {
                Text("zZz")
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accentText)
                Text("Lid closed · hold to open")
                    .font(Typography.meta13)
                    .foregroundColor(Palette.textTertiary)
            }
            .scaleEffect(holding ? 1.12 : 1)
            .animation(.easeOut(duration: 0.4), value: holding)
        }
        .contentShape(Rectangle())
        .gesture(
            LongPressGesture(minimumDuration: 0.5, maximumDistance: 30)
                .updating($holding) { pressing, state, _ in state = pressing }
                .onEnded { _ in
                    ButtonHaptics.shared.tap()
                    session.openLid()
                }
        )
    }
}

// MARK: - Landscape

struct LandscapeGameView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: EmulatorSession
    @Environment(\.theme) private var theme
    /// Full screen size (safe area ignored).
    let size: CGSize
    let safeArea: EdgeInsets

    private let metrics = ControlMetrics(isLandscape: true)

    /// Controls live inside the safe insets so nothing sits under the Dynamic
    /// Island, the rounded corners or the home indicator.
    private var controlsRect: CGRect {
        CGRect(x: safeArea.leading,
               y: 0,
               width: size.width - safeArea.leading - safeArea.trailing,
               height: size.height - safeArea.bottom)
    }

    var body: some View {
        let book = model.settings.bookMode
        // Book pages: both screens turned the same way; righty reads
        // top-screen-left / touch-right, lefty the mirror. Swap is a
        // non-book concept, so book mode ignores it.
        let swap = book == .off ? model.settings.swapScreens : (book == .leftHanded)
        let fill = model.settings.screenFit == .fill
        let rotation = book.rotation
        ZStack(alignment: .topLeading) {
            Color.black

            // Two screens side by side, centred, as large as the height allows
            // (Fill hands each exactly half the display).
            HStack(spacing: book == .off ? 8 : 14) {
                DSScreenView(store: swap ? session.bottomStore : session.topStore,
                             filter: model.settings.filter,
                             isTouchScreen: swap,
                             cornerRadius: 4,
                             fill: fill,
                             bookRotation: rotation)
                    .frame(width: fill ? (size.width - 8) / 2 : nil,
                           height: fill ? size.height : nil)
                DSScreenView(store: swap ? session.topStore : session.bottomStore,
                             filter: model.settings.filter,
                             isTouchScreen: !swap,
                             cornerRadius: 4,
                             fill: fill,
                             bookRotation: rotation)
                    .frame(width: fill ? (size.width - 8) / 2 : nil,
                           height: fill ? size.height : nil)
            }
            .frame(width: size.width, height: size.height)

            // Overlay controls at the configured opacity.
            TouchControlsView(layout: .landscapeDefault,
                              metrics: metrics,
                              size: controlsRect.size,
                              showBlow: model.settings.showMicButton,
                              showFastForward: model.settings.showFastForwardButton,
                              onKeys: { session.setTouchKeys($0) },
                              onMenu: { model.openSheet(.quickMenu) },
                              onMic: { session.setMicHeld($0) },
                              onFastForward: { model.toggleFastForward() })
                .opacity(model.settings.controlOpacity)
                .frame(width: controlsRect.width, height: controlsRect.height)
                .offset(x: controlsRect.minX, y: controlsRect.minY)

            // Speed badge sits left of the top-centre MENU pill.
            if let label = session.speedBadgeLabel {
                FFBadge(label: label)
                    .position(x: size.width * 0.5 - 110, y: max(24, safeArea.top + 6) + 12)
            }

            if session.lidClosed {
                LidClosedOverlay(fullScreen: true)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
