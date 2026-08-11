//
//  Daily.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Ежедневная задача, отдельный Daily Score и мягкий недельный ритм
//  (разделы 4.4, 9.10, 11).
//

import Foundation
import CryptoKit

public enum ChallengeModifier: String, Codable, CaseIterable, Sendable {
    case timedLimit
    case perfect
    case noNotes

    public var titleKey: String { "challenge.\(rawValue).title" }
}

public struct DailySchedule: Sendable {
    public static let scheduleVersion = "daily-2026.07-1"
    public static let dailyScoreVersion = "daily-score-1"

    /// Понедельник — Easy, плавный рост до Expert к воскресенью (раздел 11).
    public static func tier(forWeekday weekday: Int) -> DifficultyTier {
        // `weekday` в Calendar(identifier: .iso8601): 2 = понедельник ... 1 = воскресенье.
        switch weekday {
        case 2: .easy
        case 3: .easy
        case 4: .medium
        case 5: .medium
        case 6: .hard
        case 7: .hard
        default: .expert
        }
    }

    /// Детерминированный выбор задачи дня: одинаков для всех на одной версии.
    public static func puzzleID(for date: Date, in catalog: PuzzleCatalog,
                                calendar: Calendar = Calendar(identifier: .iso8601)) -> String? {
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let year = components.year, let month = components.month,
              let day = components.day, let weekday = components.weekday else { return nil }

        let tier = tier(forWeekday: weekday)
        let pool = catalog.puzzles(in: tier).filter(\.dailyEligible).sorted { $0.id < $1.id }
        guard !pool.isEmpty else { return nil }

        let seedText = "\(scheduleVersion)|\(year)-\(month)-\(day)"
        let digest = SHA256.hash(data: Data(seedText.utf8))
        var value: UInt64 = 0
        for byte in digest.prefix(8) { value = (value << 8) | UInt64(byte) }
        return pool[Int(value % UInt64(pool.count))].id
    }

    public static func competitionVersion(puzzleID: String) -> String {
        let raw = "\(scheduleVersion)|\(puzzleID)|\(dailyScoreVersion)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum DailyScore {

    /// Пространство версий Daily-таблицы. Новая формула НИКОГДА не смешивается
    /// со старой: результаты, посчитанные разными правилами, несопоставимы,
    /// поэтому получают отдельный leaderboard, а не общий с пересчётом.
    public static let legacyVersion = "daily-v1-time-penalty"
    public static let currentVersion = "daily-v2-" + SessionScoreRuleSet.v1.id

    /// Видимый Daily Score новой версии — это `SessionScore` партии.
    /// Отдельной формулы у Daily больше нет.
    public static func current(from score: SessionScoreState) -> Int {
        score.displayScore
    }


    /// Формула v1: `10000 − время − штрафы`. Оставлена только для чтения
    /// старых результатов и НЕ применяется к новым партиям: она вычитала
    /// время, что противоречит обещанию не наказывать за медленное решение.
    ///
    /// Раздел 9.10. Reveal и третий strike исключают результат из leaderboard,
    /// но не отменяют прохождение дня.
    @available(*, deprecated, message: "новые партии используют DailyScore.current(from:)")
    public static func score(
        challengeElapsedSeconds: Int,
        ledger: AssistanceUsageLedger
    ) -> Int {
        let hintPoints: Int = switch ledger.hintLayer {
        case .none: 0
        case .region: 1
        case .techniqueName: 2
        case .candidatesAndLogic, .reveal: 4
        }
        let candidateOverlayPenalty: Int = switch ledger.candidateAid {
        case .none: 0
        case .keypadDimming: 50
        case .lens: 150
        case .selectedCellPersistent: 150
        case .wholeBoard: 600
        }
        let validationPenalty: Int = switch ledger.validationAid {
        case .none: 0
        case .impossibleNoteWarning: 50
        case .singleCandidateHighlight: 100
        case .manualCheck, .automaticSolutionCheck: 400
        }
        return max(0, 10000
                   - challengeElapsedSeconds
                   - ledger.confirmedGuessStrikes * 250
                   - hintPoints * 400
                   - candidateOverlayPenalty
                   - validationPenalty)
    }

    public static func isLeaderboardEligible(
        ledger: AssistanceUsageLedger,
        timing: TimingSnapshot,
        savedCompetitionVersion: String,
        activeCompetitionVersion: String
    ) -> Bool {
        guard !ledger.revealUsed else { return false }
        guard ledger.confirmedGuessStrikes < 3 else { return false }
        guard timing.leaderboardEligible, !timing.clockAnomalyDetected else { return false }
        return savedCompetitionVersion == activeCompetitionVersion
    }
}

/// Мягкий недельный ритм: «4 из последних 7 дней», без красных предупреждений.
public struct WeeklyRhythm: Equatable, Sendable {
    public let completedDays: Int
    public let windowDays: Int
    public let personalBest: Int

    public init(completedDays: Int, windowDays: Int = 7, personalBest: Int = 0) {
        self.completedDays = completedDays
        self.windowDays = windowDays
        self.personalBest = personalBest
    }

    public static func compute(
        completionDates: [Date],
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .iso8601)
    ) -> WeeklyRhythm {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -6, to: today) else {
            return WeeklyRhythm(completedDays: 0)
        }
        let days = Set(completionDates
            .map { calendar.startOfDay(for: $0) }
            .filter { $0 >= windowStart && $0 <= today })
        return WeeklyRhythm(completedDays: days.count)
    }
}
