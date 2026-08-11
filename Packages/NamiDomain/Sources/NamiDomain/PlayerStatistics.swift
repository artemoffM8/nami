//
//  PlayerStatistics.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Статистика и «тихие вехи». Чистая функция над списком результатов:
//  ничего не хранится отдельно, поэтому цифры не могут разойтись с историей.
//
//  Что показываем и почему — раздел 5.6 ТЗ и его дух:
//   • метрики про УМЕНИЕ, а не про количество часов;
//   • ни одного счётчика, который штрафует за пропуск дня;
//   • вехи формулируются как «я так умею», а не «зайди завтра».
//
//  Осознанно НЕ показываем: общее время в игре, серию дней с обнулением,
//  место в глобальном рейтинге — по ТЗ это создаёт тревогу и не помогает расти.
//

import Foundation

/// Одна завершённая партия в виде, достаточном для всей статистики.
public struct SolvedRecord: Sendable, Equatable {
    public let tier: DifficultyTier
    public let completedAt: Date
    public let activeSeconds: Int
    public let isRanked: Bool
    public let deltaR: Int
    public let usedHint: Bool
    public let confirmedErrors: Int
    public let usedCandidateHelp: Bool
    public let wasComparable: Bool
    public let techniques: [SudokuTechnique]
    /// Счёт партии. `nil` у партий, сыгранных до появления счёта — ноль
    /// исказил бы рекорды, поэтому такие записи просто не участвуют.
    public let sessionScore: Int?
    public let maxMultiplierPermille: Int?
    /// Рейтинг ПОСЛЕ партии. Нужен для кривой: восстанавливать его сложением
    /// дельт нельзя — нерейтинговые партии дельту не дают, и ряд разъедется.
    public let ratingAfter: Int?

    public init(
        tier: DifficultyTier,
        completedAt: Date,
        activeSeconds: Int,
        isRanked: Bool,
        deltaR: Int,
        usedHint: Bool,
        confirmedErrors: Int,
        usedCandidateHelp: Bool,
        wasComparable: Bool,
        techniques: [SudokuTechnique],
        sessionScore: Int? = nil,
        maxMultiplierPermille: Int? = nil,
        ratingAfter: Int? = nil
    ) {
        self.sessionScore = sessionScore
        self.maxMultiplierPermille = maxMultiplierPermille
        self.ratingAfter = ratingAfter
        self.tier = tier
        self.completedAt = completedAt
        self.activeSeconds = activeSeconds
        self.isRanked = isRanked
        self.deltaR = deltaR
        self.usedHint = usedHint
        self.confirmedErrors = confirmedErrors
        self.usedCandidateHelp = usedCandidateHelp
        self.wasComparable = wasComparable
        self.techniques = techniques
    }

    /// «Чисто»: без подсказок и без подтверждённых ошибок.
    /// Кандидаты и заметки не считаются грязью — это часть честной игры.
    public var isClean: Bool { !usedHint && confirmedErrors == 0 }

    /// «Полностью самостоятельно»: ещё и без вычисляемых кандидатов.
    public var isUnaided: Bool { isClean && !usedCandidateHelp }
}

public struct PlayerStatistics: Sendable {

    public let records: [SolvedRecord]

    public init(records: [SolvedRecord]) {
        self.records = records.sorted { $0.completedAt < $1.completedAt }
    }

    // MARK: - Объём

    public var solvedTotal: Int { records.count }

    public func solvedCount(in tier: DifficultyTier) -> Int {
        records.filter { $0.tier == tier }.count
    }

    /// Самый сложный тир, в котором есть хотя бы одно чистое решение.
    public var hardestCleanTier: DifficultyTier? {
        records.filter(\.isClean).map(\.tier).max()
    }

    // MARK: - Счёт партий

    /// Лучший счёт в тире. Партии без счёта пропускаются, а не считаются
    /// нулём: иначе история до появления системы очков занижала бы рекорд.
    public func bestScore(in tier: DifficultyTier) -> Int? {
        records.filter { $0.tier == tier }.compactMap(\.sessionScore).max()
    }

