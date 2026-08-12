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

/// Сбой чтения или записи прогресса — единственный вид ошибки, о котором
/// игрок обязан узнать: он молчаливый и стоит рейтинга.
public enum ProgressIntegrityIssue: Error, Equatable, Sendable {
    /// Сохранённый snapshot не читается и восстановить его не из чего.
    /// Запись заморожена: перезапись уничтожила бы единственную копию прогресса.
    case snapshotUnreadable(reason: String)
    /// Сам профиль не прочитался из хранилища. Отличается от «профиля ещё
    /// нет»: вставлять новый в этом случае нельзя — уникальный `id` превращает
    /// вставку в перезапись живого профиля стартовыми значениями.
    case profileUnreadable(reason: String)
    /// Snapshot не закодировался — на диск ушли бы пустые байты.
    case snapshotNotEncodable(reason: String)
    /// Транзакция не дошла до диска.
    case writeFailed(reason: String)
    /// Не ошибка, а сообщение об уже устранённой: нечитаемый snapshot заменён
    /// копией из последнего применённого результата. Никогда не бросается —
    /// после восстановления запись работает как обычно.
    case snapshotRecovered(appliedAt: Date)
}

@MainActor
public final class ProgressRepository {

    private let context: ModelContext

    /// Последний сбой целостности. Репозиторий не `@Observable`, поэтому
    /// значение забирает роутер там же, где обновляет snapshot.
    private var pendingIssue: ProgressIntegrityIssue?

    /// Профиль не прочитался, и `profile()` вернул объект вне контекста.
    /// Пустые байты такого объекта читаются как `.empty`, то есть как «первый
    /// запуск», и без этого флага запись снова стала бы разрешена — поверх
    /// профиля, которого мы не видим.
    private var profileDetached = false

    /// Чтение строки профиля. Вынесено отдельным замыканием ради проверяемости:
    /// `ModelContext` не `open`, а на исправной базе его `fetch` не падает
    /// никогда — иначе сбой чтения было бы нечем воспроизвести. Проверять его
    /// обязательно: именно на нём прежний код перезаписывал живой профиль.
    private let readProfiles: () throws -> [PlayerProfile]

    public convenience init(context: ModelContext) {
        self.init(context: context, readProfiles: {
            try context.fetch(FetchDescriptor<PlayerProfile>(
                predicate: #Predicate { $0.id == "player" }
            ))
        })
    }

    init(context: ModelContext, readProfiles: @escaping () throws -> [PlayerProfile]) {
        self.context = context
        self.readProfiles = readProfiles
    }

    // MARK: - Целостность

    /// Забирает накопленный сбой ровно один раз: показать его нужно, а
    /// повторять на каждом обновлении экрана — нет.
    public func takeIntegrityIssue() -> ProgressIntegrityIssue? {
        defer { pendingIssue = nil }
        return pendingIssue
    }

    /// Первый сбой информативнее последующих: он объясняет причину, а всё
    /// дальнейшее — уже следствия.
    private func record(_ issue: ProgressIntegrityIssue) {
        if pendingIssue == nil { pendingIssue = issue }
    }

    /// `save()` без `try?`: неудачная запись оставляет след, иначе экран
    /// показывает значение, которого на диске нет.
    private func commit() {
        do {
            try context.save()
        } catch {
            record(.writeFailed(reason: "\(error)"))
        }
    }

    // MARK: - Профиль

    /// Профиль игрока. Три исхода строки не смешиваются: он есть, его ещё нет,
    /// или прочитать не удалось.
    ///
    /// Раньше `try? … .first` сводил «нет строки» и «не прочиталось» к одному
    /// `nil`, и на сбое чтения вставлялся новый `PlayerProfile(id: "player")`.
    /// Из-за `@Attribute(.unique)` такая вставка — не вставка, а перезапись:
    /// живой профиль молча становился стартовым и уезжал на диск. Поэтому на
    /// сбое чтения не вставляется ничего.
    public func profile() -> PlayerProfile {
        let stored: [PlayerProfile]
        do {
            stored = try readProfiles()
        } catch {
            record(.profileUnreadable(reason: "\(error)"))
            profileDetached = true
            // Объект вне контекста: экранам нужно что-то отдать, но в базу он
            // не попадёт и ничего не перезапишет. Запись при этом заморожена
            // флагом выше — иначе его пустые байты сошли бы за первый запуск.
            return PlayerProfile(snapshotData: Data())
        }
        profileDetached = false
        if let existing = stored.first { return existing }
        // Пустые байты здесь не потеря: `.empty` читается как «профиля ещё
        // не было» и даёт ровно тот же стартовый snapshot, что и запись.
        let data = (try? RatingSnapshotArchive.encode(RatingSnapshot())) ?? Data()
        let created = PlayerProfile(snapshotData: data)
        context.insert(created)
        commit()
        return created
    }

    /// Snapshot вместе с ответом на вопрос, можно ли поверх него писать.
    private struct Resolution {
        let snapshot: RatingSnapshot
        /// Причина, по которой запись заморожена, или `nil`, если её нет.
        let blocker: ProgressIntegrityIssue?

