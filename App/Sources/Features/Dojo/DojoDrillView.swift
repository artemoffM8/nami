//
//  DojoDrillView.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Одно упражнение: найти единственный ход, который здесь даёт техника.
//
//  Доска — та же `BoardView`, что и в игре. Своя упрощённая сетка была бы
//  быстрее в написании и вреднее по сути: тренировка должна выглядеть ровно
//  так, как выглядит игра, иначе навык не переносится.
//
//  По той же причине доска показывает кандидатов из `drill.solverGrid()`, а
//  не одни цифры позиции. Решатель нашёл шаг, глядя на кандидатов, суженных
//  предыдущими вычерками; экран без них показывал бы ДРУГУЮ позицию — с
//  вернувшимися кандидатами и с более простым ходом, который игрок и найдёт
//  вместо изучаемой техники.
//
//  Здесь НЕТ таймера, счёта и рейтинга. Тренировка — единственное место
//  приложения, где ошибаться ничего не стоит; добавить сюда цену значит
//  сделать её ещё одним местом, где страшно.
//

import SwiftUI
import NamiDomain
import NamiData
import NamiExperience

struct DojoDrillView: View {

    let drill: DojoDrill
    let lesson: DojoLesson

    @Environment(AppRouter.self) private var router
    @Environment(ThemeProvider.self) private var theme
    @Environment(PreferencesRepository.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Int?
    @State private var outcome: Outcome = .pending
    @State private var showPremises = false

    private enum Outcome: Equatable {
        case pending, wrong, solved
    }

    /// Позиция упражнения глазами решателя: цифры И кандидаты с уже
    /// накопленными вычерками.
    ///
    /// Одно значение на двоих — намеренно. 81 символ `drill.position`
    /// выражает только цифры, а шаг был найден на суженных кандидатах.
    /// Доска из одних цифр возвращает вычеркнутых кандидатов обратно, а
    /// вместе с ними — тот более простой ход, который их и вычеркнул:
    /// игрок ищет и находит его вместо изучаемой техники. Поэтому цифры
    /// без кандидатов на экран не попадают ни при каких обстоятельствах.
    private var position: (board: BoardState, candidates: [DigitMask])? {
        guard let board = BoardState(givens: drill.position),
              let grid = drill.solverGrid() else { return nil }
        return (board, grid.candidates)
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            // `nil` здесь означает только одно: `drill.position` — не позиция
            // (не 81 допустимый символ). Такой дрилл невозможно ни показать,
            // ни решить, и доска не рисуется вовсе. Откатиться на «легальные
            // по строке, столбцу и блоку» было бы хуже пустого экрана:
            // получилась бы авторитетно выглядящая, но чужая позиция.
            if let position {
                BoardView(
                    states: renderStates(position.board, candidates: position.candidates),
                    palette: CellPalette(theme: theme),
                    thinLine: theme.current.thinLineWidth,
                    thickLine: theme.current.thickLineWidth,
                    largeDigits: preferences.largeDigits,
                    onSelect: { selected = $0 }
                )
                .padding(.horizontal, 2)
            }
            keypad
            footer
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color(.appBackground).ignoresSafeArea())
        .preferredColorScheme(theme.current.preferredColorScheme)
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                Button(L.t("common.close")) { dismiss() }
                Spacer()
                Text(L.t(lesson.titleKey)).font(.headline)
                Spacer()
                Button(L.t("dojo.show")) { showPremises = true }
                    .disabled(showPremises || outcome == .solved)
            }
            Text(drill.expectsPlacement
                 ? L.t("dojo.task.place")
                 : L.t("dojo.task.eliminate"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !drill.priorEliminations.isEmpty {
                // Оговорка появляется только там, где она правда. Если
                // вычерков не было, пометки совпадают с «легальными по
                // строке, столбцу и блоку», и фраза про вычеркнутое
                // сбивала бы с толку на ровном месте.
                Text(L.t("dojo.notesArePosition"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var keypad: some View {
        HStack(spacing: 6) {
            ForEach(1...9, id: \.self) { digit in
                Button {
                    answer(digit)
                } label: {
                    Text("\(digit)")
                        .font(.title3.monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(selected == nil || outcome == .solved)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch outcome {
        case .pending:
            Text(L.t("dojo.hintTapCell"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .wrong:
            // Тон нейтральный: «не тот ход», а не «неверно». Ошибка в
            // тренировке — это данные, а не провал.
            Text(L.t("dojo.notThisMove"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .solved:
            VStack(spacing: 10) {
                Text(L.t("dojo.found"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.color(.accent))
                Button(L.t("common.done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func answer(_ digit: Int) {
        guard let cell = selected, outcome != .solved else { return }
        let correct = drill.expectsPlacement
            ? drill.isCorrect(cell: cell, digit: digit)
            : drill.isCorrect(elimination: Elimination(cell: cell, digit: digit))
        guard correct else {
            outcome = .wrong
            return
        }
        outcome = .solved
        preferences.registerDojoDrill(drill.technique)
    }

    /// Состояния клеток строятся вручную: доска здесь статична, домашняя
    /// сессия не задействована и заводить её ради одного экрана незачем.
    private func renderStates(_ board: BoardState,
                              candidates: [DigitMask]) -> [CellRenderState] {
        let premises = Set(drill.premises)
        let selectedValue = selected.map { board[$0].value } ?? 0
        return (0..<81).map { index in
            var state = CellRenderState()
            let cell = board[index]
            state.value = cell.value
            state.isGiven = cell.isGiven
            // Кандидаты решателя едут в `assistedCandidates`, а не в
            // `manualNotes`: игрок их не писал, и VoiceOver обязан называть
            // их подсказанными. Рисует их та же `NotesGrid` игровой доски —
            // второго пути для пометок в приложении нет и заводить его
            // нельзя: тренировка должна выглядеть ровно как игра.
            //
            // Заполненные клетки пометок не получают сами собой: у решателя
            // кандидаты поставленной клетки обнулены, а `CellView` при
            // непустом значении рисует цифру, а не сетку заметок — как и в
            // игре, где `assistedCandidates` считаются только для пустых.
            state.assistedCandidates = candidates.indices.contains(index)
                ? candidates[index] : 0
            state.isSelected = index == selected
            state.isSameDigit = cell.value != 0 && cell.value == selectedValue
            if let selected {
                state.isRelated = BoardTopology.peers[selected].contains(index)
            }
            // Подсказка показывает область вывода — то же, что первый слой
            // подсказки в игре, и по той же причине: сначала «где смотреть».
            state.isHintFocus = showPremises && premises.contains(index)
            return state
        }
    }
}
