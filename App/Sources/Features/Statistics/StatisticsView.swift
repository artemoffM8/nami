//
//  StatisticsView.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Раздел 5.6 плюс «тихие вехи». Экран отвечает на один вопрос:
//  «в чём я стал лучше и что попробовать дальше».
//
//  Чего здесь намеренно НЕТ: общего времени в игре, серии дней с обнулением,
//  глобального места. По ТЗ такие метрики создают тревогу и не помогают расти.
//

import SwiftUI
import NamiDomain
import NamiData
import NamiExperience

struct StatisticsView: View {

    @Environment(AppRouter.self) private var router
    @Environment(ThemeProvider.self) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Вся история — один раз за загрузку экрана.
    ///
    /// Раньше `stats` было вычисляемым свойством, и каждое из ~тридцати
    /// обращений в `body` заново поднимало из SwiftData все `GameResult`,
    /// декодировало ledger каждой записи и сортировало результат. `let` в
    /// начале `body` убрал бы только повторы внутри одного прохода, но сам
    /// проход повторяется при любом изменении наблюдаемого `router` или темы —
    /// и вся история читалась бы заново. Поэтому снимок живёт в `@State`
    /// и пересобирается в `.task`: при появлении экрана и при смене
    /// рейтингового snapshot, то есть ровно тогда, когда история могла
    /// измениться.
    @State private var loaded: StatsData?

    /// Всё, что экран берёт из истории. Собирается разом, чтобы разделы
    /// не спорили между собой о том, какие данные они показывают.
    private struct StatsData {
        let stats: PlayerStatistics
        let completionDates: [Date]
        /// Сначала уже достигнутое, потом самое близкое к цели —
        /// так экран показывает результат и сразу подсказывает следующий шаг.
        let milestones: [Milestone]
        let achievedCount: Int

        @MainActor
        init(progress: ProgressRepository) {
            let stats = progress.statistics()
            let all = MilestoneCatalog.build(from: stats)
            let achieved = all.filter(\.isAchieved)
            let pending = all.filter { !$0.isAchieved }.sorted { $0.progress > $1.progress }
            self.stats = stats
            self.completionDates = progress.completionDates()
            self.milestones = achieved + pending
            self.achievedCount = achieved.count
        }
    }

    var body: some View {
        // До того как отработает `.task`, читаем историю напрямую: пустой
        // экран в первом кадре выглядел бы как потеря данных. Это один проход
        // по истории вместо тридцати пяти, и только в первом кадре.
        let data = loaded ?? StatsData(progress: router.progress)
        return NavigationStack {
            List {
                headline(data)
                garden(data)
                curve(data)
                aspects(data)
                milestones(data)
                techniques(data)
                tiers(data)
            }
            .navigationTitle(L.t("stats.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("common.close")) { dismiss() }
                }
            }
        }
        .task(id: router.snapshot) {
            loaded = StatsData(progress: router.progress)
        }
    }

    // MARK: - Шапка: рейтинг, ранг, ритм

