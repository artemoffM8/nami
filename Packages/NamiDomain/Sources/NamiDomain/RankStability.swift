//
//  RankStability.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  15 ступеней, calibration guard и подтверждение перехода rolling-окном из
//  трёх применённых рейтинговых результатов (раздел 9.7).
//
//  Ключевые инварианты:
//   • `ratingDivision` — сырой, `displayDivision` — подтверждённый;
//   • окно НЕ очищается после перехода: «последние три результата»;
//   • `bestDivision` и открытая стадия пространства никогда не уменьшаются;
//   • понижение — только спокойный crossfade, без отрицательного feedback.
//

import Foundation

public enum RankTier: Int, Codable, CaseIterable, Sendable, Comparable {
    case observer = 0    // Наблюдатель
    case logician        // Логик
    case strategist      // Стратег
    case architect       // Архитектор
    case master          // Мастер

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var titleKey: String { "rank.tier.\(rawValue).title" }
    /// Стабильный ID художественной стадии «Пространства ясности» (раздел 9.8).
    public var claritySpaceID: String {
        switch self {
        case .observer: "horizon"
        case .logician: "glow"
        case .strategist: "planes"
        case .architect: "arc"
        case .master: "field"
        }
    }
}

/// Одна из 15 ступеней: `tier` × `detailLevel` (0 = III, 1 = II, 2 = I).
public struct RankDivision: Codable, Equatable, Sendable, Comparable, Hashable {
    public let index: Int   // 0...14

    public init(index: Int) {
        self.index = clamp(index, 0, 14)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.index < rhs.index }

    public var tier: RankTier { RankTier(rawValue: index / 3) ?? .observer }
    public var detailLevel: Int { index % 3 }
    /// Римская подпись ступени.
    public var romanKey: String { ["III", "II", "I"][detailLevel] }

    /// Нижние границы 15 ступеней (раздел 9.7).
    public static let lowerBounds = [
        600, 750, 900,
        1050, 1150, 1250,
        1350, 1450, 1550,
        1650, 1750, 1850,
        2000, 2150, 2300
    ]

    public var lowerBound: Int { Self.lowerBounds[index] }
    public var upperBound: Int? { index < 14 ? Self.lowerBounds[index + 1] - 1 : nil }

    public static func forRating(_ rating: Int) -> RankDivision {
        var result = 0
        for (i, bound) in lowerBounds.enumerated() where rating >= bound { result = i }
        return RankDivision(index: result)
    }

    /// Расстояние до следующего порога или `nil` на верхней ступени.
    public func pointsToNext(from rating: Int) -> Int? {
        guard index < 14 else { return nil }
        return max(0, Self.lowerBounds[index + 1] - rating)
    }
}

public struct PendingProgressEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case calibrationPlaced
        case claritySpaceAdvanced
        case rankPromoted
    }

    public let id: UUID
    public let kind: Kind
    public let fromDivision: Int?
    public let toDivision: Int
    /// Атомарно отмечается перед началом показа: после crash/retry полный
    /// переход не проигрывается второй раз (раздел 9.7).
    public var presentationStartedAt: Date?

    public init(id: UUID = UUID(), kind: Kind, fromDivision: Int?, toDivision: Int,
                presentationStartedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.fromDivision = fromDivision
        self.toDivision = toDivision
        self.presentationStartedAt = presentationStartedAt
    }
}

public struct RatingSnapshot: Codable, Equatable, Sendable {
    public static let currentStabilityVersion = 2

    public var rating: Int
    public var ratingDivision: RankDivision
    public var displayDivision: RankDivision?
    public var bestDivision: RankDivision?
    public var calibrationRatedCount: Int
    /// Последние (не более трёх) значения `R` после применённых рейтинговых результатов.
    public var confirmationWindow: [Int]
    public var rankStabilityVersion: Int
    public var lastAppliedRatedResultID: String?
    public var pendingProgressEvent: PendingProgressEvent?

    public init(
        rating: Int = RatingEngine.startingRating,
        ratingDivision: RankDivision? = nil,
        displayDivision: RankDivision? = nil,
        bestDivision: RankDivision? = nil,
        calibrationRatedCount: Int = 0,
        confirmationWindow: [Int] = [],
        rankStabilityVersion: Int = RatingSnapshot.currentStabilityVersion,
        lastAppliedRatedResultID: String? = nil,
        pendingProgressEvent: PendingProgressEvent? = nil
    ) {
        self.rating = rating
        self.ratingDivision = ratingDivision ?? RankDivision.forRating(rating)
        self.displayDivision = displayDivision
        self.bestDivision = bestDivision
        self.calibrationRatedCount = calibrationRatedCount
        self.confirmationWindow = confirmationWindow
        self.rankStabilityVersion = rankStabilityVersion
        self.lastAppliedRatedResultID = lastAppliedRatedResultID
        self.pendingProgressEvent = pendingProgressEvent
    }

