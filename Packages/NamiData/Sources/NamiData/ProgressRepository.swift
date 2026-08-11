//
//  ProgressRepository.swift
//  NamiData
//
//  Created by artemoffM8.
//
//  Профиль, рейтинговый snapshot и exactly-once применение результата
//  (разделы 9.7, 13.7).
//

import Foundation
import SwiftData
import NamiDomain

@MainActor
public final class ProgressRepository {

    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Профиль

    public func profile() -> PlayerProfile {
        let descriptor = FetchDescriptor<PlayerProfile>(
            predicate: #Predicate { $0.id == "player" }
        )
        if let existing = try? context.fetch(descriptor).first { return existing }
        let created = PlayerProfile(snapshotData: DomainCoding.encode(RatingSnapshot()))
        context.insert(created)
        try? context.save()
        return created
    }

    public func snapshot() -> RatingSnapshot {
        DomainCoding.decode(RatingSnapshot.self, from: profile().snapshotData) ?? RatingSnapshot()
    }

    public func store(snapshot: RatingSnapshot) {
        let profile = profile()
        profile.snapshotData = DomainCoding.encode(snapshot)
        try? context.save()
    }

    public func assistanceProfile() -> AssistanceProfile {
        AssistanceProfile(rawValue: profile().assistanceProfileRaw) ?? .focus
    }

    public func sessionPolicy() -> SessionPolicy {
        let profile = profile()
        if let data = profile.sessionPolicyData,
           let policy = DomainCoding.decode(SessionPolicy.self, from: data) {
            return policy
        }
        return assistanceProfile().preset
    }

    public func store(assistanceProfile: AssistanceProfile, policy: SessionPolicy?) {
        let profile = self.profile()
        profile.assistanceProfileRaw = assistanceProfile.rawValue
        profile.sessionPolicyData = policy.map { DomainCoding.encode($0) }
        try? context.save()
    }

    public func setOnboardingCompleted() {
        profile().onboardingCompleted = true
        try? context.save()
    }

    /// Одноразовые карточки InterfaceCoach (раздел 5.1).
    public func markCoachCardShown(notes: Bool = false, hint: Bool = false) {
        let profile = self.profile()
        if notes { profile.interfaceCoachNotesShown = true }
        if hint { profile.interfaceCoachHintShown = true }
        try? context.save()
    }

    public var coachCardsComplete: Bool {
        let profile = self.profile()
        return profile.interfaceCoachNotesShown && profile.interfaceCoachHintShown
    }

    // MARK: - Результаты

    public func completedPuzzleIDs() -> Set<String> {
        let descriptor = FetchDescriptor<GameResult>()
        let results = (try? context.fetch(descriptor)) ?? []
        return Set(results.map(\.puzzleID))
    }

