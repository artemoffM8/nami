//
//  ResultView.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Раздел 5.5 и 9.6. Одна карточка, одна главная причина, breakdown из
//  не более четырёх строк, сумма которых ВСЕГДА равна применённому ΔR.
//  Сырая формула, E и K в интерфейсе не показываются никогда.
//

import SwiftUI
import NamiDomain
import NamiExperience

struct ResultView: View {

    let payload: AppRouter.ResultPayload

    @Environment(AppRouter.self) private var router
    @Environment(ThemeProvider.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Разбор раскрывается только явным действием.
    @State private var showBreakdown = false
    /// Переход ступени показывается ОДИН раз поверх результата и сам себя
    /// закрывает: событие приходит из домена уже применённым.
    @State private var rankChangeShown = false
    @AccessibilityFocusState private var headlineFocused: Bool

    var body: some View {
        content.overlay {
            if let event = payload.event, !rankChangeShown {
                RankChangeOverlay(
                    from: RankDivision(index: event.fromDivision ?? event.toDivision),
                    to: RankDivision(index: event.toDivision),
                    rating: router.snapshot.rating,
                    theme: theme,
                    reduceMotion: reduceMotion,
                    onFinished: { rankChangeShown = true }
                )
                .transition(.opacity)
            }
        }
    }

    /// Очки за партию с разбором: игрок должен видеть, из чего сложился счёт
    /// и что именно срезало множитель.
    /// Итог по макету спецификации: крупное число, одна строка сводки,
    /// и разбор ТОЛЬКО после явного действия «Как начислено».
    ///
    /// Разбор скрыт не ради красоты: четыре строки сразу превращают экран
    /// победы в отчёт. Кому нужно — раскроет.
    @ViewBuilder
    private func scoreCard(_ score: SessionScoreState) -> some View {
        VStack(spacing: 6) {
            Text(L.t("score.total"))
                .font(.caption)
                .foregroundStyle(theme.color(.secondaryText))

            Text("\(score.displayScore)")
                .font(.system(size: 44, weight: .light)).monospacedDigit()
                .foregroundStyle(theme.color(.primaryText))
                .contentTransition(.numericText())

            // Сводка одной строкой: максимум множителя, ошибки, время.
            Text(summaryLine(score))
                .font(.caption)
                .foregroundStyle(theme.color(.secondaryText))

            if !score.isRecordable {
                Text(L.t("score.practiceResult"))
                    .font(.caption2)
                    .foregroundStyle(theme.color(.secondaryText))
            }

            Button(showBreakdown ? L.t("common.close") : L.t("result.howCounted")) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.17)) {
                    showBreakdown.toggle()
                }
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(theme.color(.accent))
            .frame(minWidth: 44, minHeight: 44)
            .padding(.top, 2)

            if showBreakdown {
                VStack(spacing: 3) {
                    scoreLine(L.t("score.placements"), score.placementTotal)
                    scoreLine(L.t("score.groups"), score.structureTotal)
                    if score.effectivePenalty > 0 {
                        scoreLine(L.t("score.errors"), -score.effectivePenalty)
                    }
                    if score.paceBonus > 0 {
                        scoreLine(L.t("score.pace"), score.paceBonus)
                    }
                    // Непогашенный штраф — подпись, а не пятая строка суммы.
                    if score.penaltyRemainder > 0 {
                        Text(L.t("score.debt", score.penaltyRemainder))
                            .font(.caption2)
                            .foregroundStyle(theme.color(.secondaryText))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(L.t("score.timeNeutral"))
                        .font(.caption2)
                        .foregroundStyle(theme.color(.secondaryText))
                        .padding(.top, 2)
                }
                .font(.caption)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
    }

    /// Готовые значения доступности присутствуют сразу: VoiceOver не должен
    /// озвучивать промежуточные шаги счётчика.
    private func summaryLine(_ score: SessionScoreState) -> String {
        var parts = [L.t("score.maxMultiplier",
                         (Double(score.maxMultiplierPermille) / 1000)
                             .formatted(.number.precision(.fractionLength(1))))]
        parts.append(L.t("score.errorCount", score.confirmedErrorStrikes))
        parts.append(String(format: "%d:%02d",
                            payload.activeSeconds / 60, payload.activeSeconds % 60))
        return parts.joined(separator: " · ")
    }

    private func scoreLine(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value >= 0 ? "+\(value)" : "\(value)").monospacedDigit()
        }
        .foregroundStyle(theme.color(value >= 0 ? .primaryText : .secondaryText))
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        ZStack {
            ClaritySpaceView(
                tier: router.snapshot.bestTier,
                detailLevel: router.snapshot.bestDivision?.detailLevel ?? 0,
                state: .dimmedStill,
                theme: theme.current,
                reduceMotion: reduceMotion
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()

                VStack(spacing: 10) {
                    // Прерванная попытка не называется решением.
                    Text(L.t(payload.wasSolved ? "result.solved" : "result.attemptEnded"))
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($headlineFocused)

                    if payload.rating.isRanked {
                        Text(L.t("result.rating", payload.rating.newRating))
                            .font(.title3)
                            .monospacedDigit()
                        Text(deltaText)
                            .font(.system(size: 34, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(payload.rating.deltaR >= 0
                                             ? theme.color(.accent) : theme.color(.conflict))
                    } else {
                        Text(L.t("result.practice"))
                            .font(.title3)
                            .foregroundStyle(theme.color(.secondaryText))
                    }

                    // Одна главная причина, выбранная детерминированным reason code.
                    // Повтор и провал Perfect получают собственную формулировку:
                    // это не Reveal и не «третья ошибка».
                    Text(L.t(payload.overrideReasonKey
                             ?? payload.rating.reason.localizationKey))
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.color(.secondaryText))

                    if let best = payload.personalBestSeconds {
                        Text(L.t("result.personalBest", best / 60, best % 60))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(theme.color(.secondaryText))
                    }

                    if let score = payload.dailyScore {
                        Text("Daily Score \(score)")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(theme.color(.secondaryText))
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(theme.color(.boardSurface).opacity(0.9))
                )

                if showBreakdown { breakdown }

                Spacer()

                if let score = payload.score {
                    scoreCard(score)
                }

                if let done = payload.calibrationProgress {
                    // Калибровка молчала: игрок доигрывал партии и не понимал,
                    // засчитались они или нет.
                    Text(L.t("home.calibration", done, RatingEngine.calibrationCount))
                        .font(.caption)
                        .foregroundStyle(theme.color(.secondaryText))
                }

                VStack(spacing: 10) {
                    Button(L.t("result.moreLikeThis")) { router.repeatSimilar() }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.color(.accent))
                    Button(L.t("result.toHome")) { router.goHome() }
                        .buttonStyle(.bordered)
                    Button(L.t("result.howCounted")) {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            showBreakdown.toggle()
                        }
                    }
                    .font(.footnote)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
        .onAppear { headlineFocused = true }
    }

    private var deltaText: String {
        payload.rating.deltaR >= 0 ? "+\(payload.rating.deltaR)" : "\(payload.rating.deltaR)"
    }

    /// Четыре человеческие категории. Строка показывается, только если она ненулевая
    /// или является основной «Сложностью».
    private var breakdown: some View {
        let b = payload.rating.breakdown
        return VStack(spacing: 6) {
            line(L.t("result.line.challenge"), b.challengeDelta, always: true)
            line(L.t("result.line.assist"), b.assistDelta)
            line(L.t("result.line.guess"), b.guessDelta)
            line(L.t("result.line.speed"), b.speedBonus)
            Divider()
            HStack {
                Text(L.t("result.total")).font(.subheadline.weight(.semibold))
                Spacer()
                Text(deltaText).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.color(.boardSurface).opacity(0.7))
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func line(_ title: String, _ value: Int, always: Bool = false) -> some View {
        if value != 0 || always {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(value >= 0 ? "+\(value)" : "\(value)")
                    .font(.subheadline)
                    .monospacedDigit()
            }
        }
    }
}
