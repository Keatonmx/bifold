//
//  ControlViews.swift
//  Bifold
//
//  The drawn controls. They are purely visual: touches are handled by
//  MultiTouchInputView so several buttons can be held at once.
//

import SwiftUI

/// Chosen press-glow style (Settings › Controls), injected at the app root.
private struct PressGlowKey: EnvironmentKey {
    static let defaultValue: PressGlow = .accent
}
extension EnvironmentValues {
    var pressGlow: PressGlow {
        get { self[PressGlowKey.self] }
        set { self[PressGlowKey.self] = newValue }
    }
}

/// Visual press state: translateY(1px), slight dip, and a *lightening* — on a
/// dark theme a pressed control should read as lit, not sunk to black.
private struct PressedLook: ViewModifier {
    let pressed: Bool
    var scale: CGFloat = 1
    func body(content: Content) -> some View {
        content
            .offset(y: pressed ? 1 : 0)
            .scaleEffect(pressed ? scale : 1)
            .brightness(pressed ? 0.07 : 0)
            .animation(.easeOut(duration: 0.06), value: pressed)
    }
}

struct DPadView: View {
    @Environment(\.skin) private var skin
    @Environment(\.theme) private var theme
    @Environment(\.pressGlow) private var glowStyle
    let metrics: ControlMetrics
    let pressed: Bool
    var highlight: DSKeyMask = []

    private var glowColor: Color { glowStyle == .accent ? theme.accent : .white }

    var body: some View {
        let size = metrics.dpad
        let arm = metrics.dpadArm
        let radius = metrics.dpadRadius
        ZStack {
            // Vertical arm
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(skin.padGradient)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(stops: verticalStops, startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Palette.hairline10, lineWidth: 0.5))
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.horizontal, radius) }
                .shadow(color: .black.opacity(0.4), radius: 4, y: 3)
                .frame(width: arm, height: size)
            // Horizontal arm
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(skin.padGradient)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(stops: horizontalStops, startPoint: .leading, endPoint: .trailing)))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Palette.hairline10, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.4), radius: 4, y: 3)
                .frame(width: size, height: arm)
            // Arrows: 30% white idle; the pressed one lights up in the glow colour.
            Group {
                arrow(.up).position(x: size / 2, y: 11 + 4.5)
                arrow(.down).rotationEffect(.degrees(180)).position(x: size / 2, y: size - 11 - 4.5)
                arrow(.left).rotationEffect(.degrees(-90)).position(x: 11 + 4.5, y: size / 2)
                arrow(.right).rotationEffect(.degrees(90)).position(x: size - 11 - 4.5, y: size / 2)
            }
            // Recessed centre dot
            Circle()
                .fill(Color.black.opacity(0.25))
                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1).blur(radius: 1).mask(Circle()))
                .frame(width: 22, height: 22)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.06), value: highlight)
        // No PressedLook: the pad body stays constant and only the pressed
        // direction's end + arrow light up.
    }

    /// Vertical arm: glow at the top when Up is held, at the bottom for Down.
    private var verticalStops: [Gradient.Stop] {
        directionalStops(first: highlight.contains(.up), second: highlight.contains(.down))
    }
    /// Horizontal arm: glow at the leading end for Left, trailing for Right.
    private var horizontalStops: [Gradient.Stop] {
        directionalStops(first: highlight.contains(.left), second: highlight.contains(.right))
    }

    private func directionalStops(first: Bool, second: Bool) -> [Gradient.Stop] {
        let peak = glowStyle == .accent ? 0.5 : 0.4
        return [.init(color: glowColor.opacity(first ? peak : 0), location: 0),
                .init(color: glowColor.opacity(0), location: 0.5),
                .init(color: glowColor.opacity(second ? peak : 0), location: 1)]
    }

    private func arrow(_ key: DSKeyMask) -> some View {
        let active = highlight.contains(key)
        return Triangle()
            .fill(active ? glowColor.opacity(0.95) : Color.white.opacity(0.3))
            .frame(width: 12, height: 9)
            .shadow(color: active ? glowColor.opacity(0.7) : .clear, radius: 4)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct FaceButtonView: View {
    @Environment(\.skin) private var skin
    @Environment(\.theme) private var theme
    @Environment(\.pressGlow) private var glowStyle
    let label: String
    let metrics: ControlMetrics
    let pressed: Bool

    private var accentRing: Bool { pressed && glowStyle == .accent }

    var body: some View {
        Circle()
            .fill(skin.buttonGradient)
            .overlay(Circle().stroke(Palette.hairline14, lineWidth: 0.5))
            .overlay(
                Circle().stroke(theme.accent.opacity(accentRing ? 0.9 : 0), lineWidth: 2)
                    .shadow(color: theme.accent.opacity(accentRing ? 0.6 : 0), radius: 6))
            .overlay(alignment: .top) {
                Circle().stroke(Color.white.opacity(0.16), lineWidth: 1.5).padding(1).mask(
                    LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
            }
            .shadow(color: .black.opacity(0.45), radius: 5, y: 4)
            .overlay(
                Text(label)
                    .font(.system(size: metrics.faceFont, weight: .bold))
                    .foregroundColor(Palette.text85))
            .frame(width: metrics.face, height: metrics.face)
            .modifier(PressedLook(pressed: pressed, scale: 0.96))
    }
}

struct ShoulderPillView: View {
    @Environment(\.skin) private var skin
    let label: String
    let metrics: ControlMetrics
    let pressed: Bool

    var body: some View {
        Capsule()
            .fill(skin.padGradient)
            .overlay(Capsule().stroke(Palette.hairline10, lineWidth: 0.5))
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.horizontal, 14) }
            .shadow(color: .black.opacity(0.35), radius: 2.5, y: 2)
            .overlay(Text(label).font(.system(size: metrics.shoulderFont, weight: .bold)).foregroundColor(Palette.text75))
            .frame(width: metrics.shoulder.width, height: metrics.shoulder.height)
            .modifier(PressedLook(pressed: pressed))
    }
}

