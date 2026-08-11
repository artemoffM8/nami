//
//  RatingEngine.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  «Рейтинг ясности» v2 (раздел 9). Полностью детерминированный расчёт:
//  одинаковый вход даёт одинаковый выход, версия зафиксирована в
//  `ratingAlgorithmVersion`, старые результаты не пересчитываются.
//
//  Четыре видимые строки breakdown считаются тем же алгоритмом контрфактически,
//  поэтому всегда суммируются в реально применённый ΔR — даже на cap и на 600.
//

import Foundation

public enum RatingPaceMode: String, Codable, Sendable {
    case disabled
    case againstPersonalBest
    case timedLimit

    /// Только явно выбранное испытание допускает положительный бонус темпа.
    public var allowsSpeedBonus: Bool { self != .disabled }
}

public enum ResultReasonCode: String, Codable, Sendable, CaseIterable {
    case unrankedReveal
    case practiceThirdStrike
    case ratingFloor
    case verifiedErrorsReducedResult
    case assistanceReducedResult
    case easierThanRating
    case harderThanRating
    case speedChallengeBonus
    case ratingMatched

    public var localizationKey: String { "result.reason.\(rawValue)" }
}

public struct RatingInput: Sendable {
    /// Текущий рейтинг игрока.
    public let currentRating: Int
    /// Внутренняя сложность задачи `D`.
    public let puzzleDifficulty: Int
    /// Сколько рейтинговых результатов уже применено — определяет `K`.
    public let appliedRatedCount: Int
    public let ledger: AssistanceUsageLedger
    public let paceMode: RatingPaceMode
    public let speedEligible: Bool
    public let activeSeconds: Int
    public let expectedActiveSecondsP50: Int

    public init(
        currentRating: Int,
        puzzleDifficulty: Int,
        appliedRatedCount: Int,
        ledger: AssistanceUsageLedger,
        paceMode: RatingPaceMode,
        speedEligible: Bool,
        activeSeconds: Int,
        expectedActiveSecondsP50: Int
    ) {
        self.currentRating = currentRating
        self.puzzleDifficulty = puzzleDifficulty
        self.appliedRatedCount = appliedRatedCount
        self.ledger = ledger
        self.paceMode = paceMode
        self.speedEligible = speedEligible
        self.activeSeconds = activeSeconds
        self.expectedActiveSecondsP50 = expectedActiveSecondsP50
    }
}

public struct RatingBreakdown: Equatable, Sendable {
    /// «Сложность»
    public let challengeDelta: Int
    /// «Помощь» — один объединённый компонент, даже если сработал cap 0.24.
    public let assistDelta: Int
    /// «Проверенные ошибки»
    public let guessDelta: Int
    /// «Бонус испытания» — только в Against PB / Timed.
    public let speedBonus: Int

    public var total: Int { challengeDelta + assistDelta + guessDelta + speedBonus }
}

public struct RatingResult: Equatable, Sendable {
    public let isRanked: Bool
    public let previousRating: Int
    public let newRating: Int
    public let deltaR: Int
    public let breakdown: RatingBreakdown
    public let reason: ResultReasonCode
    public let kFactor: Int
    public let assistPenalty: Double
    public let guessPenalty: Double
    public let speedCandidate: Int
    public let algorithmVersion: String
}

public enum RatingEngine {

    public static let algorithmVersion = "rating-v2.0"
    public static let ratingFloorValue = 600
    public static let startingRating = 1000
    // Три результата вместо пяти: калибровка заканчивается заметно раньше.
    // Цена — более шумный старт, поэтому K на этом отрезке остаётся высоким.
    public static let calibrationCount = 3

    public static let deltaLowerBound = -12
    public static let deltaUpperBound = 28

    /// K по разделу 9.3.
    public static func kFactor(appliedRatedCount: Int) -> Int {
        switch appliedRatedCount {
        case ..<5: 48
        case ..<15: 32
        default: 20
        }
    }

    /// Бакет темпа по активному времени относительно медианы задачи (раздел 9.5).
    public static func speedBucket(activeSeconds: Int, expectedP50: Int) -> Int {
        guard expectedP50 > 0, activeSeconds > 0 else { return 0 }
        let ratio = Double(activeSeconds) / Double(expectedP50)
        if ratio <= 0.70 { return 3 }
        if ratio <= 0.85 { return 2 }
        if ratio <= 1.00 { return 1 }
        return 0
    }

