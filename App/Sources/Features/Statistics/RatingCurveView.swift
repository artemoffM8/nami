//
//  RatingCurveView.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Кривая рейтинга за последние партии.
//
//  Своя отрисовка, а не Swift Charts: одна линия с заливкой не стоит новой
//  зависимости, а Charts тянет собственные шрифты, оси и жесты, которые здесь
//  пришлось бы отключать по одному.
//
//  Тон намеренно спокойный. По ТЗ статистика отвечает на вопрос «в чём я стал
//  лучше», а не «сколько я потерял»: поэтому нет красной зоны, нет подписи
//  «падение» и нет сравнения с другими игроками. Провал в кривой виден, но
//  ничем не выделен.
//

import SwiftUI
import NamiDomain
import NamiExperience

struct RatingCurveView: View {

    let points: [(date: Date, rating: Int)]
    let accent: Color

    /// Ниже четырёх точек кривая — не кривая, а зигзаг из двух отрезков:
    /// он показывает шум и наводит на выводы, которых данные не содержат.
    static let minimumPoints = 4

    var body: some View {
        // Локальная копия, а не вычисляемое свойство: замыкание `Canvas`
        // выполняется вне изоляции MainActor и обращаться к свойствам View
        // из него нельзя.
        let values = points.map(\.rating)
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        // Диапазон никогда не нулевой: у прямой линии высота графика
        // обратилась бы в деление на ноль.
        let span = max(1, high - low)

        VStack(alignment: .leading, spacing: 6) {
            Canvas(rendersAsynchronously: false) { context, size in
                guard values.count >= 2 else { return }
                let step = size.width / Double(values.count - 1)

                func point(_ index: Int) -> CGPoint {
                    let normalized = Double(values[index] - low) / Double(span)
                    // Поля сверху и снизу: точка на самом краю выглядит
                    // обрезанной, а не крайней.
                    let y = size.height * (0.9 - normalized * 0.8)
                    return CGPoint(x: Double(index) * step, y: y)
                }

                var line = Path()
                line.move(to: point(0))
                for index in 1..<values.count { line.addLine(to: point(index)) }

                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [accent.opacity(0.22), accent.opacity(0)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

                context.stroke(line, with: .color(accent.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                  lineJoin: .round))

                // Последняя точка помечена: взгляд должен находить «где я
                // сейчас» без чтения подписей.
                let last = point(values.count - 1)
                context.fill(
                    Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5,
                                           width: 7, height: 7)),
                    with: .color(accent))
            }
            .frame(height: 64)
            .accessibilityElement()
            .accessibilityLabel(L.t("stats.curve.a11y", values.count, low, high))

            HStack {
                Text("\(low)")
                Spacer()
                Text("\(high)")
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
    }
}
