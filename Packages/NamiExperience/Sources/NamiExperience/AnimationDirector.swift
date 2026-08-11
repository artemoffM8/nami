//
//  AnimationDirector.swift
//  NamiExperience
//
//  Created by artemoffM8.
//
//  Раздел 7.3. Слой рисует ТОЛЬКО полученную команду и никогда не владеет
//  `BoardState`: он не знает ни правил, ни того, почему группа завершилась.
//
//  Инварианты:
//   • анимация никогда не блокирует следующий ввод — overlay не принимает касания;
//   • display link живёт ровно столько, сколько длится эффект, и гасится Task-ом;
//   • Reduce Motion убирает scale, волны и частицы: остаётся короткий fade
//     и статический контур завершённой группы;
//   • частицы полностью выключаются настройкой интенсивности.
//

import SwiftUI
import NamiDomain

public struct BoardEffectOverlay: View {

    public let command: FeedbackCommand?
    public let accent: Color
    public let surface: Color
    public let reduceMotion: Bool
    /// Каким словарём тема отвечает на событие. Сама механика эффекта от него
    /// не зависит — меняется только то, чем она нарисована.
    public let personality: EffectPersonality
    public let onFinished: (UUID) -> Void

    @State private var activeID: UUID?
    @State private var startedAt: Date = .distantPast

    public init(
        command: FeedbackCommand?,
        accent: Color,
        surface: Color,
        reduceMotion: Bool,
        personality: EffectPersonality = .ink,
        onFinished: @escaping (UUID) -> Void
    ) {
        self.command = command
        self.accent = accent
        self.surface = surface
        self.reduceMotion = reduceMotion
        self.personality = personality
        self.onFinished = onFinished
    }

    // MARK: - Длительности из ТЗ