    public static func evaluate(_ input: RatingInput) -> RatingResult {
        let ledger = input.ledger
        let k = kFactor(appliedRatedCount: input.appliedRatedCount)
        let r = Double(input.currentRating)
        let d = Double(input.puzzleDifficulty)
        let expected = 1.0 / (1.0 + pow(10.0, (d - r) / 400.0))

        let assistPenalty = ledger.assistPenalty
        let guessPenalty = ledger.guessPenalty

        // baseDelta нужен для гейта бонуса темпа.
        let baseDelta = rawDelta(k: k, expected: expected, assist: assistPenalty, guess: guessPenalty)

        let speedCandidate = resolveSpeedCandidate(input: input, baseDelta: baseDelta)

        // Контрфактические компоненты — раздел 9.6.
        func rate(_ a: Double, _ g: Double, _ b: Int) -> Int {
            let delta = clamp(rawDelta(k: k, expected: expected, assist: a, guess: g) + b,
                              deltaLowerBound, deltaUpperBound)
            return max(ratingFloorValue, input.currentRating + delta) - input.currentRating
        }

        let challengeDelta = rate(0, 0, 0)
        let assistDelta = rate(assistPenalty, 0, 0) - challengeDelta
        let guessDelta = rate(assistPenalty, guessPenalty, 0) - rate(assistPenalty, 0, 0)
        let speedBonus = rate(assistPenalty, guessPenalty, speedCandidate)
            - rate(assistPenalty, guessPenalty, 0)

        let breakdown = RatingBreakdown(
            challengeDelta: challengeDelta,
            assistDelta: assistDelta,
            guessDelta: guessDelta,
            speedBonus: speedBonus
        )

        let isRanked = ledger.isRanked
        let deltaR = isRanked ? breakdown.total : 0
        let newRating = input.currentRating + deltaR

        let reason = resolveReason(
            ledger: ledger,
            deltaR: deltaR,
            currentRating: input.currentRating,
            puzzleDifficulty: input.puzzleDifficulty,
            breakdown: breakdown
        )

        return RatingResult(
            isRanked: isRanked,
            previousRating: input.currentRating,
            newRating: newRating,
            deltaR: deltaR,
            breakdown: isRanked ? breakdown
                : RatingBreakdown(challengeDelta: 0, assistDelta: 0, guessDelta: 0, speedBonus: 0),
            reason: reason,
            kFactor: k,
            assistPenalty: assistPenalty,
            guessPenalty: guessPenalty,
            speedCandidate: speedCandidate,
            algorithmVersion: algorithmVersion
        )
    }

    // MARK: - Внутреннее

    private static func rawDelta(k: Int, expected: Double, assist: Double, guess: Double) -> Int {
        let s = clamp(1.0 - assist - guess, 0.0, 1.0)
        return Int((Double(k) * (s - expected)).rounded())
    }

    private static func resolveSpeedCandidate(input: RatingInput, baseDelta: Int) -> Int {
        // Раздел 9.5: все гейты обязательны.
        guard input.paceMode.allowsSpeedBonus else { return 0 }
        guard input.speedEligible else { return 0 }
        guard baseDelta > 0 else { return 0 }
        guard input.ledger.confirmedGuessStrikes == 0 else { return 0 }
        guard input.ledger.hintLayer <= .region else { return 0 }
        guard input.ledger.candidateAid < .wholeBoard else { return 0 }
        guard !input.ledger.revealUsed else { return 0 }
        return speedBucket(activeSeconds: input.activeSeconds,
                           expectedP50: input.expectedActiveSecondsP50)
    }

    /// «Задача проще текущего уровня» — эвристика порога, а не часть формулы.
    static let easierThanRatingMargin = 100

    private static func resolveReason(
        ledger: AssistanceUsageLedger,
        deltaR: Int,
        currentRating: Int,
        puzzleDifficulty: Int,
        breakdown: RatingBreakdown
    ) -> ResultReasonCode {
        // Practice и Reveal всегда перекрывают остальные причины.
        if ledger.revealUsed { return .unrankedReveal }
        if ledger.isPractice { return .practiceThirdStrike }
        // ratingFloor допустим только при ΔR = 0 на нижней границе.
        if deltaR == 0 && currentRating == ratingFloorValue { return .ratingFloor }

        if deltaR < 0 {
            // Наибольший отрицательный вклад; при равенстве — порядок из таблицы 9.6.
            // `challengeDelta` не может быть отрицательным: решённая задача даёт S - E,
            // где S = 1 без помощи, поэтому минус создают только помощь и ошибки.
            var best = ResultReasonCode.easierThanRating
            var bestValue = 0
            if breakdown.guessDelta < bestValue {
                bestValue = breakdown.guessDelta
                best = .verifiedErrorsReducedResult
            }
            if breakdown.assistDelta < bestValue {
                bestValue = breakdown.assistDelta
                best = .assistanceReducedResult
            }
            if breakdown.challengeDelta < bestValue {
                best = .easierThanRating
            }
            return best
        }

        if deltaR > 0 {
            if breakdown.challengeDelta > 0 { return .harderThanRating }
            // Единственный случай, когда нулевую базу поднял бонус испытания.
            if breakdown.speedBonus > 0 { return .speedChallengeBonus }
            return .ratingMatched
        }

        // ΔR = 0: задача либо в уровень, либо заметно проще.
        if puzzleDifficulty <= currentRating - easierThanRatingMargin {
            return .easierThanRating
        }
        return .ratingMatched
    }
}

@inlinable
func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
}
