//
//  ProgressIntegrityTests.swift
//  NamiDataTests
//
//  Created by artemoffM8.
//
//  Целостность прогресса: профиль, рейтинговый snapshot и заморозка записи.
//
//  Слой считался непроверяемым, поэтому единственной защитой было чтение
//  кода. Проверяется он обычным `ModelContainer` в памяти: контейнер живёт
//  в свойстве теста (контекст released-контейнера падает по SIGTRAP), а
//  `RatingResult` собирается через `RatingEngine.evaluate` — memberwise-init
//  у него internal.
//
//  Каждый тест здесь падает, если убрать соответствующее исправление: это
//  проверено мутацией, иначе тест защищает только самого себя.
//

import XCTest
import SwiftData
import NamiDomain
@testable import NamiData

@MainActor
final class ProgressIntegrityTests: XCTestCase {

    /// Контейнер обязан пережить тест целиком: `mainContext` отпущенного
    /// контейнера падает по SIGTRAP на первом же обращении.
    private var container: ModelContainer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let schema = Schema(PersistenceSchema.models)
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    // MARK: - Инструменты

    private enum StorageFault: Error { case fetchUnavailable }

    /// Управляемый сбой чтения профиля: на живом устройстве так выглядит
    /// недоступный файл хранилища. `ModelContext` не `open`, подменить его
    /// `fetch` нельзя, поэтому репозиторий принимает чтение отдельно.
    private final class ProfileReader {
        let context: ModelContext
        var fails = false

        init(_ context: ModelContext) { self.context = context }

        @MainActor
        func read() throws -> [PlayerProfile] {
            if fails { throw StorageFault.fetchUnavailable }
            return try context.fetch(FetchDescriptor<PlayerProfile>(
                predicate: #Predicate { $0.id == "player" }
            ))
        }
    }

    /// Репозиторий с управляемым чтением профиля и его переключатель сбоя.
    private func repositoryWithFaultyProfileRead()
    -> (progress: ProgressRepository, context: ModelContext, reader: ProfileReader) {
        let context = ModelContext(container)
        let reader = ProfileReader(context)
        let progress = ProgressRepository(context: context, readProfiles: { try reader.read() })
        return (progress, context, reader)
    }

    private func playedSnapshot(rating: Int = 1480) -> RatingSnapshot {
        RatingSnapshot(
            rating: rating,
            displayDivision: RankDivision(index: 7),
            bestDivision: RankDivision(index: 8),
            calibrationRatedCount: 17,
            confirmationWindow: [1440, 1460, rating]
        )
    }

    /// Рейтинговый результат без единой поблажки: `RatingResult` собирается
    /// только движком — его memberwise-init internal для домена.
    private func rankedResult(currentRating: Int, difficulty: Int = 1500) -> RatingResult {
        RatingEngine.evaluate(RatingInput(
            currentRating: currentRating,
            puzzleDifficulty: difficulty,
            appliedRatedCount: 17,
            ledger: AssistanceUsageLedger(),
            paceMode: .disabled,
            speedEligible: false,
            activeSeconds: 400,
            expectedActiveSecondsP50: 500
        ))
    }

    /// Нерейтинговый исход: Reveal. Именно им заканчивается партия, если
    /// прогресс не читается, — и раньше он всё равно попадал в базу.
    private func unrankedResult(currentRating: Int) -> RatingResult {
        var ledger = AssistanceUsageLedger()
        ledger.record(hintLayer: .reveal)
        return RatingEngine.evaluate(RatingInput(
            currentRating: currentRating,
            puzzleDifficulty: 1500,
            appliedRatedCount: 17,
            ledger: ledger,
            paceMode: .disabled,
            speedEligible: false,
            activeSeconds: 400,
            expectedActiveSecondsP50: 500
        ))
    }

    private func gameResult(id: String, rating: RatingResult) -> GameResult {
        GameResult(
            id: id,
            puzzleID: "p-042",
            catalogVersion: "test",
            tierRaw: DifficultyTier.medium.rawValue,
            completedAt: .now,
            activeSeconds: 400,
            challengeElapsedSeconds: 400,
            deltaR: rating.deltaR,
            ratingAfter: rating.newRating,
            isRanked: rating.isRanked,
            isPractice: false,
            reasonCodeRaw: rating.reason.rawValue,
            ledgerData: Data(),
            initialProfileID: AssistanceProfile.focus.rawValue,
            ratingAlgorithmVersion: rating.algorithmVersion,
            isDaily: false,
            dailyScore: nil
        )
    }

    private func insertProfile(snapshotData: Data, in context: ModelContext) throws {
        context.insert(PlayerProfile(snapshotData: snapshotData))
        try context.save()
    }

