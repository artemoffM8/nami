//
//  BoardView.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Отрисовка сетки (раздел 13.5). Три решения ради 60 fps и P95 < 100 мс:
//   • `CellView` получает компактный `CellRenderState`, а не весь `BoardState`;
//   • палитра резолвится ОДИН раз в `BoardView` и передаётся как Equatable-значение,
//     поэтому смена наблюдаемой темы не инвалидирует 81 view по отдельности;
//   • линии сетки рисуются одним `Canvas` поверх, а не бордерами 81 клетки.
//
//  `.drawingGroup()` намеренно НЕ ставится на всю доску: он допустим только
//  для изолированного overlay после проверки резкости текста и памяти.
//

import SwiftUI
import NamiDomain
import NamiExperience

struct CellPalette: Equatable {
    var surface: Color
    var given: Color
    var user: Color
    var note: Color
    var assisted: Color
    var selected: Color
    var related: Color
    var sameDigit: Color
    var conflict: Color
    var focusRing: Color

    /// `ThemeProvider` изолирован на MainActor, поэтому палитра резолвится тоже там.
    /// Дальше она передаётся в клетки как обычное Equatable-значение.
    @MainActor
    init(theme: ThemeProvider) {
        surface = theme.color(.boardSurface)
        given = theme.color(.givenDigit)
        user = theme.color(.userDigit)
        note = theme.color(.manualNote)
        assisted = theme.color(.assistedCandidate)
        selected = theme.color(.selectedCell)
        related = theme.color(.relatedCell)
        sameDigit = theme.color(.sameDigit)
        conflict = theme.color(.conflict)
        focusRing = theme.color(.focusRing)
    }
}

struct BoardView: View {

    let states: [CellRenderState]
    let palette: CellPalette
    let thinLine: Double
    let thickLine: Double
    let largeDigits: Bool
    /// Команда feedback, которую рисует overlay. Доска о ней ничего не знает.
    var effect: FeedbackCommand?
    var reduceMotion = false
    /// Словарь эффектов текущей темы. Доска его не выбирает — только передаёт.
    var personality: EffectPersonality = .ink
    var onEffectFinished: (UUID) -> Void = { _ in }
    let onSelect: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let cell = side / 9

            ZStack(alignment: .topLeading) {
                // Строки и столбцы вместо ZStack + .offset: так рамка клетки
                // и её область касания совпадают, а размер сетки не зависит
                // от того, какой размер предложил родитель.
                VStack(spacing: 0) {
                    ForEach(0..<9, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<9, id: \.self) { column in
                                let index = row * 9 + column
                                CellView(
                                    state: states.indices.contains(index)
                                        ? states[index] : CellRenderState(),
                                    palette: palette,
                                    size: cell,
                                    largeDigits: largeDigits,
                                    reduceMotion: reduceMotion,
                                    reaction: reaction(for: index)
                                )
                                .equatable()
                                .frame(width: cell, height: cell)
                                .contentShape(Rectangle())
                                .onTapGesture { onSelect(index) }
                                .accessibilityElement()
                                .accessibilityLabel(accessibilityLabel(index))
                                .accessibilityAddTraits(
                                    states.indices.contains(index) && states[index].isSelected
                                        ? [.isButton, .isSelected] : .isButton
                                )
                            }
                        }
                    }
                }

                GridLinesView(side: side, thin: thinLine, thick: thickLine, palette: palette)
                    .allowsHitTesting(false)

                // Эффекты рисуются ПОВЕРХ поля и не меняют layout 81 клетки.
                BoardEffectOverlay(
                    command: effect,
                    accent: palette.focusRing,
                    surface: palette.surface,
                    reduceMotion: reduceMotion,
                    personality: personality,
                    onFinished: onEffectFinished
                )
                .frame(width: side, height: side)
            }
            .frame(width: side, height: side)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .contain)
    }

    /// Реакция конкретной клетки на текущую команду.
    ///
    /// Считается здесь, а не в сессии: это чистая функция от команды, и
    /// хранить её негде — реакция живёт 300 мс и не должна попадать
    /// ни в автосохранение, ни в VoiceOver.
    private func reaction(for index: Int) -> CellReaction {
        guard let effect, !reduceMotion, effect.cells.contains(index) else {
            return .inactive
        }
        switch effect.cue {
        case .none:
            return .inactive

        case .error:
            let kind = personality.errorReaction
            guard kind != .none else { return .inactive }
            return CellReaction(kind: kind, token: effect.transactionID)

        case .group:
            let kind = personality.groupReaction
            guard kind != .none else { return .inactive }
            // Волна идёт по диагонали группы: одновременный подъём девяти
            // клеток читается как рывок всей доски, а не как событие.
            let row = BoardTopology.rowOf[index] % 3
            let column = BoardTopology.columnOf[index] % 3
            return CellReaction(kind: kind, token: effect.transactionID,
                                delay: Double(row + column) * 0.05)
        }
    }

    /// VoiceOver: ручные и подсказанные кандидаты озвучиваются РАЗДЕЛЬНО,
    /// чтобы overlay не выдавался за ввод игрока (раздел 15).
    private func accessibilityLabel(_ index: Int) -> String {
        guard states.indices.contains(index) else { return "" }
        let state = states[index]
        var parts = [L.t("a11y.cell", BoardTopology.rowOf[index] + 1,
                         BoardTopology.columnOf[index] + 1)]
        if state.value != 0 {
            parts.append(state.isGiven
                ? L.t("a11y.given", Int(state.value))
                : L.t("a11y.userDigit", Int(state.value)))
        } else {
            parts.append(L.t("a11y.empty"))
            if state.manualNotes != 0 {
                parts.append(L.t("a11y.notes", list(state.manualNotes)))
            }
            if state.assistedCandidates != 0 {
                parts.append(L.t("a11y.assistedCandidates", list(state.assistedCandidates)))
            }
        }
        if state.isConflict { parts.append(L.t("a11y.conflict")) }
        return parts.joined(separator: ", ")
    }

    private func list(_ mask: DigitMask) -> String {
        Digits.list(mask).map(String.init).joined(separator: ", ")
    }
}

