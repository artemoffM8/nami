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

    private var board: BoardState? { BoardState(givens: drill.position) }

    var body: some View {
        VStack(spacing: 16) {
            header
            if let board {
                BoardView(
                    states: renderStates(board),
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
    private func renderStates(_ board: BoardState) -> [CellRenderState] {
        let premises = Set(drill.premises)
        let selectedValue = selected.map { board[$0].value } ?? 0
        return (0..<81).map { index in
            var state = CellRenderState()
            let cell = board[index]
            state.value = cell.value
            state.isGiven = cell.isGiven
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