    private func insertApplied(id: String, snapshot: RatingSnapshot?,
                               appliedAt: Date, in context: ModelContext) throws {
        let data = try snapshot.map { try RatingSnapshotArchive.encode($0) }
            ?? Data("не json".utf8)
        context.insert(AppliedRatingResult(
            ratedResultID: id, appliedAt: appliedAt,
            deltaR: 12, ratingAfter: snapshot?.rating ?? 0, snapshotData: data
        ))
        try context.save()
    }

    /// Байты профиля, как их видит следующий запуск: читаем из отдельного
    /// контекста, чтобы не поверить объекту, живущему в памяти теста.
    private func storedProfileData() throws -> Data? {
        let fresh = ModelContext(container)
        return try fresh.fetch(FetchDescriptor<PlayerProfile>()).first?.snapshotData
    }

    private func storedResultCount() throws -> Int {
        try ModelContext(container).fetch(FetchDescriptor<GameResult>()).count
    }

    // MARK: - Здоровая установка: поведение не изменилось

    /// Опорный тест ко всем остальным: на исправном хранилище ничего из
    /// защит не срабатывает, а результат применяется ровно один раз.
    func testHealthyProfileAppliesResultExactlyOnceWithoutAnyIssue() throws {
        let context = ModelContext(container)
        try insertProfile(snapshotData: RatingSnapshotArchive.encode(playedSnapshot()),
                          in: context)
        let progress = ProgressRepository(context: context)
        let applier = RatingResultApplier(context: context, progress: progress)

        XCTAssertEqual(progress.snapshot().rating, 1480)
        XCTAssertFalse(progress.isWriteFrozen)
        XCTAssertNoThrow(try progress.ensureWritable())

        let rating = rankedResult(currentRating: 1480)
        XCTAssertTrue(rating.isRanked)
        let first = applier.apply(ratedResultID: "r-1", result: rating,
                                  resultRecord: gameResult(id: "r-1", rating: rating))

        XCTAssertNil(first.persistenceFailure)
        XCTAssertFalse(first.wasAlreadyApplied)
        XCTAssertEqual(first.snapshot.rating, rating.newRating)
        XCTAssertEqual(first.deltaR, rating.deltaR)
        XCTAssertNil(progress.takeIntegrityIssue(), "на исправном профиле сбоев быть не может")
        XCTAssertEqual(try storedResultCount(), 1)
        XCTAssertEqual(try storedProfileData().map(RatingSnapshotArchive.restore),
                       .restored(first.snapshot))

        // Повтор с тем же ID — no-op, а не второе начисление.
        let again = applier.apply(ratedResultID: "r-1", result: rating,
                                  resultRecord: gameResult(id: "r-1", rating: rating))
        XCTAssertTrue(again.wasAlreadyApplied)
        XCTAssertEqual(again.snapshot.rating, first.snapshot.rating)
        XCTAssertEqual(try storedResultCount(), 1)
    }

    /// Первый запуск обязан остаться первым запуском: профиля нет, snapshot
    /// стартовый, запись разрешена, предупреждения нет.
    func testFirstLaunchCreatesProfileWithoutFreezing() throws {
        let context = ModelContext(container)
        let progress = ProgressRepository(context: context)

        XCTAssertEqual(progress.snapshot(), RatingSnapshot())
        XCTAssertFalse(progress.isWriteFrozen)
        XCTAssertNil(progress.takeIntegrityIssue())

        try progress.store(snapshot: playedSnapshot(rating: 1010))
        XCTAssertEqual(try storedProfileData().map(RatingSnapshotArchive.restore),
                       .restored(playedSnapshot(rating: 1010)))
    }

    // MARK: - Профиль не прочитался (не путать с «профиля нет»)

    /// Главный случай: на сбое чтения нельзя вставлять новый профиль.
    /// `@Attribute(.unique)` превращает такую вставку в перезапись, и живой
    /// рейтинг 1480 молча становится стартовым — на диске.
    func testProfileReadFailureNeverOverwritesStoredProfile() throws {
        let seed = ModelContext(container)
        try insertProfile(snapshotData: RatingSnapshotArchive.encode(playedSnapshot()),
                          in: seed)

        let (progress, _, reader) = repositoryWithFaultyProfileRead()
        reader.fails = true

        _ = progress.profile()
        _ = progress.snapshot()

        XCTAssertEqual(try storedProfileData().map(RatingSnapshotArchive.restore),
                       .restored(playedSnapshot()),
                       "сохранённый профиль перезаписан стартовым — это и есть потеря прогресса")
        XCTAssertEqual(progress.takeIntegrityIssue(),
                       .profileUnreadable(reason: "\(StorageFault.fetchUnavailable)"))
    }