    public var bestScore: Int? { records.compactMap(\.sessionScore).max() }

    /// Самая длинная серия за одну партию — в промилле множителя.
    public var bestMultiplierPermille: Int? {
        records.compactMap(\.maxMultiplierPermille).max()
    }

    /// Есть ли вообще что показывать по счёту. До первой сыгранной партии
    /// раздел прячется целиком, а не показывает прочерки.
    public var hasScores: Bool { records.contains { $0.sessionScore != nil } }

    // MARK: - Кривая рейтинга

    /// Точки для графика: только рейтинговые партии, у которых известен
    /// рейтинг после. Нерейтинговые не влияют на R и в кривой создавали бы
    /// горизонтальные ступени, которых игрок не заслуживал.
    public func ratingCurve(limit: Int = 30) -> [(date: Date, rating: Int)] {
        records
            .filter { $0.isRanked }
            .compactMap { record in record.ratingAfter.map { (record.completedAt, $0) } }
            .suffix(limit)
            .map { (date: $0.0, rating: $0.1) }
    }

    // MARK: - Время

    /// Среднее активное время в тире, в секундах.
    ///
    /// Только чистые партии: решение с подсказкой измеряет не скорость игрока,
    /// а скорость подсказки, и смешивать их в одном среднем нечестно.
    public func averageCleanSeconds(in tier: DifficultyTier) -> Int? {
        let values = records.filter { $0.tier == tier && $0.isClean }.map(\.activeSeconds)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }

    /// Стало ли быстрее. Сравнивается среднее первой и последней трети чистых
    /// партий тира; при малой выборке возвращается `nil`, потому что разница
    /// на трёх партиях — это шум, а показанная стрелка выглядит как факт.
    public func speedTrend(in tier: DifficultyTier) -> Double? {
        let values = records.filter { $0.tier == tier && $0.isClean }.map(\.activeSeconds)
        guard values.count >= 6 else { return nil }
        let third = values.count / 3
        let first = values.prefix(third)
        let last = values.suffix(third)
        guard !first.isEmpty, !last.isEmpty else { return nil }
        let before = Double(first.reduce(0, +)) / Double(first.count)
        let after = Double(last.reduce(0, +)) / Double(last.count)
        guard before > 0 else { return nil }
        return (after - before) / before
    }

    // MARK: - Три аспекта из раздела 5.6

    /// Точность: доля партий без подтверждённых ошибок.
    public var accuracyRate: Double { rate { $0.confirmedErrors == 0 } }

    /// Самостоятельность: доля партий без подсказок.
    public var independenceRate: Double { rate { !$0.usedHint } }

    /// Логика: доля партий, решённых вообще без вычисляемой помощи.
    public var logicRate: Double { rate(\.isUnaided) }

    private func rate(_ predicate: (SolvedRecord) -> Bool) -> Double {
        guard !records.isEmpty else { return 0 }
        return Double(records.filter(predicate).count) / Double(records.count)
    }

    // MARK: - Серии

    /// Текущая серия чистых партий. Обнуляется только ошибкой или подсказкой,
    /// а НЕ пропущенным днём: это метрика умения, а не посещаемости.
    public var currentCleanStreak: Int {
        var streak = 0
        for record in records.reversed() {
            guard record.isClean else { break }
            streak += 1
        }
        return streak
    }

    public var longestCleanStreak: Int {
        var best = 0
        var current = 0
        for record in records {
            if record.isClean {
                current += 1
                best = max(best, current)
            } else {
                current = 0
            }
        }
        return best
    }

    // MARK: - Время

    public func personalBest(in tier: DifficultyTier) -> Int? {
        records.filter { $0.tier == tier && $0.wasComparable }
            .map(\.activeSeconds).min()
    }

    /// Медиана активного времени по тиру — устойчивее среднего к одной долгой партии.
    public func medianTime(in tier: DifficultyTier) -> Int? {
        let times = records.filter { $0.tier == tier }.map(\.activeSeconds).sorted()
        guard !times.isEmpty else { return nil }
        return times[times.count / 2]
    }