    private func duration(_ preset: AnimationPreset) -> Double {
        if reduceMotion {
            // Остаётся только короткий fade 120-180 мс.
            return preset == .boardWave ? 0.24 : 0.16
        }
        switch preset {
        case .none: return 0
        case .fade: return 0.16
        case .lineWave: return 0.32     // было 0.21: вспышка не успевала прочитаться
        case .boxBloom: return 0.38     // было 0.26: то же самое для блока
        case .boardWave: return 0.80    // 650-900 мс
        case .rankGrowth: return 1.50
        }
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            Group {
                if let command, isRunning(command) {
                    TimelineView(.animation) { timeline in
                        Canvas(rendersAsynchronously: false) { context, _ in
                            let total = duration(command.animation)
                            let elapsed = timeline.date.timeIntervalSince(startedAt)
                            let progress = total > 0 ? min(1, max(0, elapsed / total)) : 1
                            draw(command, progress: progress, side: side, in: &context)
                        }
                        .frame(width: side, height: side)
                    }
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Мутация состояния происходит в onChange, а не внутри тела TimelineView:
        // иначе SwiftUI ругается на несколько обновлений за кадр.
        .onChange(of: command?.transactionID) { _, newValue in
            guard let command, let newValue, command.animation != .none else {
                activeID = nil
                return
            }
            activeID = newValue
            startedAt = .now
            let seconds = duration(command.animation)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard activeID == newValue else { return }
                activeID = nil
                onFinished(newValue)
            }
        }
    }

    private func isRunning(_ command: FeedbackCommand) -> Bool {
        activeID == command.transactionID && command.animation != .none
    }

    // MARK: - Отрисовка

    private func draw(
        _ command: FeedbackCommand,
        progress: Double,
        side: Double,
        in context: inout GraphicsContext
    ) {
        let cell = side / 9

        switch command.animation {
        case .none:
            return

        case .fade:
            // Reduce Motion fallback и подтверждение ввода: мягкая вспышка
            // плюс статический контур, если завершилась группа.
            let alpha = sin(progress * .pi) * 0.35
            for index in command.cells {
                context.fill(rect(for: index, cell: cell), with: .color(accent.opacity(alpha)))
            }
            // Отклик темы на касание одной клетки. У группы своя анимация,
            // поверх неё круги по воде превратились бы в кашу.
            if command.cells.count == 1, !reduceMotion,
               let kind = personality.tapKind, let index = command.cells.first {
                ParticleVocabulary.draw(
                    kind: kind, cellIndex: index, origin: center(of: index, cell: cell),
                    cellSide: cell, count: 1, progress: progress,
                    color: accent, in: &context)
            }
            if command.cells.count == 9 {
                context.stroke(
                    Path(groupBounds(command.cells, cell: cell)),
                    with: .color(accent.opacity(0.55)),
                    lineWidth: 2
                )
            }

        case .lineWave:
            drawLineWave(command.cells, progress: progress, cell: cell, in: &context)
            drawParticles(command, progress: progress, cell: cell, in: &context)

        case .boxBloom:
            drawBoxBloom(command.cells, progress: progress, cell: cell, in: &context)
            drawParticles(command, progress: progress, cell: cell, in: &context)

        case .boardWave:
            drawBoardWave(progress: progress, side: side, cell: cell, in: &context)
            drawParticles(command, progress: progress, cell: cell, in: &context)

        case .rankGrowth:
            let alpha = sin(progress * .pi) * 0.25
            context.fill(
                Path(CGRect(x: 0, y: 0, width: side, height: side)),
                with: .color(accent.opacity(alpha))
            )
        }
    }

    /// Направленная световая волна вдоль строки или столбца.
    private func drawLineWave(
        _ cells: [Int],
        progress: Double,
        cell: Double,
        in context: inout GraphicsContext
    ) {
        guard let first = cells.first else { return }
        let isRow = cells.allSatisfy { BoardTopology.rowOf[$0] == BoardTopology.rowOf[first] }

        for index in cells {
            // Позиция клетки вдоль направления волны, 0...1.
            let position = Double(isRow ? BoardTopology.columnOf[index]
                                        : BoardTopology.rowOf[index]) / 8.0
            // Гребень шириной 0.35 проходит от начала к концу линии.
            let distance = abs(progress * 1.35 - 0.175 - position)
            let intensity = max(0, 1 - distance / 0.45)
            guard intensity > 0 else { continue }
            context.fill(
                rect(for: index, cell: cell),
                with: .color(accent.opacity(0.72 * intensity))
            )
        }
        // Контур всей линии держится дольше гребня: именно он читается как
        // «группа закрыта», а бегущая волна — только способ это показать.
        let outline = 1 - progress
        context.stroke(
            Path(groupBounds(cells, cell: cell)),
            with: .color(accent.opacity(0.85 * outline)),
            lineWidth: 2.5
        )
    }

    /// Мягкая radial-wave от центра блока 3×3.
    private func drawBoxBloom(
        _ cells: [Int],
        progress: Double,
        cell: Double,
        in context: inout GraphicsContext
    ) {
        let bounds = groupBounds(cells, cell: cell)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = bounds.width * 0.5 * (0.35 + progress * 1.05)
        let alpha = (1 - progress) * 0.78

        let circle = Path(ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))
        context.fill(
            circle,
            with: .radialGradient(
                Gradient(colors: [accent.opacity(alpha), accent.opacity(0)]),
                center: center, startRadius: 0, endRadius: radius
            )
        )
        context.stroke(Path(bounds), with: .color(accent.opacity(alpha)), lineWidth: 2.5)
    }

    /// Победа: волна по всей сетке и галочка в конце.
    private func drawBoardWave(
        progress: Double,
        side: Double,
        cell: Double,
        in context: inout GraphicsContext
    ) {
        for index in 0..<81 {
            // Диагональная развёртка: чем дальше клетка, тем позже её очередь.
            let position = Double(BoardTopology.rowOf[index] + BoardTopology.columnOf[index]) / 16.0
            let distance = abs(progress * 1.4 - 0.2 - position)
            let intensity = max(0, 1 - distance / 0.3)
            guard intensity > 0 else { continue }
            context.fill(
                rect(for: index, cell: cell),
                with: .color(accent.opacity(0.40 * intensity))
            )
        }

        // Галочка проявляется во второй половине.
        guard progress > 0.55 else { return }
        let appear = (progress - 0.55) / 0.45
        var check = Path()
        let unit = side * 0.10
        let origin = CGPoint(x: side * 0.5 - unit, y: side * 0.5)
        check.move(to: origin)
        check.addLine(to: CGPoint(x: origin.x + unit * 0.8, y: origin.y + unit * 0.8))
        check.addLine(to: CGPoint(x: origin.x + unit * 2.2, y: origin.y - unit * 0.9))
        context.stroke(
            check,
            with: .color(accent.opacity(min(1, appear) * 0.85)),
            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        )
    }

