//
//  Analytics.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Шов для телеметрии. Реализации подставляются снаружи; домен знает только
//  про смысл событий.
//
//  Зачем она нужна именно нам. Академический обзор оценки сложности (Pelánek,
//  arXiv 1403.7373) показывает, что технический рейтинг вроде SE коррелирует
//  со временем живых решателей примерно на 0.69. Наш `SE → D` — гипотеза,
//  проверить которую можно только реальными завершениями. Без телеметрии
//  калибровка сложности невозможна в принципе.
//
//  Поэтому здесь СТРОГОЕ ограничение на состав данных: только агрегаты,
//  описывающие партию, и ни одного поля, по которому можно восстановить
//  игрока или ход решения. Ни решения, ни значений клеток, ни журнала ходов,
//  ни идентификатора устройства. При таком составе событие можно честно
//  объявить в карточке приватности как «данные не связаны с пользователем».
//

import Foundation

/// Ведро значения. Сырые числа не отправляются: точный счёт или точное время
/// в связке с задачей делают запись почти уникальной.
public enum AnalyticsBucket {

    /// Порядковые ведра для счёта: 0, 1-999, 1000-2999, …
    public static func score(_ value: Int) -> String {
        switch value {
        case ..<1: "0"
        case ..<1_000: "1-999"
        case ..<3_000: "1000-2999"
        case ..<6_000: "3000-5999"
        case ..<10_000: "6000-9999"
        default: "10000+"
        }
    }

    /// Ведра внутреннего рейтинга задачи с шагом 300.
    public static func difficulty(_ value: Int) -> String {
        let lower = (value / 300) * 300
        return "\(lower)-\(lower + 299)"
    }

    /// Отношение времени к медиане, а не само время.
    public static func pace(elapsedMs: Int, expectedMs: Int) -> String {
        guard expectedMs > 0, elapsedMs > 0 else { return "unknown" }
        let permille = ScoreMath.ceilDiv(elapsedMs * 1000, expectedMs)
        // Неявный возврат работает только для тела из одного выражения,
        // а здесь перед switch есть guard и let.
        return switch permille {
        case ..<701: "<=0.7"
        case ..<851: "<=0.85"
        case ..<1001: "<=1.0"
        case ..<1501: "<=1.5"
        default: ">1.5"
        }
    }
}

public enum AnalyticsEvent: Equatable, Sendable {
    case sessionScoreStarted(SessionScoreContext)
    case multiplierTierReached(tier: Int, ruleSet: String)
    case multiplierBroken(reason: ScorePenaltyReason, ruleSet: String)
    case penaltyApplied(reason: ScorePenaltyReason, ruleSet: String)
    case paperBatchResolved(moves: Int, ruleSet: String)
    case sessionScoreCompleted(SessionScoreSummary)
    case hudHidden(ruleSet: String)

    public var name: String {
        switch self {
        case .sessionScoreStarted: "session_score_started"
        case .multiplierTierReached: "score_multiplier_tier_reached"
        case .multiplierBroken: "score_multiplier_broken"
        case .penaltyApplied: "score_penalty_applied"
        case .paperBatchResolved: "paper_score_batch_resolved"
        case .sessionScoreCompleted: "session_score_completed"
        case .hudHidden: "session_score_hud_hidden"
        }
    }
}

public struct SessionScoreContext: Equatable, Sendable {
    public let ruleSet: String
    public let tier: String
    public let difficultyBucket: String
    public let validationPolicy: String
    public let mode: String

    public init(ruleSet: String, tier: DifficultyTier, difficultyD: Int,
                policy: ScoreValidationPolicy, mode: GameMode) {
        self.ruleSet = ruleSet
        self.tier = tier.rawValue
        self.difficultyBucket = AnalyticsBucket.difficulty(difficultyD)
        self.validationPolicy = policy.rawValue
        self.mode = mode.rawValue
    }
}

/// Итог партии в агрегатах. Именно эти поля нужны для перекалибровки
/// таблицы `SE → D`: сложность, время относительно ожидания и исход.
public struct SessionScoreSummary: Equatable, Sendable {
    public let ruleSet: String
    public let tier: String
    public let difficultyBucket: String
    public let scoreBucket: String
    public let paceBucket: String
    public let maxStreak: Int
    public let maxMultiplierPermille: Int
    public let confirmedErrors: Int
    public let checkCount: Int
    public let deepestHint: String
    public let candidateAid: String
    public let isRecordable: Bool

    public init(ruleSet: String, tier: DifficultyTier, difficultyD: Int,
                score: Int, elapsedMs: Int, expectedMs: Int,
                maxStreak: Int, maxMultiplierPermille: Int,
                confirmedErrors: Int, checkCount: Int,
                deepestHint: HintLayer, candidateAid: CandidateAid,
                isRecordable: Bool) {
        self.ruleSet = ruleSet
        self.tier = tier.rawValue
        self.difficultyBucket = AnalyticsBucket.difficulty(difficultyD)
        self.scoreBucket = AnalyticsBucket.score(score)
        self.paceBucket = AnalyticsBucket.pace(elapsedMs: elapsedMs, expectedMs: expectedMs)
        self.maxStreak = maxStreak
        self.maxMultiplierPermille = maxMultiplierPermille
        self.confirmedErrors = confirmedErrors
        self.checkCount = checkCount
        self.deepestHint = String(describing: deepestHint)
        self.candidateAid = String(describing: candidateAid)
        self.isRecordable = isRecordable
    }
}

// MARK: - Приёмник

public protocol AnalyticsService: AnyObject, Sendable {
    func record(_ event: AnalyticsEvent)
}

/// Значение по умолчанию. Пока внешний SDK не выбран, приложение не
/// отправляет ничего — и это состояние должно быть именно значением по
/// умолчанию, а не забытой настройкой.
public final class NoopAnalyticsService: AnalyticsService, @unchecked Sendable {
    public init() {}
    public func record(_ event: AnalyticsEvent) {}
}

/// Локальный кольцевой буфер: события видно в отладке и можно выгрузить
/// вручную, но они никуда не уходят с устройства.
public final class InMemoryAnalyticsService: AnalyticsService, @unchecked Sendable {

    private let limit: Int
    private let lock = NSLock()
    private var storage: [AnalyticsEvent] = []

    public init(limit: Int = 200) { self.limit = limit }

    public var events: [AnalyticsEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    public func record(_ event: AnalyticsEvent) {
        lock.lock(); defer { lock.unlock() }
        storage.append(event)
        if storage.count > limit { storage.removeFirst(storage.count - limit) }
    }
}
