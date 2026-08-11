//
//  GardenGlyph.swift
//  NamiExperience
//
//  Created by artemoffM8.
//
//  Знак завершённого дня: камешек, звезда или цветок — по теме.
//
//  Глиф рисуется кодом, а не берётся из ассетов. Причина не в размере бандла,
//  а в цвете: тема меняет палитру целиком, и растровый камешек остался бы
//  бежевым на тёмном фоне. Canvas получает цвета аргументами и не знает,
//  из какой темы они пришли.
//
//  Тот же глиф используется в календаре и в отметке освоенной техники: сад и
//  тренировка должны говорить одним языком, иначе это два разных приложения
//  в одном.
//

import SwiftUI

public struct GardenGlyph: View {

    public let personality: EffectPersonality
    public let tint: Color
    public let secondary: Color
    public let size: Double

    public init(personality: EffectPersonality, tint: Color,
                secondary: Color, size: Double = 18) {
        self.personality = personality
        self.tint = tint
        self.secondary = secondary
        self.size = size
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { context, canvas in
            let width = canvas.width, height = canvas.height
            let center = CGPoint(x: width / 2, y: height / 2)

            switch personality {
            case .ink:
                drawPebble(width, height, tint, secondary, &context)
            case .cosmos:
                drawStar(center, width, tint, &context)
            case .grove:
                drawFlower(center, width, height, tint, secondary, &context)
            case .plain:
                // Без декора: закрашенный круг читается так же однозначно,
                // а рисунок конкурировал бы с цифрами за внимание.
                let radius = width * 0.32
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                           width: radius * 2, height: radius * 2)),
                    with: .color(tint))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Камешек: два овала со смещением дают объём без градиента.
    private func drawPebble(
        _ width: Double, _ height: Double,
        _ tint: Color, _ secondary: Color, _ context: inout GraphicsContext
    ) {
        context.fill(
            Path(ellipseIn: CGRect(x: width * 0.18, y: height * 0.42,
                                   width: width * 0.64, height: height * 0.42)),
            with: .color(tint.opacity(0.75)))
        context.fill(
            Path(ellipseIn: CGRect(x: width * 0.30, y: height * 0.20,
                                   width: width * 0.42, height: height * 0.34)),
            with: .color(tint))
        context.fill(
            Path(ellipseIn: CGRect(x: width * 0.38, y: height * 0.25,
                                   width: width * 0.12, height: height * 0.08)),
            with: .color(secondary.opacity(0.6)))
    }

    /// Четырёхлучевая звезда: лучи вогнутыми дугами, иначе получается крест.
    private func drawStar(
        _ center: CGPoint, _ width: Double, _ tint: Color,
        _ context: inout GraphicsContext
    ) {
        var star = Path()
        let long = width * 0.42, short = width * 0.12
        star.move(to: CGPoint(x: center.x, y: center.y - long))
        star.addQuadCurve(to: CGPoint(x: center.x + long, y: center.y),
                          control: CGPoint(x: center.x + short, y: center.y - short))
        star.addQuadCurve(to: CGPoint(x: center.x, y: center.y + long),
                          control: CGPoint(x: center.x + short, y: center.y + short))
        star.addQuadCurve(to: CGPoint(x: center.x - long, y: center.y),
                          control: CGPoint(x: center.x - short, y: center.y + short))
        star.addQuadCurve(to: CGPoint(x: center.x, y: center.y - long),
                          control: CGPoint(x: center.x - short, y: center.y - short))

        let glow = width * 0.5
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow,
                                   width: glow * 2, height: glow * 2)),
            with: .radialGradient(Gradient(colors: [tint.opacity(0.30), tint.opacity(0)]),
                                  center: center, startRadius: 0, endRadius: glow))
        context.fill(star, with: .color(tint))
    }

    /// Цветок: пять лепестков по кругу и сердцевина.
    private func drawFlower(
        _ center: CGPoint, _ width: Double, _ height: Double,
        _ tint: Color, _ secondary: Color, _ context: inout GraphicsContext
    ) {
        for index in 0..<5 {
            var petal = context
            petal.translateBy(x: center.x, y: center.y)
            petal.rotate(by: .radians(Double(index) / 5 * 2 * .pi))
            petal.fill(
                Path(ellipseIn: CGRect(x: -width * 0.10, y: -height * 0.46,
                                       width: width * 0.20, height: height * 0.34)),
                with: .color(tint.opacity(0.9)))
        }
        let core = width * 0.22
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - core / 2, y: center.y - core / 2,
                                   width: core, height: core)),
            with: .color(secondary))
    }
}