    // MARK: - Коллекция техник

    /// Техники, встреченные в РЕШЁННЫХ БЕЗ ПОДСКАЗКИ задачах.
    /// Это честная коллекция: подсказка показала бы технику за игрока.
    public var techniquesMet: Set<SudokuTechnique> {
        Set(records.filter { !$0.usedHint }.flatMap(\.techniques))
    }

    public var techniquesTotal: Int { SudokuTechnique.allCases.count }

    // MARK: - Динамика рейтинга

    /// Последние рейтинговые изменения — для линии на экране прогресса.
    public func recentDeltas(limit: Int = 10) -> [Int] {
        records.filter(\.isRanked).suffix(limit).map(\.deltaR)
    }
}

// MARK: - Тихие вехи

/// Веха — это «я так умею», а не «я столько накликал».
/// Ни одна веха не истекает и не сгорает: достигнутое остаётся навсегда.
public struct Milestone: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable {
        case independence   // играть без подсказок
        case accuracy       // играть без ошибок
        case depth          // подниматься по сложности
        case technique      // встречать новые техники
        case pace           // сопоставимый personal best
    }

    public let id: String
    public let kind: Kind
    public let titleKey: String
    /// Текущее значение и цель. Для достигнутых `current >= target`.
    public let current: Int
    public let target: Int

    public var isAchieved: Bool { current >= target }
    public var progress: Double {
        target > 0 ? min(1, Double(current) / Double(target)) : 0
    }
}

public enum MilestoneCatalog {

    /// Порядок фиксирован: сначала близкие к достижению, потом остальные.
    /// Сортировка делается на экране, здесь — стабильный список.
    public static func build(from stats: PlayerStatistics) -> [Milestone] {
        let cleanByTier: (DifficultyTier) -> Int = { tier in
            stats.records.filter { $0.tier == tier && $0.isClean }.count
        }
        let comparableTiers = DifficultyTier.allCases.filter {
            stats.personalBest(in: $0) != nil
        }.count

        return [
            Milestone(id: "clean.first", kind: .independence,
                      titleKey: "milestone.clean.first",
                      current: min(stats.records.filter(\.isClean).count, 1), target: 1),

            Milestone(id: "clean.streak3", kind: .accuracy,
                      titleKey: "milestone.clean.streak3",
                      current: min(stats.longestCleanStreak, 3), target: 3),

            Milestone(id: "clean.streak10", kind: .accuracy,
                      titleKey: "milestone.clean.streak10",
                      current: min(stats.longestCleanStreak, 10), target: 10),

            Milestone(id: "clean.hard", kind: .depth,
                      titleKey: "milestone.clean.hard",
                      current: min(cleanByTier(.hard), 1), target: 1),

            Milestone(id: "clean.expert", kind: .depth,
                      titleKey: "milestone.clean.expert",
                      current: min(cleanByTier(.expert), 1), target: 1),

            Milestone(id: "clean.master", kind: .depth,
                      titleKey: "milestone.clean.master",
                      current: min(cleanByTier(.master), 1), target: 1),

            Milestone(id: "unaided.10", kind: .independence,
                      titleKey: "milestone.unaided.10",
                      current: min(stats.records.filter(\.isUnaided).count, 10), target: 10),

            Milestone(id: "techniques.half", kind: .technique,
                      titleKey: "milestone.techniques.half",
                      current: min(stats.techniquesMet.count, stats.techniquesTotal / 2),
                      target: stats.techniquesTotal / 2),

            Milestone(id: "techniques.all", kind: .technique,
                      titleKey: "milestone.techniques.all",
                      current: stats.techniquesMet.count, target: stats.techniquesTotal),

            Milestone(id: "pace.allTiers", kind: .pace,
                      titleKey: "milestone.pace.allTiers",
                      current: comparableTiers, target: DifficultyTier.allCases.count)
        ]
    }
}