        var isFrozen: Bool { blocker != nil }

        static func writable(_ snapshot: RatingSnapshot) -> Resolution {
            Resolution(snapshot: snapshot, blocker: nil)
        }
    }

    private func resolveSnapshot() -> Resolution {
        let profile = profile()
        if profileDetached {
            return Resolution(snapshot: RatingSnapshot(),
                              blocker: .profileUnreadable(reason: "профиль не прочитан"))
        }
        switch RatingSnapshotArchive.restore(profile.snapshotData) {
        case .empty:
            // Первый запуск: стартовый snapshot — правильный ответ, не сбой.
            return .writable(RatingSnapshot())
        case .restored(let snapshot):
            return .writable(snapshot)
        case .unreadable(let reason):
            // Данные на месте, но не читаются. Сначала пробуем восстановить их
            // из копии, приложенной к применённому результату.
            if let recovered = recoverSnapshot(into: profile) { return recovered }
            // Восстанавливать не из чего. Показываем стартовые значения
            // (других мы не знаем) и запрещаем запись, чтобы они не стали
            // правдой вместо повреждённых, но ещё восстановимых байтов.
            let issue = ProgressIntegrityIssue.snapshotUnreadable(reason: reason)
            record(issue)
            return Resolution(snapshot: RatingSnapshot(), blocker: issue)
        }
    }

    /// Восстановление профиля из копии snapshot, которую `AppliedRatingResult`
    /// хранит после каждого применённого рейтингового результата.
    ///
    /// Заморозка записи спасает повреждённые байты от перезаписи, но сама по
    /// себе — та же потеря: рейтинг показывается стартовым, ранг исчезает, ни
    /// один результат больше не записывается. Выход есть, и он уже лежит в
    /// базе: копии применённых результатов. Берём самую свежую, которая
    /// читается, — в худшем случае теряется один последний результат.
    private func recoverSnapshot(into profile: PlayerProfile) -> Resolution? {
        var descriptor = FetchDescriptor<AppliedRatingResult>(
            sortBy: [SortDescriptor(\.appliedAt, order: .reverse)]
        )
        // Глубже смотреть незачем: если не читается и двадцатая копия подряд,
        // повреждено само хранилище, а не одна запись.
        descriptor.fetchLimit = 20
        guard let applied = try? context.fetch(descriptor) else { return nil }
        for candidate in applied {
            guard case .restored(let snapshot) =
                    RatingSnapshotArchive.restore(candidate.snapshotData) else { continue }
            profile.snapshotData = candidate.snapshotData
            do {
                try context.save()
            } catch {
                // Значение восстановлено, но на диск не легло. Показать его
                // честнее, чем стартовое, а писать поверх — рано: о починке
                // объявляем только когда она пережила запись.
                let issue = ProgressIntegrityIssue.writeFailed(reason: "\(error)")
                record(issue)
                return Resolution(snapshot: snapshot, blocker: issue)
            }
            record(.snapshotRecovered(appliedAt: candidate.appliedAt))
            return .writable(snapshot)
        }
        return nil
    }

    public func snapshot() -> RatingSnapshot {
        resolveSnapshot().snapshot
    }

    /// Прогресс не читается и не восстановлен. Вызывающий обязан спросить об
    /// этом ДО расчёта: рейтинг, посчитанный от подставного snapshot, нельзя
    /// ни показывать, ни записывать в историю.
    public var isWriteFrozen: Bool {
        resolveSnapshot().isFrozen
    }

    /// Проверяет право на запись, ничего не меняя. Бросает ровно тот же сбой,
    /// что и `stage(snapshot:)`, поэтому вызывающий может остановиться раньше —
    /// до того, как вставит в базу результат, посчитанный не от того рейтинга.
    public func ensureWritable() throws {
        if let blocker = resolveSnapshot().blocker { throw blocker }
    }

    /// Готовит запись snapshot в профиль, но не коммитит: вызывающий
    /// сохраняет её одной транзакцией с остальными записями результата.
    /// Возвращает те самые байты, чтобы не кодировать snapshot дважды.
    ///
    /// Бросает, если сохранённые байты не читаются: перезапись превратила бы
    /// повреждение в безвозвратную потерю.
    @discardableResult
    public func stage(snapshot: RatingSnapshot) throws -> Data {
        try ensureWritable()
        let profile = profile()
        do {
            let data = try RatingSnapshotArchive.encode(snapshot)
            profile.snapshotData = data
            return data
        } catch {
            let issue = ProgressIntegrityIssue.snapshotNotEncodable(reason: "\(error)")
            record(issue)
            throw issue
        }
    }

    public func store(snapshot: RatingSnapshot) throws {
        try stage(snapshot: snapshot)
        do {
            try context.save()
        } catch {
            let issue = ProgressIntegrityIssue.writeFailed(reason: "\(error)")
            record(issue)
            throw issue
        }
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
        commit()
    }

    public func setOnboardingCompleted() {
        profile().onboardingCompleted = true
        commit()
    }