    private func headline(_ data: StatsData) -> some View {
        let snapshot = router.snapshot
        return Section {
            if snapshot.isCalibrating {
                LabeledContent(L.t("home.rating"),
                               value: L.t("home.calibration", snapshot.calibrationRatedCount,
                         RatingEngine.calibrationCount))
            } else {
                LabeledContent(L.t("home.rating"), value: "\(snapshot.rating)")
                if let display = snapshot.displayDivision {
                    LabeledContent(L.t("stats.rank"),
                                   value: "\(L.t(display.tier.titleKey)) \(display.romanKey)")
                    rankProgress(display, rating: snapshot.rating, snapshot: snapshot)
                    // Стабильность ранга живёт только здесь, в подробностях,
                    // и намеренно без предупреждающего тона: понижение — это
                    // спокойный факт, а не угроза (раздел 9.7).
                    if let stability = snapshot.demotionRiskProgress() {
                        Text(L.t("stats.rankStability", stability))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent(L.t("stats.solved"), value: "\(data.stats.solvedTotal)")
            Text(L.t("home.rhythm", router.rhythm.completedDays))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Что именно отделяет игрока от следующей ступени.
    ///
    /// Порог можно пройти по очкам и всё равно остаться на месте: повышение
    /// подтверждается тремя результатами подряд. Пока это не показано, экран
    /// сообщает «до следующего ранга 0 очков» и выглядит сломанным — ранг не
    /// растёт, а идти до него якобы некуда. Не хватает не очков, а подтверждения,
    /// и говорить надо именно об этом.
    @ViewBuilder
    private func rankProgress(
        _ display: RankDivision, rating: Int, snapshot: RatingSnapshot
    ) -> some View {
        if display.index < 14, let distance = display.pointsToNext(from: rating) {
            if distance > 0 {
                let next = RankDivision(index: display.index + 1)
                Text(L.t("home.toNextRank",
                         "\(L.t(next.tier.titleKey)) \(next.romanKey)", distance))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Окно может быть пустым сразу после калибровки: тогда честный
                // ответ — 0 из 3, а не молчание.
                Text(L.t("home.promotionConfirmation",
                         snapshot.promotionConfirmationProgress() ?? 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Сад

    private func garden(_ data: StatsData) -> some View {
        Section {
            GardenCalendarView(
                completionDates: data.completionDates,
                personality: EffectPersonality(themeID: theme.current.id),
                tint: theme.color(.accent),
                secondary: theme.color(.secondaryText))
        } header: {
            Text(L.t("garden.title"))
        } footer: {
            Text(L.t("garden.hint"))
        }
    }

    // MARK: - Кривая рейтинга

    /// Раздел появляется только когда точек достаточно. Пустой график с
    /// подписью «данных пока нет» занимает место и ничего не сообщает.
    @ViewBuilder
    private func curve(_ data: StatsData) -> some View {
        let points = data.stats.ratingCurve()
        if points.count >= RatingCurveView.minimumPoints {
            Section {
                RatingCurveView(points: points, accent: theme.color(.accent))
            } header: {
                Text(L.t("stats.curve"))
            } footer: {
                Text(L.t("stats.curve.hint", points.count))
            }
        }
    }

    // MARK: - Три аспекта

    private func aspects(_ data: StatsData) -> some View {
        Section {
            aspectRow(L.t("progress.accuracy"), data.stats.accuracyRate,
                      hint: L.t("stats.accuracy.hint"))
            aspectRow(L.t("progress.independence"), data.stats.independenceRate,
                      hint: L.t("stats.independence.hint"))
            aspectRow(L.t("progress.logic"), data.stats.logicRate,
                      hint: L.t("stats.logic.hint"))
        } header: {
            Text(L.t("stats.aspects"))
        } footer: {
            // Серия про умение, а не про посещаемость: пропущенный день её не рвёт.
            Text(L.t("stats.cleanStreak",
                     data.stats.currentCleanStreak, data.stats.longestCleanStreak))
        }
    }

    private func aspectRow(_ title: String, _ value: Double, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: value)
                .tint(theme.color(.accent))
            Text(hint).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Вехи

    private func milestones(_ data: StatsData) -> some View {
        // Порядок и подсчёт достигнутых собраны вместе с самими данными:
        // здесь остаётся только отрисовка.
        Section {
            ForEach(data.milestones) { milestone in
                HStack(spacing: 12) {
                    Image(systemName: milestone.isAchieved
                          ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(milestone.isAchieved
                                         ? theme.color(.accent) : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L.t(milestone.titleKey))
                            .font(.subheadline)
                            .foregroundStyle(milestone.isAchieved ? .primary : .secondary)
                        if !milestone.isAchieved, milestone.target > 1 {
                            Text("\(milestone.current) / \(milestone.target)")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(L.t("stats.milestones", data.achievedCount, data.milestones.count))
        }
    }

    // MARK: - Коллекция техник

    private func techniques(_ data: StatsData) -> some View {
        let met = data.stats.techniquesMet
        return Section {
            ForEach(SudokuTechnique.allCases, id: \.self) { technique in
                HStack {
                    Text(L.t(technique.nameKey))
                        .foregroundStyle(met.contains(technique) ? .primary : .secondary)
                    Spacer()
                    Text(String(format: "%.1f", technique.rating))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    // `Color` не имеет `.tertiary` — это стиль иерархии,
                    // а тернарник здесь выводит именно Color.
                    Image(systemName: met.contains(technique) ? "checkmark" : "lock")
                        .font(.caption)
                        .foregroundStyle(met.contains(technique)
                                         ? theme.color(.accent)
                                         : theme.color(.secondaryText).opacity(0.5))
                }
            }
        } header: {
            Text(L.t("stats.techniques", met.count, data.stats.techniquesTotal))
        } footer: {
            Text(L.t("stats.techniques.hint"))
        }
    }

    // MARK: - По уровням

    private func tiers(_ data: StatsData) -> some View {
        Section {
            ForEach(DifficultyTier.allCases, id: \.self) { tier in
                // Тир читает статистику пять раз подряд — по разу на строку.
                // Раньше каждое такое чтение было ещё и выборкой из SwiftData.
                let stats = data.stats
                let solved = stats.solvedCount(in: tier)
                HStack {
                    Text(L.t(tier.titleKey))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(L.t("stats.tierSolved", solved))
                            .font(.caption)
                            .monospacedDigit()
                        if let best = stats.personalBest(in: tier) {
                            Text(L.t("challenge.personalBest", best / 60, best % 60))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        // Среднее считается только по чистым партиям: решение
                        // с подсказкой измеряет скорость подсказки, а не игрока.
                        if let average = stats.averageCleanSeconds(in: tier) {
                            Text(L.t("stats.averageTime", average / 60, average % 60))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        if let score = stats.bestScore(in: tier) {
                            Text(L.t("stats.bestScore", score))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        if stats.personalBest(in: tier) == nil, solved > 0 {
                            Text(L.t("stats.noComparable"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        } header: {
            Text(L.t("stats.byTier"))
        } footer: {
            Text(L.t("stats.comparable.hint"))
        }
    }
}