    /// Пустые байты отсоединённого профиля читаются как `.empty`, то есть как
    /// первый запуск. Без явной заморозки это снова разрешило бы запись.
    func testProfileReadFailureFreezesWriting() throws {
        let seed = ModelContext(container)
        try insertProfile(snapshotData: RatingSnapshotArchive.encode(playedSnapshot()),
                          in: seed)

        let (progress, _, reader) = repositoryWithFaultyProfileRead()
        reader.fails = true

        XCTAssertTrue(progress.isWriteFrozen)
        XCTAssertThrowsError(try progress.stage(snapshot: playedSnapshot(rating: 1600))) { error in
            XCTAssertEqual(error as? ProgressIntegrityIssue,
                           .profileUnreadable(reason: "профиль не прочитан"))
        }
        XCTAssertEqual(try storedProfileData().map(RatingSnapshotArchive.restore),
                       .restored(playedSnapshot()))
    }

    /// Сбой чтения не вечен: как только профиль читается, запись оживает.
    func testWritingResumesAfterProfileBecomesReadableAgain() throws {
        let seed = ModelContext(container)
        try insertProfile(snapshotData: RatingSnapshotArchive.encode(playedSnapshot()),
                          in: seed)

        let (progress, _, reader) = repositoryWithFaultyProfileRead()
        reader.fails = true
        XCTAssertTrue(progress.isWriteFrozen)

        reader.fails = false
        XCTAssertFalse(progress.isWriteFrozen)
        XCTAssertEqual(progress.snapshot().rating, 1480)
        XCTAssertNoThrow(try progress.store(snapshot: playedSnapshot(rating: 1500)))
        XCTAssertEqual(try storedProfileData().map(RatingSnapshotArchive.restore),
                       .restored(playedSnapshot(rating: 1500)))
    }

    // MARK: - Старая форма snapshot — не повреждение