    /// Частицы. Смещения детерминированы по индексу клетки — никакого RNG,
    /// поэтому эффект одинаков в снапшот-тестах.
    private func drawParticles(
        _ command: FeedbackCommand,
        progress: Double,
        cell: Double,
        in context: inout GraphicsContext
    ) {
        guard command.particleCount > 0, !reduceMotion else { return }

        // Словарь темы: у закрытой группы своя реакция в каждой теме.
        // «Высокий контраст» сюда не попадает намеренно — там остаётся
        // только нейтральная россыпь ниже.
        if let kind = personality.groupKind, !command.cells.isEmpty {
            let anchors = groupAnchors(command.cells, cell: cell)
            for (ordinal, index) in anchors.enumerated() {
                // Стаггер по углам: одновременная вспышка в четырёх точках
                // читается как мигание экрана, а не как событие.
                let delay = Double(ordinal) * 0.10
                let local = (progress - delay) / max(0.01, 1 - delay)
                guard local > 0, local <= 1 else { continue }
                ParticleVocabulary.draw(
                    kind: kind, cellIndex: index,
                    origin: center(of: index, cell: cell), cellSide: cell,
                    count: max(2, command.particleCount / 2), progress: local,
                    color: accent, in: &context)
            }
            return
        }

        let anchor: CGRect = command.cells.isEmpty
            ? CGRect(x: cell * 3, y: cell * 3, width: cell * 3, height: cell * 3)
            : groupBounds(command.cells, cell: cell)
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        let alpha = (1 - progress) * 0.45
        // Стартовое смещение обязательно: иначе на progress = 0 все частицы
        // складываются в одну точку и закрывают собой цифру под собой.
        let travel = cell * (0.45 + 1.5 * progress)

        for particle in 0..<command.particleCount {
            let angle = Double(particle) / Double(command.particleCount) * 2 * .pi
                + Double(particle &* 37 % 11) * 0.05
            let spread = 0.6 + Double((particle &* 53) % 7) / 10.0
            let point = CGPoint(
                x: center.x + cos(angle) * travel * spread,
                y: center.y + sin(angle) * travel * spread
            )
            let size = cell * 0.10 * (1 - progress * 0.5)
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - size, y: point.y - size,
                                       width: size * 2, height: size * 2)),
                with: .color(accent.opacity(alpha))
            )
        }
    }

    // MARK: - Геометрия

    private func center(of index: Int, cell: Double) -> CGPoint {
        CGPoint(x: (Double(BoardTopology.columnOf[index]) + 0.5) * cell,
                y: (Double(BoardTopology.rowOf[index]) + 0.5) * cell)
    }

    /// Точки, из которых бьёт реакция группы: углы для блока, концы для линии.
    /// Из центра эффект читается как «что-то мигнуло», из углов — как контур.
    private func groupAnchors(_ cells: [Int], cell: Double) -> [Int] {
        let sorted = cells.sorted()
        guard let first = sorted.first, let last = sorted.last else { return [] }
        let rows = Set(sorted.map { BoardTopology.rowOf[$0] })
        let columns = Set(sorted.map { BoardTopology.columnOf[$0] })
        // Линия: два конца. Блок 3×3: четыре угла.
        guard rows.count > 1, columns.count > 1 else { return [first, last] }
        let minRow = rows.min() ?? 0, maxRow = rows.max() ?? 0
        let minColumn = columns.min() ?? 0, maxColumn = columns.max() ?? 0
        return [minRow * 9 + minColumn, minRow * 9 + maxColumn,
                maxRow * 9 + maxColumn, maxRow * 9 + minColumn]
    }

    private func rect(for index: Int, cell: Double) -> Path {
        Path(CGRect(
            x: Double(BoardTopology.columnOf[index]) * cell,
            y: Double(BoardTopology.rowOf[index]) * cell,
            width: cell, height: cell
        ))
    }

    private func groupBounds(_ cells: [Int], cell: Double) -> CGRect {
        guard !cells.isEmpty else { return .zero }
        let columns = cells.map { BoardTopology.columnOf[$0] }
        let rows = cells.map { BoardTopology.rowOf[$0] }
        let minX = Double(columns.min() ?? 0) * cell
        let minY = Double(rows.min() ?? 0) * cell
        let maxX = Double((columns.max() ?? 0) + 1) * cell
        let maxY = Double((rows.max() ?? 0) + 1) * cell
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