/// Линии блоков 2–2.5 pt, линии клеток 0.5–0.75 pt (раздел 6.1).
private struct GridLinesView: View {
    let side: Double
    let thin: Double
    let thick: Double
    let palette: CellPalette

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            let step = side / 9
            for index in 0...9 {
                let position = Double(index) * step
                let isThick = index % 3 == 0
                let width = isThick ? thick : thin
                let color = isThick ? palette.focusRing.opacity(0.55) : palette.note.opacity(0.35)

                var vertical = Path()
                vertical.move(to: CGPoint(x: position, y: 0))
                vertical.addLine(to: CGPoint(x: position, y: side))
                context.stroke(vertical, with: .color(color), lineWidth: width)

                var horizontal = Path()
                horizontal.move(to: CGPoint(x: 0, y: position))
                horizontal.addLine(to: CGPoint(x: side, y: position))
                context.stroke(horizontal, with: .color(color), lineWidth: width)
            }
        }
        .frame(width: side, height: side)
    }
}

struct CellView: View, Equatable {

    let state: CellRenderState
    let palette: CellPalette
    let size: Double
    let largeDigits: Bool
    var reduceMotion = false
    var reaction: CellReaction = .inactive

    /// Явное сравнение: body пересчитывается только при реальном изменении клетки.
    /// `nonisolated`, потому что `View` неявно изолирован на MainActor,
    /// а `Equatable.==` — нет. Все поля здесь — Sendable-значения.
    ///
    /// Реакция входит в сравнение: без неё клетка с неизменившимся состоянием
    /// не получила бы новый токен и не вздрогнула бы на второй ошибке подряд.
    nonisolated static func == (lhs: CellView, rhs: CellView) -> Bool {
        lhs.state == rhs.state
        && lhs.size == rhs.size
        && lhs.largeDigits == rhs.largeDigits
        && lhs.reduceMotion == rhs.reduceMotion
        && lhs.palette == rhs.palette
        && lhs.reaction == rhs.reaction
    }

    /// Приоритет отрисовки: конфликт, выбранная, та же цифра, связанная, поверхность.
    private var background: Color {
        if state.isConflict { return palette.conflict.opacity(0.16) }
        if state.isSelected { return palette.selected }
        if state.isSameDigit { return palette.sameDigit }
        if state.isRelated { return palette.related }
        return .clear
    }

    private var digitColor: Color {
        if state.isConflict { return palette.conflict }
        return state.isGiven ? palette.given : palette.user
    }

    var body: some View {
        ZStack {
            background

            if state.isHintFocus {
                Rectangle().fill(palette.focusRing.opacity(0.20))
            }

            if state.value != 0 {
                Text(String(state.value))
                    .font(.system(size: size * (largeDigits ? 0.66 : 0.56),
                                  weight: state.isGiven ? .semibold : .regular,
                                  design: .default))
                    .monospacedDigit()
                    .foregroundStyle(digitColor)
                    // Цвет не единственный сигнал: конфликт ещё и подчёркнут.
                    .underline(state.isConflict || state.isVerifiedWrong)
                    // Появление цифры: scale 0.92 -> 1.0 + opacity, 150-180 мс.
                    // При Reduce Motion остаётся только fade.
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.92).combined(with: .opacity)
                    )
                    .id(state.value)
            } else if state.manualNotes != 0 || state.assistedCandidates != 0 {
                NotesGrid(
                    manual: state.manualNotes,
                    assisted: state.assistedCandidates,
                    palette: palette,
                    size: size
                )
            }

            if state.isSelected {
                Rectangle()
                    .strokeBorder(palette.focusRing, lineWidth: 2)
                    // Один мягкий импульс при выборе, без бесконечного цикла.
                    .transition(reduceMotion ? .opacity
                                             : .scale(scale: 1.12).combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
        // Реакция применяется поверх содержимого и не трогает frame:
        // сетка из 81 клетки не должна пересчитываться из-за дрожания одной.
        .modifier(CellReactionModifier(reaction: reaction, reduceMotion: reduceMotion))
        // Смена выделения 100-140 мс, появление цифры 150-180 мс.
        .animation(reduceMotion ? .easeOut(duration: 0.14)
                                : .easeOut(duration: 0.12), value: state.isSelected)
        .animation(reduceMotion ? .easeOut(duration: 0.16)
                                : .spring(response: 0.18, dampingFraction: 0.72),
                   value: state.value)
    }
}

/// Девять позиций 3×3 внутри клетки. Ручная заметка визуально побеждает
/// подсказанного кандидата при совпадении (раздел 4.5).
private struct NotesGrid: View {
    let manual: DigitMask
    let assisted: DigitMask
    let palette: CellPalette
    let size: Double

    var body: some View {
        let cell = size / 3
        let fontSize = size * 0.22
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { column in
                        let digit = row * 3 + column + 1
                        let isManual = Digits.contains(manual, digit)
                        let isAssisted = !isManual && Digits.contains(assisted, digit)
                        Text(isManual || isAssisted ? String(digit) : " ")
                            .font(.system(size: fontSize, weight: isManual ? .regular : .light))
                            .monospacedDigit()
                            .foregroundStyle(isManual ? palette.note : palette.assisted)
                            .opacity(isAssisted ? 0.8 : 1)
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
    }
}