    /// Одноразовые карточки InterfaceCoach (раздел 5.1).
    public func markCoachCardShown(notes: Bool = false, hint: Bool = false) {
        let profile = self.profile()
        if notes { profile.interfaceCoachNotesShown = true }
        if hint { profile.interfaceCoachHintShown = true }
        commit()
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
        commit()
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
        /// Транзакция не дошла до диска. Без этого поля `wasAlreadyApplied:
        /// false` и новый snapshot означали «применено», хотя не сохранилось
        /// ничего: экран результата праздновал переход ступени, который
        /// исчезал при следующем запуске.
        public let persistenceFailure: ProgressIntegrityIssue?
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
            switch RatingSnapshotArchive.restore(existing.snapshotData) {
            case .restored(let stored):
                return Application(snapshot: stored, deltaR: existing.deltaR,
                                   wasAlreadyApplied: true, event: nil,
                                   persistenceFailure: nil)
            case .empty:
                return Application(snapshot: progress.snapshot(), deltaR: existing.deltaR,
                                   wasAlreadyApplied: true, event: nil,
                                   persistenceFailure: nil)
            case .unreadable(let reason):
                // Результат применён, но его копия snapshot повреждена.
                // Показываем текущий профиль и говорим об этом вслух.
                return Application(snapshot: progress.snapshot(), deltaR: existing.deltaR,
                                   wasAlreadyApplied: true, event: nil,
                                   persistenceFailure: .snapshotUnreadable(reason: reason))
            }
        }

        // 2. Заморозка проверяется ДО разделения на исходы. Нерейтинговая
        // партия snapshot не трогает, но её `ratingAfter` считается от него,
        // и при заморозке это подставное число: `statistics()` читает поле как
        // факт. Заморозка, сквозь которую проходит запись, — не заморозка.
        do {
            try progress.ensureWritable()
        } catch {
            return Application(snapshot: progress.snapshot(), deltaR: 0,
                               wasAlreadyApplied: false, event: nil,
                               persistenceFailure: Self.issue(from: error))
        }

        // 3. Нерейтинговый исход не трогает snapshot, но сохраняется как результат.
        guard result.isRanked else {
            context.insert(resultRecord())
            var failure: ProgressIntegrityIssue?
            do {
                try context.save()
            } catch {
                failure = .writeFailed(reason: "\(error)")
            }
            return Application(snapshot: progress.snapshot(), deltaR: 0,
                               wasAlreadyApplied: false, event: nil,
                               persistenceFailure: failure)
        }

        // 4. Один атомарный переход.
        let previous = progress.snapshot()
        let outcome = RankStabilityEngine.apply(result: result, to: previous)
        var snapshot = outcome.snapshot
        snapshot.lastAppliedRatedResultID = ratedResultID

        // Snapshot готовится ПЕРВЫМ. Если писать его нельзя, не вставляется
        // ни отметка exactly-once, ни запись результата: повтор после
        // устранения причины пройдёт как первый раз, а не как «уже применено».
        let snapshotData: Data
        do {
            snapshotData = try progress.stage(snapshot: snapshot)
        } catch {
            return Application(snapshot: previous, deltaR: 0,
                               wasAlreadyApplied: false, event: nil,
                               persistenceFailure: Self.issue(from: error))
        }

        context.insert(AppliedRatingResult(
            ratedResultID: ratedResultID,
            appliedAt: .now,
            deltaR: result.deltaR,
            ratingAfter: result.newRating,
            snapshotData: snapshotData
        ))
        context.insert(resultRecord())
        do {
            try context.save()
        } catch {
            // Откат контекста НЕ делаем намеренно: изменения остаются
            // ожидающими и могут дойти до диска следующим успешным `save()`,
            // а `rollback()` гарантированно уничтожил бы результат, который
            // ещё можно спасти. Но событие перехода гасим — праздновать
            // несохранённое повышение нельзя.
            return Application(snapshot: snapshot, deltaR: result.deltaR,
                               wasAlreadyApplied: false, event: nil,
                               persistenceFailure: .writeFailed(reason: "\(error)"))
        }

        return Application(snapshot: snapshot, deltaR: result.deltaR,
                           wasAlreadyApplied: false, event: outcome.event,
                           persistenceFailure: nil)
    }

    /// Отмечает начало показа перехода. После crash/retry анимация не повторяется.
    public func markPresentationStarted() {
        var snapshot = progress.snapshot()
        guard var event = snapshot.pendingProgressEvent, event.presentationStartedAt == nil
        else { return }
        event.presentationStartedAt = .now
        snapshot.pendingProgressEvent = event
        // Ошибка записи уже зафиксирована репозиторием и поднимется на экран
        // предупреждением; ронять из-за неё показ результата нечестно вдвойне.
        try? progress.store(snapshot: snapshot)
    }

    public func clearPendingEvent() {
        var snapshot = progress.snapshot()
        snapshot.pendingProgressEvent = nil
        try? progress.store(snapshot: snapshot)
    }

    private static func issue(from error: Error) -> ProgressIntegrityIssue {
        (error as? ProgressIntegrityIssue) ?? .writeFailed(reason: "\(error)")
    }
}
