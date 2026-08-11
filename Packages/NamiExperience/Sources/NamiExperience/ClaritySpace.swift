//
//  ClaritySpace.swift
//  NamiExperience
//
//  Created by artemoffM8.
//
//  «Пространство ясности» (разделы 4.3, 9.8): только свет, линия горизонта,
//  дуги, плоскости и бумажное зерно. Фигуративные элементы — листья, цветы,
//  птицы, домики, лица, тела — ЗАПРЕЩЕНЫ и не должны появляться в коде.
//
//  Во время партии фон полностью неподвижен и дополнительно приглушён
//  на 15-25% относительно Home; display link для `.static` не запускается.
//

import SwiftUI
import NamiDomain

public enum GameBackgroundState: Equatable, Sendable {
    /// Home: свет может очень медленно меняться, если Reduce Motion выключен.
    case ambient
    /// Во время партии: полностью неподвижно и приглушено.
    case still
    /// Пауза и результат: статично, допускается очень слабое изменение света.
    case dimmedStill

    public var opacityScale: Double {
        switch self {
        case .ambient: 1.0
        case .still: 0.79        // приглушение на 21% — внутри диапазона 15-25%
        case .dimmedStill: 0.72
        }
    }

    public var allowsDisplayLink: Bool { self == .ambient }
}

/// Абстрактная композиция из 15 стадий: `(tier, detailLevel)`.
public struct ClaritySpaceView: View {

    public let tier: RankTier?
    public let detailLevel: Int
    public let state: GameBackgroundState
    public let theme: ThemeDefinition
    public let reduceMotion: Bool

    public init(
        tier: RankTier?,
        detailLevel: Int,
        state: GameBackgroundState,
        theme: ThemeDefinition,
        reduceMotion: Bool
    ) {
        self.tier = tier
        self.detailLevel = detailLevel
        self.state = state
        self.theme = theme
        self.reduceMotion = reduceMotion
    }

    private var accent: Color {
        Color(hexString: theme.hex(.accent) ?? "#2F7774") ?? .teal
    }

    private var surface: Color {
        Color(hexString: theme.hex(.appBackground) ?? "#F1ECE1") ?? .gray
    }

    private var animates: Bool {
        state.allowsDisplayLink && !reduceMotion
    }

    public var body: some View {
        Group {
            if animates {
                // Фаза выводится ПРЯМО из timeline и никуда не пишется:
                // мутация @State внутри TimelineView даёт несколько обновлений
                // за кадр и ломает рендер-цикл.
                TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { timeline in
                    canvas(phase: timeline.date.timeIntervalSinceReferenceDate * 0.18)
                }
            } else {
                // `.static` и Reduce Motion: display link не запускается вообще.
                canvas(phase: 0)
            }
        }
        .opacity(state.opacityScale)
        .allowsHitTesting(false)
        .background(surface)
        .accessibilityHidden(true)
    }

    private func canvas(phase: Double) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            draw(in: &context, size: size, phase: phase)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, phase: Double) {
        let horizonY = size.height * (0.58 - 0.03 * Double(detailLevel))
        let stage = tier?.rawValue ?? -1
        let light = accent.opacity(0.10 + 0.02 * Double(detailLevel))
        let drift = animates ? sin(phase) * 6 : 0

        // Стадия 1+: световое пятно за линией.
        if stage >= 1 {
            let glowRect = CGRect(
                x: size.width * 0.18,
                y: horizonY - size.height * 0.34 + drift,
                width: size.width * 0.64,
                height: size.height * 0.42
            )
            context.fill(
                Path(ellipseIn: glowRect),
                with: .radialGradient(
                    Gradient(colors: [light, light.opacity(0)]),
                    center: CGPoint(x: glowRect.midX, y: glowRect.midY),
                    startRadius: 0,
                    endRadius: glowRect.width * 0.5
                )
            )
        }

        // Стадия 2+: несколько полупрозрачных плоскостей.
        if stage >= 2 {
            for index in 0..<(2 + detailLevel) {
                let inset = Double(index) * size.width * 0.08
                var plane = Path()
                plane.move(to: CGPoint(x: inset, y: horizonY + Double(index) * 10))
                plane.addLine(to: CGPoint(x: size.width - inset, y: horizonY + Double(index) * 16))
                plane.addLine(to: CGPoint(x: size.width - inset, y: size.height))
                plane.addLine(to: CGPoint(x: inset, y: size.height))
                plane.closeSubpath()
                context.fill(plane, with: .color(accent.opacity(0.035)))
            }
        }

        // Стадия 3+: одна сдержанная дуга и её отражение.
        if stage >= 3 {
            var arc = Path()
            arc.addArc(
                center: CGPoint(x: size.width * 0.5, y: horizonY + size.height * 0.30),
                radius: size.width * 0.42,
                startAngle: .degrees(200),
                endAngle: .degrees(340),
                clockwise: false
            )
            context.stroke(arc, with: .color(accent.opacity(0.22)), lineWidth: 1.2)
            context.opacity = 0.35
            context.stroke(arc, with: .color(accent.opacity(0.10)), lineWidth: 3)
            context.opacity = 1
        }

        // Стадия 4: собранное поле света, линий и воздуха.
        if stage >= 4 {
            for index in 0..<(3 + detailLevel) {
                let y = horizonY - Double(index + 1) * size.height * 0.05
                var line = Path()
                line.move(to: CGPoint(x: size.width * 0.12, y: y))
                line.addLine(to: CGPoint(x: size.width * 0.88, y: y))
                context.stroke(line, with: .color(accent.opacity(0.06)), lineWidth: 0.75)
            }
        }

        // Линия горизонта есть на всех стадиях, включая Наблюдателя.
        var horizon = Path()
        horizon.move(to: CGPoint(x: 0, y: horizonY + drift * 0.3))
        horizon.addLine(to: CGPoint(x: size.width, y: horizonY + drift * 0.3))
        context.stroke(horizon, with: .color(accent.opacity(0.28)), lineWidth: 0.8)

        // Бумажное зерно: низкоконтрастный статичный шум.
        context.opacity = 0.05
        for index in stride(from: 0, to: 240, by: 1) {
            let x = Double((index &* 7919) % 997) / 997.0 * size.width
            let y = Double((index &* 6151) % 991) / 991.0 * size.height
            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: 1.1, height: 1.1)),
                with: .color(.black)
            )
        }
        context.opacity = 1
    }
}

