//
//  RankBadgeView.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Знак ранга и шкала продвижения внутри ступени.
//
//  Иконки рисуются кодом, а не лежат картинками. Причины:
//   • 15 ступеней × 3 размера × 2 темы = сотня файлов, которые рассинхронятся;
//   • нарисованный знак берёт цвет из активной темы, картинка — нет;
//   • векторная фигура остаётся резкой на любом Dynamic Type.
//
//  По ТЗ (раздел 6.4) знак абстрактный: свет, горизонт, дуги, поле.
//  Фигуративных элементов — короны, кубки, звёзды — быть не должно:
//  они обещают соревнование, а приложение обещает ясность.
//

import SwiftUI
import NamiDomain
import NamiExperience

struct RankBadgeView: View {

    let division: RankDivision
    let size: CGFloat
    let accent: Color
    let surface: Color
    /// Приглушённый вариант для ещё не достигнутых ступеней.
    var isDimmed: Bool = false

    private var tint: Color { isDimmed ? accent.opacity(0.28) : accent }

    var body: some View {
        Canvas { context, canvasSize in
            let side = min(canvasSize.width, canvasSize.height)
            let rect = CGRect(x: (canvasSize.width - side) / 2,
                              y: (canvasSize.height - side) / 2,
                              width: side, height: side)
            drawPlate(&context, in: rect)
            drawTierGlyph(&context, in: rect)
            drawDetailMarks(&context, in: rect)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(Self.title(for: division))
    }

    static func title(for division: RankDivision) -> String {
        "\(L.t(division.tier.titleKey)) \(division.romanKey)"
    }

    // MARK: - Слои знака

    /// Общая для всех ступеней подложка: мягкий шестиугольник.
    private func drawPlate(_ context: inout GraphicsContext, in rect: CGRect) {
        let path = plateShape(in: rect.insetBy(dx: rect.width * 0.04, dy: rect.width * 0.04))
        context.fill(path, with: .color(surface.opacity(isDimmed ? 0.25 : 0.55)))
        context.stroke(path, with: .color(tint.opacity(0.85)), lineWidth: rect.width * 0.035)
    }

    private func plateShape(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        for index in 0..<6 {
            // Вершиной вверх: -90° старт.
            let angle = Double(index) / 6 * 2 * .pi - .pi / 2
            let point = CGPoint(x: center.x + cos(angle) * radius,
                                y: center.y + sin(angle) * radius)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    /// Мотив тира. Каждый следующий — «больше света» на том же поле.
    private func drawTierGlyph(_ context: inout GraphicsContext, in rect: CGRect) {
        let inner = rect.insetBy(dx: rect.width * 0.26, dy: rect.width * 0.26)
        let line = rect.width * 0.045
        let stroke = GraphicsContext.Shading.color(tint)

        switch division.tier {
        case .observer:
            // Горизонт: одна прямая — всё ещё только наблюдение.
            var path = Path()
            path.move(to: CGPoint(x: inner.minX, y: inner.midY))
            path.addLine(to: CGPoint(x: inner.maxX, y: inner.midY))
            context.stroke(path, with: stroke, lineWidth: line)

        case .logician:
            // Восход: горизонт плюс дуга над ним.
            var path = Path()
            path.move(to: CGPoint(x: inner.minX, y: inner.maxY))
            path.addLine(to: CGPoint(x: inner.maxX, y: inner.maxY))
            context.stroke(path, with: stroke, lineWidth: line)
            var arc = Path()
            arc.addArc(center: CGPoint(x: inner.midX, y: inner.maxY),
                       radius: inner.width * 0.42,
                       startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            context.stroke(arc, with: stroke, lineWidth: line)

        case .strategist:
            // Плоскости: три смещённые линии — взгляд с разных сторон.
            for offset in [-0.28, 0.0, 0.28] {
                var path = Path()
                let y = inner.midY + inner.height * offset
                let inset = inner.width * abs(offset) * 0.6
                path.move(to: CGPoint(x: inner.minX + inset, y: y))
                path.addLine(to: CGPoint(x: inner.maxX - inset, y: y))
                context.stroke(path, with: stroke, lineWidth: line)
            }

        case .architect:
            // Свод: две вложенные дуги на общем основании.
            for scale in [0.46, 0.28] {
                var arc = Path()
                arc.addArc(center: CGPoint(x: inner.midX, y: inner.maxY),
                           radius: inner.width * scale,
                           startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                context.stroke(arc, with: stroke, lineWidth: line)
            }
            var base = Path()
            base.move(to: CGPoint(x: inner.minX, y: inner.maxY))
            base.addLine(to: CGPoint(x: inner.maxX, y: inner.maxY))
            context.stroke(base, with: stroke, lineWidth: line)

        case .master:
            // Поле: замкнутый круг со светом внутри — ничего не осталось снаружи.
            let circle = Path(ellipseIn: inner)
            context.fill(circle, with: .radialGradient(
                Gradient(colors: [tint.opacity(0.55), tint.opacity(0)]),
                center: CGPoint(x: inner.midX, y: inner.midY),
                startRadius: 0, endRadius: inner.width * 0.55))
            context.stroke(circle, with: stroke, lineWidth: line)
        }
    }

    /// Ступень внутри тира: одна, две или три засечки под знаком.
    private func drawDetailMarks(_ context: inout GraphicsContext, in rect: CGRect) {
        let count = division.detailLevel + 1
        let width = rect.width * 0.09
        let gap = rect.width * 0.05
        let total = CGFloat(count) * width + CGFloat(count - 1) * gap
        var x = rect.midX - total / 2
        let y = rect.maxY - rect.height * 0.14
        for _ in 0..<count {
            let mark = Path(roundedRect: CGRect(x: x, y: y, width: width, height: rect.width * 0.028),
                            cornerRadius: rect.width * 0.014)
            context.fill(mark, with: .color(tint))
            x += width + gap
        }
    }
}

// MARK: - Шкала внутри ступени

/// Прогресс между нижней границей текущей ступени и следующей.
/// Именно она даёт ощущение движения: сам рейтинг меняется на единицы,
/// а полоса — на заметную долю.
struct RankProgressBar: View {

    let rating: Int
    let division: RankDivision
    let accent: Color
    let track: Color

    private var fraction: Double {
        guard let upper = division.upperBound else { return 1 }
        let span = Double(upper - division.lowerBound + 1)
        guard span > 0 else { return 1 }
        return min(1, max(0, Double(rating - division.lowerBound) / span))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(track.opacity(0.35))
                    Capsule()
                        .fill(accent)
                        .frame(width: max(3, proxy.size.width * fraction))
                        .animation(.easeOut(duration: 0.6), value: fraction)
                }
            }
            .frame(height: 6)

            HStack {
                Text(RankBadgeView.title(for: division))
                Spacer()
                if let remaining = division.pointsToNext(from: rating) {
                    Text(L.t("rank.pointsToNext", remaining))
                } else {
                    Text(L.t("rank.top"))
                }
            }
            .font(.caption2)
            .foregroundStyle(track)
        }
        .accessibilityElement(children: .combine)
    }
}