    /// Первый же новый обязательный член `RatingSnapshot` сделал бы каждый
    /// сохранённый профиль нечитаемым, то есть заморозил бы запись навсегда.
    /// Отсутствующий ключ обязан читаться как «старая форма».
    func testSnapshotWithoutKnownKeyIsStillReadable() throws {
        let full = try RatingSnapshotArchive.encode(playedSnapshot())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: full) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "rankStabilityVersion"),
                        "ключ обязан присутствовать, иначе тест ничего не проверяет")
        let older = try JSONSerialization.data(withJSONObject: object)

        guard case .restored(let restored) = RatingSnapshotArchive.restore(older) else {
            return XCTFail("snapshot прежней формы объявлен повреждением: "
                           + "\(RatingSnapshotArchive.restore(older))")
        }
        XCTAssertEqual(restored.rating, 1480)
        XCTAssertEqual(restored.displayDivision, RankDivision(index: 7))
        XCTAssertEqual(restored.calibrationRatedCount, 17)
    }

    /// Читаемость старой формы не должна превращаться в снисходительность:
    /// байты, которые не разбираются, обязаны оставаться повреждением.
    func testTrulyBrokenBytesRemainUnreadable() {
        for payload in ["не json", "{\"rating\":", "[1,2,3]", "null",
                        "{\"rating\":\"1480\"}"] {
            guard case .unreadable = RatingSnapshotArchive.restore(Data(payload.utf8)) else {
                return XCTFail("«\(payload)» прочитано не как повреждение")
            }
        }
    }

    // MARK: - Восстановление вместо вечной заморозки

    /// У заморозки обязан быть выход. Копия snapshot лежит в каждом
    /// применённом результате — берём самую свежую читаемую.
    func testUnreadableSnapshotIsRecoveredFromLastAppliedResult() throws {
        let context = ModelContext(container)
        try insertProfile(snapshotData: Data("испорчено".utf8), in: context)
        try insertApplied(id: "r-1", snapshot: playedSnapshot(rating: 1440),
                          appliedAt: Date(timeIntervalSince1970: 1_000), in: context)
        try insertApplied(id: "r-2", snapshot: playedSnapshot(rating: 1480),
                          appliedAt: Date(timeIntervalSince1970: 2_000), in: context)

        let progress = ProgressRepository(context: context)

        XCTAssertEqual(progress.snapshot().rating, 1480, "восстановлен не самый свежий результат")
        XCTAssertFalse(progress.isWriteFrozen, "после восстановления замораживать нечего")
        XCTAssertEqual(progress.takeIntegrityIssue(),
                       .snapshotRecovered(appliedAt: Date(timeIntervalSince1970: 2_000)))
        // Починка обязана дойти до диска, иначе следующий запуск начнёт заново.
        XCTAssertEqual(try storedProfileData().map(RatingSnapshotArchive.restore),
                       .restored(playedSnapshot(rating: 1480)))
        // И запись снова работает: рейтинговые партии опять записываются.
        XCTAssertNoThrow(try progress.store(snapshot: playedSnapshot(rating: 1492)))
    }

    /// Повреждена может быть и сама свежая копия. Тогда берётся следующая:
    /// потеря — один результат, а не весь прогресс.
    func testRecoveryFallsBackToOlderDecodableCopy() throws {
        let context = ModelContext(container)
        try insertProfile(snapshotData: Data("испорчено".utf8), in: context)
        try insertApplied(id: "r-1", snapshot: playedSnapshot(rating: 1440),
                          appliedAt: Date(timeIntervalSince1970: 1_000), in: context)
        try insertApplied(id: "r-2", snapshot: nil,
                          appliedAt: Date(timeIntervalSince1970: 2_000), in: context)

        let progress = ProgressRepository(context: context)

        XCTAssertEqual(progress.snapshot().rating, 1440)
        XCTAssertFalse(progress.isWriteFrozen)
        XCTAssertEqual(progress.takeIntegrityIssue(),
                       .snapshotRecovered(appliedAt: Date(timeIntervalSince1970: 1_000)))
    }

    /// Восстанавливать не из чего — вот теперь заморозка. Перезаписывать
    /// повреждённые байты нельзя: это единственная копия прогресса.
    func testFreezeStaysWhenThereIsNothingToRecoverFrom() throws {
        let context = ModelContext(container)
        let corrupted = Data("испорчено".utf8)
        try insertProfile(snapshotData: corrupted, in: context)

        let progress = ProgressRepository(context: context)

        XCTAssertEqual(progress.snapshot(), RatingSnapshot())
        XCTAssertTrue(progress.isWriteFrozen)
        XCTAssertThrowsError(try progress.stage(snapshot: playedSnapshot(rating: 1600)))
        guard case .snapshotUnreadable = try XCTUnwrap(progress.takeIntegrityIssue()) else {
            return XCTFail("сбой назван не тем, чем является")
        }
        XCTAssertEqual(try storedProfileData(), corrupted,
                       "повреждённые байты перезаписаны — восстанавливать больше нечего")
    }

    // MARK: - Заморозка обязана останавливать любую запись

    /// Нерейтинговая партия snapshot не трогает, но её `ratingAfter`
    /// считается от него, и при заморозке это подставное число — а
    /// `statistics()` читает поле как факт. Заморозка, сквозь которую
    /// проходит запись, не заморозка.
    func testFrozenProgressRefusesEvenUnrankedResult() throws {
        let context = ModelContext(container)
        try insertProfile(snapshotData: Data("испорчено".utf8), in: context)
        let progress = ProgressRepository(context: context)
        let applier = RatingResultApplier(context: context, progress: progress)

        let rating = unrankedResult(currentRating: 1000)
        XCTAssertFalse(rating.isRanked)
        let application = applier.apply(ratedResultID: "r-1", result: rating,
                                        resultRecord: gameResult(id: "r-1", rating: rating))

        XCTAssertNotNil(application.persistenceFailure,
                        "сбой не показан: игрок уверен, что партия записана")
        XCTAssertEqual(try storedResultCount(), 0,
                       "результат записан во время заморозки — с выдуманным ratingAfter")
    }

    /// Тот же запрет для рейтингового исхода: ни отметки exactly-once, ни
    /// записи результата, ни перезаписи профиля.
    func testFrozenProgressRefusesRankedResult() throws {
        let context = ModelContext(container)
        let corrupted = Data("испорчено".utf8)
        try insertProfile(snapshotData: corrupted, in: context)
        let progress = ProgressRepository(context: context)
        let applier = RatingResultApplier(context: context, progress: progress)

        let rating = rankedResult(currentRating: 1000)
        let application = applier.apply(ratedResultID: "r-1", result: rating,
                                        resultRecord: gameResult(id: "r-1", rating: rating))

        XCTAssertNotNil(application.persistenceFailure)
        XCTAssertEqual(application.deltaR, 0)
        XCTAssertEqual(try storedResultCount(), 0)
        XCTAssertEqual(try storedProfileData(), corrupted)
        XCTAssertTrue(try ModelContext(container)
            .fetch(FetchDescriptor<AppliedRatingResult>()).isEmpty)
    }
}
