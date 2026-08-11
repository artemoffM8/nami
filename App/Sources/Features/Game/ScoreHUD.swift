//
//  ScoreHUD.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  «Пульс партии» — отдельная полоса между шапкой и сеткой.
//
//  Почему полоса, а не значок в шапке. Счёт меняется на каждом ходу, и если
//  он живёт над сеткой, то каждое изменение сдвигает поле. Отдельная полоса с
//  собственной минимальной высотой 44 pt гарантирует, что сетка не двигается
//  и ни одна из 81 клетки не теряет площадь касания.
//
//  Позиция под дельту ОДНА и зарезервирована всегда. Второго центра
//  уведомлений над клавиатурой нет: два бегущих числа читаются как шум.
//

import SwiftUI
import NamiDomain
import NamiExperience

struct ScoreHUD: View {

    let score: SessionScoreState
    let pendingCount: Int
    let delta: GameSessionStore.ScoreDelta?
    let palette: CellPalette
    let accent: Color
    let primary: Color
    let secondary: Color
    let reduceMotion: Bool

    /// При крупных системных шрифтах полоса переносится на две строки и
    /// растёт в высоту. Уменьшать шрифт ради фиксированной высоты нельзя.
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isCompact: Bool { typeSize <= .xxLarge }

    var body: some View {
        Group {
            if isCompact {
                HStack(alignment: .center, spacing: 10) {
                    scoreText
                    Spacer(minLength: 4)
                    deltaSlot
                    Spacer(minLength: 4)
                    multiplierCapsule
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        scoreText
                        Spacer()
                        multiplierCapsule
                    }
                    deltaSlot
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Части

    private var scoreText: some View {
        HStack(spacing: 6) {
            Text("\(score.displayScore)")
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(primary)
            // В отложенной валидации показываем только счётчик ожидания:
            // сколько ходов ждёт, но НЕ какие из них верны.
            if pendingCount > 0 {
                Text(L.t("score.pending", pendingCount))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(secondary)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22),
                   value: score.displayScore)
    }

    /// Ширина слота постоянна: появление числа не должно двигать соседей.
    private var deltaSlot: some View {
        ZStack {
            if let delta {
                VStack(spacing: 1) {
                    Text(delta.value >= 0 ? "+\(delta.value)" : "\(delta.value)")
                        .font(.caption.weight(.medium)).monospacedDigit()
                    if let key = delta.reasonKey {
                        Text(L.t(key))
                            .font(.system(size: 9))
                            .foregroundStyle(secondary)
                    }
                }
                // Штраф обозначается знаком и текстом, а не только цветом.
                .foregroundStyle(delta.value >= 0 ? accent : secondary)
                .transition(reduceMotion
                            ? .opacity
                            : .offset(y: 5).combined(with: .opacity))
                .id(delta.id)
            }
        }
        .frame(minWidth: 74)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: delta?.id)
    }

    private var multiplierCapsule: some View {
        VStack(spacing: 3) {
            Text(multiplierText)
                .font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(accent.opacity(0.14)))

            // Волосяная линия прогресса до следующей ступени. Это НЕ таймер:
            // она заполняется только верными ходами и сама не убывает.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(secondary.opacity(0.25))
                    Capsule()
                        .fill(accent.opacity(0.75))
                        .frame(width: max(2, proxy.size.width * score.tierProgress))
                }
            }
            .frame(width: 52, height: 2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3),
                       value: score.tierProgress)
        }
        // Декоративная линия скрыта от VoiceOver.
        .accessibilityHidden(true)
    }

    // MARK: - Текст

    /// Множитель хранится в промилле; делить на 100 нельзя — выйдет ×10.
    private var multiplierText: String {
        "×" + (Double(score.multiplierPermille) / 1000)
            .formatted(.number.precision(.fractionLength(1)))
    }

    /// Полоса — один элемент доступности. Прогресс неподтверждённых ходов
    /// к множителю не озвучивается: это раскрыло бы их правильность.
    private var accessibilityText: String {
        if pendingCount > 0 {
            return L.t("score.a11y.pending", score.displayScore, pendingCount)
        }
        var text = L.t("score.a11y.live", score.displayScore, multiplierText)
        if let moves = score.movesToNextTier, moves > 0 {
            text += ". " + L.t("score.a11y.toNextTier", moves)
        }
        return text
    }
}