    public var isCalibrating: Bool { calibrationRatedCount < RatingEngine.calibrationCount }
    public var bestTier: RankTier? { bestDivision?.tier }

    /// «Подтверждение повышения: N/3» — самый длинный хвост окна выше следующего порога.
    public func promotionConfirmationProgress() -> Int? {
        guard let display = displayDivision, display.index < 14 else { return nil }
        let threshold = RankDivision.lowerBounds[display.index + 1]
        var count = 0
        for value in confirmationWindow.reversed() {
            if value >= threshold { count += 1 } else { break }
        }
        return count > 0 ? min(count, 3) : nil
    }

    /// «Стабильность ранга: N/3» — доступно только в подробностях, без warning.
    public func demotionRiskProgress() -> Int? {
        guard let display = displayDivision, display.index > 0 else { return nil }
        let threshold = display.lowerBound
        var count = 0
        for value in confirmationWindow.reversed() {
            if value < threshold { count += 1 } else { break }
        }
        return count > 0 ? min(count, 3) : nil
    }
}

public enum RankStabilityEngine {

    public struct Outcome: Equatable, Sendable {
        public let snapshot: RatingSnapshot
        public let promoted: Bool
        public let demoted: Bool
        public let event: PendingProgressEvent?
    }

    /// Применяет уже рассчитанный рейтинговый результат к snapshot.
    /// Нерейтинговые исходы (practice, reveal) сюда не попадают:
    /// они не увеличивают калибровку, не наполняют окно и не сбрасывают его.
    public static func apply(
        result: RatingResult,
        to snapshot: RatingSnapshot,
        now: Date = Date()
    ) -> Outcome {
        precondition(result.isRanked, "RankStabilityEngine принимает только рейтинговые результаты")

        var next = snapshot
        next.rating = result.newRating
        next.ratingDivision = RankDivision.forRating(result.newRating)
        next.calibrationRatedCount += 1

        // Calibration guard — раздел 9.7.
        if next.calibrationRatedCount < RatingEngine.calibrationCount {
            next.displayDivision = nil
            next.confirmationWindow = []
            next.pendingProgressEvent = nil
            return Outcome(snapshot: next, promoted: false, demoted: false, event: nil)
        }

        if next.calibrationRatedCount == RatingEngine.calibrationCount {
            // Placement: без ложной серии повышений.
            next.displayDivision = next.ratingDivision
            next.bestDivision = next.ratingDivision
            next.confirmationWindow = []
            let event = PendingProgressEvent(
                kind: .calibrationPlaced,
                fromDivision: nil,
                toDivision: next.ratingDivision.index
            )
            next.pendingProgressEvent = event
            return Outcome(snapshot: next, promoted: false, demoted: false, event: event)
        }

        // Начиная с шестого результата окно наполняется.
        var window = next.confirmationWindow
        window.append(result.newRating)
        if window.count > 3 { window.removeFirst(window.count - 3) }
        next.confirmationWindow = window

        var promoted = false
        var demoted = false
        let display = next.displayDivision ?? next.ratingDivision

        if window.count == 3 {
            let upTarget = RankDivision.forRating(window.min() ?? result.newRating)
            if upTarget > display {
                next.displayDivision = upTarget
                promoted = true
            } else {
                let downTarget = RankDivision.forRating(window.max() ?? result.newRating)
                if downTarget < display {
                    next.displayDivision = downTarget
                    demoted = true
                }
            }
        }
        if next.displayDivision == nil { next.displayDivision = display }

        // Только подтверждённый `displayDivision` выше прежнего `bestDivision`
        // создаёт событие. Пересечение порога сырым `ratingDivision` не анимирует ничего.
        var event: PendingProgressEvent?
        if let confirmed = next.displayDivision {
            let previousBest = next.bestDivision
            if previousBest == nil || confirmed > previousBest! {
                next.bestDivision = confirmed
                event = PendingProgressEvent(
                    kind: .rankPromoted,
                    fromDivision: previousBest?.index,
                    toDivision: confirmed.index
                )
            }
        }
        next.pendingProgressEvent = event
        _ = now
        return Outcome(snapshot: next, promoted: promoted, demoted: demoted, event: event)
    }
}