struct BottomPillView: View {
    @Environment(\.skin) private var skin
    @Environment(\.theme) private var theme
    let label: String
    let metrics: ControlMetrics
    let pressed: Bool
    var accent = false
    /// Power-LED colour (nil == no LED).
    var led: Color? = nil

    var body: some View {
        Group {
            if accent {
                Capsule()
                    .fill(metrics.isLandscape ? AnyShapeStyle(skin.padGradient) : AnyShapeStyle(theme.tint))
                    // Landscape overlays sit on bright game pixels: keep a solid base under the tint.
                    .overlay(Capsule().fill(metrics.isLandscape ? theme.tint2 : Color.clear))
                    .overlay(Capsule().stroke(metrics.isLandscape ? theme.tintBorder2 : theme.tintBorder, lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                    .overlay(
                        Text(label).font(.system(size: metrics.pillFont, weight: .bold)).tracking(1)
                            .foregroundColor(metrics.isLandscape ? theme.accentText2 : theme.accentText))
            } else {
                Capsule()
                    .fill(skin.padGradient)
                    .overlay(Capsule().stroke(Palette.hairline10, lineWidth: 0.5))
                    .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1).padding(.horizontal, 14) }
                    .shadow(color: .black.opacity(0.35), radius: 2.5, y: 2)
                    .overlay(
                        Text(label).font(.system(size: metrics.pillFont, weight: .bold)).tracking(1)
                            .foregroundColor(metrics.isLandscape ? Palette.text65 : Palette.textSecondary))
            }
        }
        .overlay(alignment: .trailing) {
            // The power LED: green while the core runs, amber while paused.
            if let led {
                Circle()
                    .fill(led)
                    .frame(width: 5, height: 5)
                    .shadow(color: led.opacity(0.9), radius: 3)
                    .padding(.trailing, 9)
            }
        }
        .frame(width: metrics.pill.width, height: metrics.pill.height)
        .modifier(PressedLook(pressed: pressed))
    }
}

/// The MIC button: hold to blow into the emulated microphone. While held it
/// pulses in the accent colour, like a level meter catching wind.
struct BlowButtonView: View {
    @Environment(\.theme) private var theme
    @Environment(\.skin) private var skin
    let metrics: ControlMetrics
    let pressed: Bool

    var body: some View {
        Circle()
            .fill(pressed ? AnyShapeStyle(theme.accent) : AnyShapeStyle(skin.buttonGradient))
            .overlay(Circle().stroke(Palette.hairline12, lineWidth: 0.5))
            .shadow(color: pressed ? theme.accent.opacity(0.6) : .black.opacity(0.35), radius: pressed ? 8 : 3, y: 2)
            .overlay(
                VStack(spacing: 1) {
                    MicGlyph(color: pressed ? .white : Palette.textSecondary)
                        .frame(width: 10, height: 15)
                    Text("MIC").font(.system(size: 7, weight: .bold)).tracking(0.5)
                        .foregroundColor(pressed ? .white : Palette.textTertiary)
                }
            )
            .frame(width: metrics.blow, height: metrics.blow)
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.06), value: pressed)
    }
}

/// A tiny drawn microphone: capsule head on a stand.
struct MicGlyph: View {
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .top) {
                Capsule().fill(color).frame(width: w * 0.56, height: h * 0.62)
                    .frame(maxWidth: .infinity)
                ArcShape()
                    .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .frame(width: w, height: h * 0.5)
                    .offset(y: h * 0.32)
                Rectangle().fill(color).frame(width: 1.4, height: h * 0.16)
                    .offset(y: h * 0.82)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

struct ArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.minY),
                 radius: rect.width / 2,
                 startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
        return p
    }
}

struct FFBadge: View {
    @Environment(\.theme) private var theme
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .bold))
            .tracking(0.5)
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(theme.badge)
            .clipShape(Capsule())
    }
}