    public func recentResults(limit: Int = 10) -> [GameResult] {
        var descriptor = FetchDescriptor<GameResult>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    public func completionDates() -> [Date] {
        let descriptor = FetchDescriptor<GameResult>()
        return ((try? context.fetch(descriptor)) ?? []).map(\.completedAt)
    }

    /// Лучшее сопоставимое активное время для тира (раздел 11, Personal Best).
    /// Учитываются только попытки, помеченные `wasComparable`: без паузы,
    /// без глубоких подсказок, без Reveal и без подтверждённых ошибок.
    public func personalBest(for tier: DifficultyTier) -> Int? {
        let raw = tier.rawValue
        let descriptor = FetchDescriptor<GameResult>(
            predicate: #Predicate { $0.tierRaw == raw && $0.wasComparable }
        )
        let results = (try? context.fetch(descriptor)) ?? []
        return results.map(\.activeSeconds).min()
    }

    /// Сборка доменной статистики из истории. Ничего не кэшируем:
    /// цифры на экране всегда пересчитаны из тех же записей, что и рейтинг.
    public func statistics() -> PlayerStatistics {
        let descriptor = FetchDescriptor<GameResult>()
        let results = (try? context.fetch(descriptor)) ?? []
        let records: [SolvedRecord] = results.compactMap { result in
            guard let tier = DifficultyTier(rawValue: result.tierRaw) else { return nil }
            let ledger = DomainCoding.decode(AssistanceUsageLedger.self, from: result.ledgerData)
                ?? AssistanceUsageLedger()
            return SolvedRecord(
                tier: tier,
                completedAt: result.completedAt,
                activeSeconds: result.activeSeconds,
                isRanked: result.isRanked,
                deltaR: result.deltaR,
                usedHint: ledger.hintLayer > .none,
                confirmedErrors: ledger.confirmedGuessStrikes,
                usedCandidateHelp: ledger.candidateAid > .none,
                wasComparable: result.wasComparable,
                techniques: result.techniques.compactMap(SudokuTechnique.from(catalogKey:)),
                sessionScore: result.sessionScore,
                maxMultiplierPermille: result.maxMultiplierPermille,
                ratingAfter: result.ratingAfter
            )
        }
        return PlayerStatistics(records: records)
    }

    /// Повторное решение того же puzzle ID не меняет рейтинг (раздел 9.9).
    public func hasRankedResult(forPuzzle puzzleID: String) -> Bool {
        let descriptor = FetchDescriptor<GameResult>(
            predicate: #Predicate { $0.puzzleID == puzzleID && $0.isRanked }
        )
        return ((try? context.fetch(descriptor)) ?? []).isEmpty == false
    }

    // MARK: - Daily

    public func dailyProgress(dayKey: String) -> DailyProgress? {
        let descriptor = FetchDescriptor<DailyProgress>(
            predicate: #Predicate { $0.dayKey == dayKey }
        )
        return try? context.fetch(descriptor).first
    }

    public func upsertDaily(dayKey: String, puzzleID: String, competitionVersion: String,
                            completedAt: Date?, score: Int?) {
        if let existing = dailyProgress(dayKey: dayKey) {
            existing.completedAt = completedAt ?? existing.completedAt
            existing.dailyScore = score ?? existing.dailyScore
        } else {
            context.insert(DailyProgress(dayKey: dayKey, puzzleID: puzzleID,
                                         completedAt: completedAt, dailyScore: score,
                                         competitionVersion: competitionVersion))
        }
        try? context.save()
    }
}

// MARK: - Exactly-once применение результата

/// Изолирован на MainActor: одна операция проверяет уникальный `AppliedRatingResult`,
/// рассчитывает snapshot, вставляет запись результата и сохраняет всё атомарно.
/// Повторный вызов с тем же ID возвращает сохранённый итог и является no-op.
@MainActor
public final class RatingResultApplier {

    public struct Application: Sendable {
        public let snapshot: RatingSnapshot
        public let deltaR: Int
        public let wasAlreadyApplied: Bool
        public let event: PendingProgressEvent?
    }

    private let context: ModelContext
    private let progress: ProgressRepository

    public init(context: ModelContext, progress: ProgressRepository) {
        self.context = context
        self.progress = progress
    }

    public func apply(
        ratedResultID: String,
        result: RatingResult,
        resultRecord: @autoclosure () -> GameResult
    ) -> Application {
        // 1. Идемпотентность.
        let descriptor = FetchDescriptor<AppliedRatingResult>(
            predicate: #Predicate { $0.ratedResultID == ratedResultID }
        )
        if let existing = try? context.fetch(descriptor).first {
            let stored = DomainCoding.decode(RatingSnapshot.self, from: existing.snapshotData)
                ?? progress.snapshot()
            return Application(snapshot: stored, deltaR: existing.deltaR,
                               wasAlreadyApplied: true, event: nil)
        }

        // 2. Нерейтинговый исход не трогает snapshot, но сохраняется как результат.
        guard result.isRanked else {
            context.insert(resultRecord())
            try? context.save()
            return Application(snapshot: progress.snapshot(), deltaR: 0,
                               wasAlreadyApplied: false, event: nil)
        }

        // 3. Один атомарный переход.
        let outcome = RankStabilityEngine.apply(result: result, to: progress.snapshot())
        var snapshot = outcome.snapshot
        snapshot.lastAppliedRatedResultID = ratedResultID

        context.insert(AppliedRatingResult(
            ratedResultID: ratedResultID,
            appliedAt: .now,
            deltaR: result.deltaR,
            ratingAfter: result.newRating,
            snapshotData: DomainCoding.encode(snapshot)
        ))
        context.insert(resultRecord())
        progress.store(snapshot: snapshot)
        try? context.save()

        return Application(snapshot: snapshot, deltaR: result.deltaR,
                           wasAlreadyApplied: false, event: outcome.event)
    }

    /// Отмечает начало показа перехода. После crash/retry анимация не повторяется.
    public func markPresentationStarted() {
        var snapshot = progress.snapshot()
        guard var event = snapshot.pendingProgressEvent, event.presentationStartedAt == nil
        else { return }
        event.presentationStartedAt = .now
        snapshot.pendingProgressEvent = event
        progress.store(snapshot: snapshot)
    }

    public func clearPendingEvent() {
        var snapshot = progress.snapshot()
        snapshot.pendingProgressEvent = nil
        progress.store(snapshot: snapshot)
    }
}
