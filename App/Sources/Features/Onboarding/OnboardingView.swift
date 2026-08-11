//
//  OnboardingView.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Раздел 5.1. Мини-обучение сразу на настоящем поле: на доске остаются
//  3–4 пустые клетки, поэтому первая победа наступает меньше чем за минуту.
//  Кнопка «Я уже умею» видна на каждом шаге. Регистрация, уведомления,
//  Game Center, трекинг и покупки НЕ запрашиваются до первой решённой задачи.
//

import SwiftUI
import NamiDomain
import NamiData
import NamiExperience

struct OnboardingView: View {

    @Environment(AppRouter.self) private var router
    @Environment(ThemeProvider.self) private var theme
    @Environment(PreferencesRepository.self) private var preferences

    @State private var board: BoardState = OnboardingView.makeMiniBoard()
    @State private var derived = BoardDerivedState()
    @State private var selected: Int?
    @State private var notesMode = false
    @State private var step = 0
    @State private var showProfileChoice = false
    @State private var chosenProfile: AssistanceProfile = .focus

    private static let miniPuzzle =
        "534678912672195348198342567859761423426853791713924856961537284287419635345286179"
    /// Четыре пустые клетки — первая победа меньше чем за минуту.
    private static let removed = [4, 22, 40, 58]

    static func makeMiniBoard() -> BoardState {
        var characters = Array(miniPuzzle)
        for index in removed { characters[index] = "0" }
        return BoardState(givens: String(characters)) ?? BoardState()
    }

    private var palette: CellPalette { CellPalette(theme: theme) }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button(L.t("onboarding.skip")) { finish() }
                    .font(.subheadline)
            }

            Text(promptText)
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            BoardView(
                states: renderStates,
                palette: palette,
                thinLine: theme.current.thinLineWidth,
                thickLine: theme.current.thickLineWidth,
                largeDigits: preferences.largeDigits,
                onSelect: { select($0) }
            )

            HStack(spacing: 8) {
                Button {
                    notesMode.toggle()
                    if step == 2 { advance() }
                } label: {
                    Label(L.t("game.notes"), systemImage: "pencil")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(notesMode ? theme.color(.accent) : nil)
            }

            KeypadView(
                illegalDigits: 0,
                completedDigits: 0,
                lockedDigit: nil,
                layout: .adaptive,
                palette: palette,
                onTap: { input($0) },
                onLongPress: { _ in }
            )
        }
        .padding(16)
        .background(theme.color(.appBackground).ignoresSafeArea())
        .onAppear { derived = SudokuValidator.derive(board) }
        .sheet(isPresented: $showProfileChoice) { profileSheet.themedSurface() }
    }

    private var promptText: String {
        switch step {
        case 0: L.t("onboarding.step1")
        case 1: L.t("onboarding.step2")
        case 2: L.t("onboarding.step3")
        default: L.t("onboarding.done")
        }
    }

    private var renderStates: [CellRenderState] {
        (0..<81).map { index in
            var state = CellRenderState()
            let cell = board[index]
            state.value = cell.value
            state.isGiven = cell.isGiven
            state.manualNotes = cell.manualNotesMask
            state.isSelected = index == selected
            state.isRelated = selected.map { $0 != index && BoardTopology.sees($0, index) } ?? false
            state.isConflict = derived.conflicts.contains(index)
            return state
        }
    }

    private func select(_ index: Int) {
        guard board[index].value == 0 || !board[index].isGiven else { return }
        selected = index
        if step == 0, board[index].value == 0 { advance() }
    }

    private func input(_ digit: Int) {
        guard let index = selected, !board[index].isGiven else { return }
        var cell = board[index]
        if notesMode {
            cell.manualNotesMask ^= Digits.bit(digit)
        } else {
            cell.value = UInt8(digit)
            cell.manualNotesMask = 0
        }
        board[index] = cell
        derived = SudokuValidator.derive(board)
        if step == 1, !notesMode { advance() }
        if derived.isSolvedByRules { showProfileChoice = true }
    }

    private func advance() {
        step = min(step + 1, 3)
    }

    /// После мини-задачи один раз предлагаем профиль с рекомендацией «Фокус».
    private var profileSheet: some View {
        VStack(spacing: 16) {
            Text(L.t("assistance.chooseTitle")).font(.title3.weight(.semibold))
            ForEach(AssistanceProfile.allCases, id: \.self) { item in
                Button {
                    chosenProfile = item
                    finish()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L.t(item.titleKey)).font(.headline)
                            if item == .focus {
                                Text(L.t("assistance.recommended"))
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(theme.color(.selectedCell)))
                            }
                        }
                        Text(L.t(item.summaryKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme.color(.boardSurface))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .presentationDetents([.medium])
    }

    private func finish() {
        router.progress.store(assistanceProfile: chosenProfile, policy: nil)
        router.completeOnboarding()
    }
}

/// Одноразовый InterfaceCoach (раздел 5.1): регистрирует показ карточки ДО
/// первого самостоятельного нажатия и после двух карточек выключается.
struct InterfaceCoachCard: View {
    let textKey: String
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            Text(L.t(textKey))
                .font(.footnote)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.thinMaterial)
                )
        }
        .buttonStyle(.plain)
        // Карточка не блокирует поле.
        .allowsHitTesting(true)
    }
}
