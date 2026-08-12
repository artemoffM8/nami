//
//  CoreRulesTests.swift
//  NamiDomainTests
//
//  Created by artemoffM8.
//
//  Топология, Undo, помощь, подсказка, ранги и тайминг.
//  Покрывает критерии приёмки 5, 15, 16, 17, 21, 25, 27, 37.
//

import XCTest
@testable import NamiDomain

final class TopologyTests: XCTestCase {

    func testUnitsAndPeers() {
        XCTAssertEqual(BoardTopology.units.count, 27)
        for unit in BoardTopology.units { XCTAssertEqual(unit.count, 9) }
        for cell in 0..<81 {
            XCTAssertEqual(BoardTopology.peers[cell].count, 20, "клетка \(cell)")
            XCTAssertEqual(BoardTopology.unitsOfCell[cell].count, 3)
            XCTAssertFalse(BoardTopology.peers[cell].contains(cell))
        }
    }

    func testDigitMaskHelpers() {
        XCTAssertEqual(Digits.count(Digits.all), 9)
        XCTAssertEqual(Digits.list(Digits.bit(3) | Digits.bit(7)), [3, 7])
        XCTAssertEqual(Digits.single(Digits.bit(5)), 5)
        XCTAssertNil(Digits.single(Digits.bit(5) | Digits.bit(6)))
    }

    func testBoardRequiresExactly81Cells() {
        XCTAssertNil(BoardState(givens: "123"))
        XCTAssertNotNil(BoardState(givens: String(repeating: "0", count: 81)))
    }
}

final class UndoTests: XCTestCase {

    // Критерий 5: Undo возвращает цифру, заметки и связанные автоизменения.
    func testUndoRestoresAutoReducedNotes() {
        var board = BoardState(givens: String(repeating: "0", count: 81))!
        // Ставим заметку 5 в соседней клетке той же строки.
        board[1].manualNotesMask = Digits.bit(5) | Digits.bit(7)

        let builder = MoveBuilder()
        let transaction = builder.placeDigit(5, at: 0, board: board, autoReduceNotes: true)

        var history = MoveHistory()
        MoveApplier.apply(transaction, to: &board)
        history.record(transaction)

        XCTAssertEqual(board[0].value, 5)
        XCTAssertEqual(board[1].manualNotesMask, Digits.bit(7), "заметка 5 должна была уйти")

        history.undo(on: &board)
        XCTAssertEqual(board[0].value, 0)
        XCTAssertEqual(board[1].manualNotesMask, Digits.bit(5) | Digits.bit(7),
                       "Undo обязан вернуть побочно удалённую заметку")
    }

    func testRedoReappliesEverything() {
        var board = BoardState(givens: String(repeating: "0", count: 81))!
        board[1].manualNotesMask = Digits.bit(5)
        var history = MoveHistory()
        let transaction = MoveBuilder().placeDigit(5, at: 0, board: board, autoReduceNotes: true)
        MoveApplier.apply(transaction, to: &board)
        history.record(transaction)
        history.undo(on: &board)
        history.redo(on: &board)
        XCTAssertEqual(board[0].value, 5)
        XCTAssertEqual(board[1].manualNotesMask, 0)
    }
}

final class AssistanceLedgerTests: XCTestCase {

    // Критерий 16: смена профиля и Undo не стирают ledger.
    func testLedgerIsMonotonic() {
        var ledger = AssistanceUsageLedger()
        ledger.record(candidateAid: .wholeBoard)
        ledger.record(candidateAid: .none)
        XCTAssertEqual(ledger.candidateAid, .wholeBoard)

        ledger.record(hintLayer: .candidatesAndLogic)
        ledger.record(hintLayer: .region)
        XCTAssertEqual(ledger.hintLayer, .candidatesAndLogic)

        ledger.record(validationAid: .automaticSolutionCheck)
        ledger.record(validationAid: .impossibleNoteWarning)
        XCTAssertEqual(ledger.validationAid, .automaticSolutionCheck)
    }

    // Раздел 9.4: одно «Проверить» = максимум один strike.
    func testSingleManualCheckCreatesOneStrike() {
        var ledger = AssistanceUsageLedger()
        let created = ledger.registerManualCheck(mismatches: [(1, 4), (2, 5), (3, 6)])
        XCTAssertTrue(created)
        XCTAssertEqual(ledger.confirmedGuessStrikes, 1)
        XCTAssertEqual(ledger.validationAid, .manualCheck)
    }

    func testRepeatedMismatchDoesNotDuplicateStrike() {
        var ledger = AssistanceUsageLedger()
        XCTAssertTrue(ledger.registerSolutionMismatch(cell: 10, digit: 3))
        XCTAssertFalse(ledger.registerSolutionMismatch(cell: 10, digit: 3))
        XCTAssertEqual(ledger.confirmedGuessStrikes, 1)
    }

    func testManualCheckWithoutErrorsStillRecordsAid() {
        var ledger = AssistanceUsageLedger()
        XCTAssertFalse(ledger.registerManualCheck(mismatches: []))
        XCTAssertEqual(ledger.validationAid, .manualCheck)
        XCTAssertEqual(ledger.confirmedGuessStrikes, 0)
    }

    // Perfect: принудительная проверка нейтральна (критерий 29).
    func testPerfectValidationIsNeutral() {
        var ledger = AssistanceUsageLedger()
        ledger.validationIsRuleOfMode = true
        ledger.record(validationAid: .automaticSolutionCheck)
        XCTAssertEqual(ledger.validationAid, .none)
        XCTAssertEqual(ledger.assistPenalty, 0)
    }

    // Ошибка в Perfect завершает попытку без рейтингового результата,
    // но не создаёт отрицательный ΔR (критерий 29, раздел 11).
    func testPerfectFailureMakesAttemptUnranked() {
        var ledger = AssistanceUsageLedger()
        ledger.validationIsRuleOfMode = true
        XCTAssertTrue(ledger.isRanked)

        ledger.registerPerfectFailure()
        XCTAssertFalse(ledger.isRanked)
        XCTAssertTrue(ledger.isPractice)
        XCTAssertEqual(ledger.assistPenalty, 0, "провал режима не является помощью")

        let result = RatingEngine.evaluate(RatingInput(
            currentRating: 1000, puzzleDifficulty: 1400, appliedRatedCount: 20,
            ledger: ledger, paceMode: .disabled, speedEligible: false,
            activeSeconds: 300, expectedActiveSecondsP50: 600
        ))
        XCTAssertFalse(result.isRanked)
        XCTAssertEqual(result.deltaR, 0)
    }

    func testProfilePresetsMatchSpec() {
        XCTAssertEqual(AssistanceProfile.paper.preset.validation, .manualOnly)
        XCTAssertEqual(AssistanceProfile.focus.preset.fieldCandidates, .lensOnDemand)
        XCTAssertEqual(AssistanceProfile.assistant.preset.keypadHints, .dimIllegal)
        XCTAssertTrue(AssistanceProfile.focus.preset.matchesPreset(of: .focus))
        XCTAssertFalse(AssistanceProfile.focus.preset.matchesPreset(of: .paper))
    }

    func testNoNotesDisablesAllCandidateHelp() {
        let policy = AssistanceProfile.assistant.preset.applyingNoNotes()
        XCTAssertEqual(policy.fieldCandidates, .off)
        XCTAssertEqual(policy.keypadHints, .off)
        XCTAssertFalse(policy.autoReduceNotes)
    }
}

final class HintPlannerTests: XCTestCase {

    private let solvable =
        "530070000600195000098000060800060003400803001700020006060000280000419005000080079"

    func testHintReturnsStepOnValidBoard() {
        let board = BoardState(givens: solvable)!
        let derived = SudokuValidator.derive(board)
        guard case .step(let step) = HintPlanner.plan(board: board, derived: derived) else {
            return XCTFail("ожидался логический шаг")
        }
        XCTAssertNotNil(step.placement)
    }

    // Критерий 37: на противоречивой доске — только conflict guidance.
    func testConflictingBoardReturnsOnlyGuidance() {
        var board = BoardState(givens: solvable)!
        // Дублируем 5 в первой строке — явный конфликт правил.
        board[1] = CellState(value: 5)
        let derived = SudokuValidator.derive(board)
        guard case .resolveConflicts(let cells) = HintPlanner.plan(board: board, derived: derived)
        else { return XCTFail("ожидался conflict guidance") }
        XCTAssertFalse(cells.isEmpty)
    }

    // Критерий 17: ход, которого нет в offline trace, не наказывается —
    // solver просто строит следующий шаг заново из текущей позиции.
    func testSolverRebuildsStepAfterOffTraceMove() {
        var board = BoardState(givens: solvable)!
        let solution = ExactSolver.solution(for: solvable)!
        // Ставим корректную цифру в клетку, которую solver выбрал бы позже.
        let target = (0..<81).first { board[$0].value == 0 && $0 > 40 }!
        board[target] = CellState(value: UInt8(String(Array(solution)[target])) ?? 1)
        let derived = SudokuValidator.derive(board)
        XCTAssertTrue(derived.conflicts.isEmpty)
        guard case .step = HintPlanner.plan(board: board, derived: derived) else {
            return XCTFail("solver обязан найти шаг из фактической доски")
        }
    }

    // Критерий 15: assistant overlay никогда не пишет в ручные заметки.
    func testLensOverlayExcludesManualNotes() {
        var board = BoardState(givens: solvable)!
        let empty = (0..<81).first { board[$0].value == 0 }!
        let derived0 = SudokuValidator.derive(board)
        let legal = derived0.legalCandidates[empty]
        let firstDigit = Digits.list(legal)[0]

        board[empty].manualNotesMask = Digits.bit(firstDigit)
        let derived = SudokuValidator.derive(board)
        let overlay = HintPlanner.lensOverlay(for: empty, board: board, derived: derived)

        XCTAssertEqual(overlay & Digits.bit(firstDigit), 0, "ручная заметка визуально побеждает")
        XCTAssertEqual(board[empty].manualNotesMask, Digits.bit(firstDigit),
                       "overlay не должен менять manualNotesMask")
    }
}

final class RankStabilityTests: XCTestCase {

    private func rankedResult(newRating: Int, previous: Int) -> RatingResult {
        RatingResult(
            isRanked: true, previousRating: previous, newRating: newRating,
            deltaR: newRating - previous,
            breakdown: RatingBreakdown(challengeDelta: newRating - previous,
                                       assistDelta: 0, guessDelta: 0, speedBonus: 0),
            reason: .harderThanRating, kFactor: 20, assistPenalty: 0, guessPenalty: 0,
            speedCandidate: 0, algorithmVersion: RatingEngine.algorithmVersion
        )
    }

    private func applySeries(_ ratings: [Int], from start: RatingSnapshot) -> RatingSnapshot {
        var snapshot = start
        for rating in ratings {
            let result = rankedResult(newRating: rating, previous: snapshot.rating)
            snapshot = RankStabilityEngine.apply(result: result, to: snapshot).snapshot
        }
        return snapshot
    }

    // Критерий 25: первые пять предварительные, placement без серии повышений.
    func testCalibrationGuard() {
        var snapshot = RatingSnapshot()
        // Порог берём из движка, а не из литерала: калибровку уже сокращали
        // с пяти результатов до трёх, и тест не должен разваливаться от этого.
        for index in 1..<RatingEngine.calibrationCount {
            let result = rankedResult(newRating: 1000 + index * 10, previous: snapshot.rating)
            let outcome = RankStabilityEngine.apply(result: result, to: snapshot)
            snapshot = outcome.snapshot
            XCTAssertNil(snapshot.displayDivision, "результат \(index) не должен ставить ранг")
            XCTAssertNil(outcome.event)
            XCTAssertTrue(snapshot.confirmationWindow.isEmpty)
        }
        let last = rankedResult(newRating: 1100, previous: snapshot.rating)
        let outcome = RankStabilityEngine.apply(result: last, to: snapshot)
        snapshot = outcome.snapshot
        XCTAssertEqual(outcome.event?.kind, .calibrationPlaced)
        XCTAssertNotNil(snapshot.displayDivision)
        XCTAssertEqual(snapshot.displayDivision, snapshot.bestDivision)
        XCTAssertTrue(snapshot.confirmationWindow.isEmpty)
    }

    // Критерий 21: повышение только после трёх результатов по одну сторону порога.
    func testPromotionRequiresThreeResults() {
        var snapshot = applySeries(Array(repeating: 1000, count: RatingEngine.calibrationCount - 1)
                                  + [1100], from: RatingSnapshot())
        let placed = snapshot.displayDivision
        XCTAssertEqual(placed, RankDivision.forRating(1100))

        // Два результата выше порога 1150 — badge ещё не меняется.
        snapshot = applySeries([1160, 1170], from: snapshot)
        XCTAssertEqual(snapshot.displayDivision, placed)

        // Третий подтверждает.
        snapshot = applySeries([1180], from: snapshot)
        XCTAssertEqual(snapshot.displayDivision, RankDivision.forRating(1160))
        XCTAssertEqual(snapshot.bestDivision, snapshot.displayDivision)
    }

    func testBestDivisionNeverDecreases() {
        var snapshot = applySeries(Array(repeating: 1000, count: RatingEngine.calibrationCount - 1)
                                  + [1300], from: RatingSnapshot())
        snapshot = applySeries([1300, 1300, 1300], from: snapshot)
        let best = snapshot.bestDivision
        XCTAssertNotNil(best)

        // Падение рейтинга: displayDivision может опуститься, bestDivision — нет.
        snapshot = applySeries([900, 900, 900], from: snapshot)
        XCTAssertEqual(snapshot.bestDivision, best)
        XCTAssertLessThan(snapshot.displayDivision!, best!)
    }

    func testWindowKeepsOnlyLastThree() {
        var snapshot = applySeries(Array(repeating: 1000, count: RatingEngine.calibrationCount - 1)
                                  + [1000], from: RatingSnapshot())
        snapshot = applySeries([1010, 1020, 1030, 1040], from: snapshot)
        XCTAssertEqual(snapshot.confirmationWindow, [1020, 1030, 1040])
    }

    func testDivisionBoundaries() {
        XCTAssertEqual(RankDivision.forRating(600).index, 0)
        XCTAssertEqual(RankDivision.forRating(749).index, 0)
        XCTAssertEqual(RankDivision.forRating(750).index, 1)
        XCTAssertEqual(RankDivision.forRating(2300).index, 14)
        XCTAssertEqual(RankDivision.forRating(9999).index, 14)
        XCTAssertEqual(RankDivision(index: 0).tier, .observer)
        XCTAssertEqual(RankDivision(index: 14).tier, .master)
        XCTAssertEqual(RankDivision(index: 14).detailLevel, 2)
    }
}

/// Чтение рейтингового snapshot — второе место после журнала, где ошибка
/// молчит: прежний `?? RatingSnapshot()` не отличал «профиля ещё не было»
/// от «профиль не читается», и повреждённые байты обнуляли историю игрока.
final class RatingSnapshotArchiveTests: XCTestCase {

    private func played() -> RatingSnapshot {
        RatingSnapshot(
            rating: 1480,
            displayDivision: RankDivision(index: 7),
            bestDivision: RankDivision(index: 8),
            calibrationRatedCount: 17,
            confirmationWindow: [1440, 1460, 1480],
            lastAppliedRatedResultID: "p-042|1700000000.0",
            pendingProgressEvent: PendingProgressEvent(
                kind: .rankPromoted, fromDivision: 7, toDivision: 8)
        )
    }

    // MARK: - Счастливый путь

    func testRoundTripKeepsEveryField() throws {
        let snapshot = played()
        let restored = RatingSnapshotArchive.restore(try RatingSnapshotArchive.encode(snapshot))
        XCTAssertEqual(restored, .restored(snapshot))
    }

    // MARK: - Первый запуск против повреждения

    /// Ради этого всё и делалось. Пустые байты — нормальный первый запуск,
    /// и стартовый snapshot здесь правильный ответ.
    func testEmptyDataIsFirstLaunchNotCorruption() {
        XCTAssertEqual(RatingSnapshotArchive.restore(Data()), .empty)
    }

    /// А непустые байты, которые не разбираются, первым запуском называть
    /// нельзя: именно так рейтинг и обнулялся молча.
    ///
    /// `{}` из этого списка убран намеренно. Пустой объект — это не мусор, а
    /// snapshot старой формы: все ключи отсутствуют. Считать его повреждением
    /// значит замораживать запись каждому, кто обновился с версии без нового
    /// поля, — а такая заморозка, в отличие от прежнего молчаливого сброса,
    /// сама не проходит. Разбор `{}` проверяется ниже отдельно.
    func testCorruptedDataIsNotReportedAsEmpty() {
        for payload in ["не json", "{\"rating\":", "[1,2,3]", "null",
                        "{\"rating\":\"1480\"}"] {
            let data = Data(payload.utf8)
            XCTAssertFalse(data.isEmpty, "иначе случай вырождается в первый запуск")
            guard case .unreadable = RatingSnapshotArchive.restore(data) else {
                return XCTFail("«\(payload)» прочитано не как повреждение: "
                               + "\(RatingSnapshotArchive.restore(data))")
            }
        }
    }

    /// Отсутствующий ключ — это прежняя форма snapshot, а не повреждение.
    /// Синтезированный декодер требовал все ключи, и первый же новый
    /// обязательный член структуры заморозил бы запись всем сохранённым
    /// профилям навсегда. Проверяется и вырожденный случай `{}`.
    func testMissingKeysReadAsOlderShapeNotCorruption() throws {
        let full = try RatingSnapshotArchive.encode(played())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: full) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "rankStabilityVersion"),
                        "ключа нет — тест ничего не проверяет")
        let older = try JSONSerialization.data(withJSONObject: object)

        guard case .restored(let restored) = RatingSnapshotArchive.restore(older) else {
            return XCTFail("snapshot прежней формы объявлен повреждением")
        }
        XCTAssertEqual(restored.rating, played().rating)
        XCTAssertEqual(restored.displayDivision, played().displayDivision)
        XCTAssertEqual(restored.confirmationWindow, played().confirmationWindow)
        // Версии в байтах не было — значит они первой.
        XCTAssertEqual(restored.rankStabilityVersion, 1)

        // Пустой объект — предельный случай той же старой формы: стартовые
        // значения и версия «до появления версий».
        XCTAssertEqual(RatingSnapshotArchive.restore(Data("{}".utf8)),
                       .restored(RatingSnapshot(rankStabilityVersion: 1)))
    }

    /// Обрезанный хвост — самый частый вид повреждения записи.
    func testTruncatedPayloadIsUnreadable() throws {
        let data = try RatingSnapshotArchive.encode(played())
        let truncated = data.prefix(data.count - 5)
        XCTAssertGreaterThan(truncated.count, 0)
        guard case .unreadable = RatingSnapshotArchive.restore(Data(truncated)) else {
            return XCTFail("обрезанный snapshot прочитан как целый или как пустой")
        }
    }

    // MARK: - Совместимость с уже сохранёнными профилями

    /// Архив обязан читать байты, записанные прежним кодом, иначе установка,
    /// которая сегодня в порядке, после обновления увидит «повреждение» и
    /// заморозит запись. Прежний код — `JSONEncoder` с `.sortedKeys`.
    func testReadsBytesWrittenByPreviousEncoder() throws {
        let snapshot = played()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacy = try encoder.encode(snapshot)

        XCTAssertEqual(RatingSnapshotArchive.restore(legacy), .restored(snapshot))
        // И пишет ровно те же байты: обновление не меняет содержимое профиля.
        XCTAssertEqual(try RatingSnapshotArchive.encode(snapshot), legacy)
    }
}

final class TimingTests: XCTestCase {

    /// Обёртка над устаревшей формулой Daily. Она больше не применяется к
    /// новым партиям, но обязана продолжать читать архивные результаты
    /// одинаково — иначе история Daily поедет.
    @available(*, deprecated)
    private func legacyDailyScore(challengeElapsedSeconds: Int,
                                  ledger: AssistanceUsageLedger) -> Int {
        DailyScore.score(challengeElapsedSeconds: challengeElapsedSeconds, ledger: ledger)
    }


    private final class FakeClock: MonotonicClock, @unchecked Sendable {
        var value: Double = 0
        var now: Double { value }
        var wallClock: Date { Date(timeIntervalSinceReferenceDate: value) }
    }

    // Критерий 27: gameSuspended снимает speedEligible, но Daily время идёт дальше.
    func testSuspendStopsActiveTimeButNotChallengeTime() {
        let clock = FakeClock()
        var timer = GameTimer(clock: clock)
        timer.start()
        clock.value = 10
        XCTAssertEqual(timer.activeSeconds, 10, accuracy: 0.001)

        timer.suspend()
        XCTAssertFalse(timer.snapshot.speedEligible)
        clock.value = 40
        XCTAssertEqual(timer.activeSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(timer.challengeElapsedSeconds, 40, accuracy: 0.001)

        timer.resume()
        clock.value = 50
        XCTAssertEqual(timer.activeSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(timer.challengeElapsedSeconds, 50, accuracy: 0.001)
    }

    /// Часы, у которых календарная шкала живёт ОТДЕЛЬНО от монотонной —
    /// ровно так ведёт себя устройство, когда системное время двигает
    /// пользователь или коррекция NTP.
    private final class SplitClock: MonotonicClock, @unchecked Sendable {
        var value: Double = 0
        var wall = Date(timeIntervalSinceReferenceDate: 0)
        var now: Double { value }
        var wallClock: Date { wall }
    }

    /// Учёт времени партии обязан зависеть только от монотонной шкалы.
    /// Откат системных часов назад не имеет права сократить `activeSeconds`
    /// (это подарило бы бонус темпа и незаслуженный personal best), а прыжок
    /// вперёд — раздуть его.
    func testElapsedAccountingIgnoresWallClockJumps() {
        let clock = SplitClock()
        var timer = GameTimer(clock: clock)
        timer.start()

        // Системное время уезжает на сутки НАЗАД, монотонное идёт вперёд.
        clock.value = 30
        clock.wall = Date(timeIntervalSinceReferenceDate: -86_400)
        XCTAssertEqual(timer.activeSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(timer.challengeElapsedSeconds, 30, accuracy: 0.001)

        timer.suspend()
        // Прыжок NTP на десять суток вперёд во время паузы.
        clock.value = 90
        clock.wall = Date(timeIntervalSinceReferenceDate: 10 * 86_400)
        XCTAssertEqual(timer.activeSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(timer.challengeElapsedSeconds, 90, accuracy: 0.001)

        timer.resume()
        clock.value = 100
        XCTAssertEqual(timer.activeSeconds, 40, accuracy: 0.001)
        XCTAssertEqual(timer.challengeElapsedSeconds, 100, accuracy: 0.001)
    }

    // MARK: - Восстановление после перезапуска процесса

    /// Снимок партии, снятой с диска: она уже началась и часть времени сыграна.
    /// Монотонная шкала прежнего процесса при этом потеряна безвозвратно —
    /// от него остались только календарные метки.
    private func savedSnapshot(startedAt: Double,
                               activeSeconds: Double,
                               challengeSeconds: Double,
                               suspendedAt: Double?) -> TimingSnapshot {
        var snapshot = TimingSnapshot()
        snapshot.timingStartedAt = Date(timeIntervalSinceReferenceDate: startedAt)
        snapshot.activeSecondsAtSave = activeSeconds
        snapshot.challengeElapsedAtSave = challengeSeconds
        snapshot.suspendedAt = suspendedAt.map { Date(timeIntervalSinceReferenceDate: $0) }
        return snapshot
    }

    /// Соревновательные часы Daily обязаны идти и тогда, когда приложения
    /// нет в живых. Без этого выход из игры и перезапуск останавливали бы
    /// таймер испытания — самый дешёвый из возможных эксплойтов.
    ///
    /// Интервал «пока приложения не было» известен только по календарю, а
    /// дальше время снова считает монотонная шкала нового процесса. Тест
    /// проверяет стык этих двух шкал: мёртвое время засчитано РОВНО ОДИН РАЗ,
    /// не потеряно и не удвоено, и в активное время не попало.
    func testRestoreCreditsDeadTimeToChallengeClockExactlyOnce() {
        let clock = SplitClock()
        let saved = savedSnapshot(startedAt: 0, activeSeconds: 300,
                                  challengeSeconds: 300, suspendedAt: 300)

        // Новый процесс: монотонная шкала начинается заново с нуля,
        // календарь ушёл на 600 секунд вперёд от момента приостановки.
        clock.value = 0
        clock.wall = Date(timeIntervalSinceReferenceDate: 900)
        var timer = GameTimer(snapshot: saved, clock: clock)
        timer.restore(wallClockNow: clock.wallClock)

        XCTAssertEqual(timer.challengeElapsedSeconds, 900, accuracy: 0.001,
                       "время, пока приложение было мертво, не засчитано в Daily")
        XCTAssertEqual(timer.activeSeconds, 300, accuracy: 0.001,
                       "мёртвое время не является активным — доски игрок не видел")

        // Экран появился через пять секунд после восстановления: ровно этот
        // порядок даёт `GameSessionStore.init` → `GameView.task` → `startTiming()`.
        clock.value = 5
        XCTAssertEqual(timer.challengeElapsedSeconds, 905, accuracy: 0.001,
                       "до возобновления соревновательные часы обязаны идти")
        timer.start()
        XCTAssertEqual(timer.snapshot.timingStartedAt,
                       Date(timeIntervalSinceReferenceDate: 0),
                       "`start()` на восстановленной партии обязан быть no-op")
        timer.resume()

        clock.value = 15
        XCTAssertEqual(timer.challengeElapsedSeconds, 915, accuracy: 0.001,
                       "интервал восстановления засчитан дважды или потерян")
        XCTAssertEqual(timer.activeSeconds, 310, accuracy: 0.001,
                       "активное время обязано продолжиться с сохранённого")
    }

    /// Партия, сохранённая посреди хода (процесс убит без ухода в фон),
    /// обязана потерять право на бонус темпа: между ходами прошло неизвестно
    /// сколько реального времени, и «быстрое» решение здесь уже не сравнимо
    /// ни с медианой задачи, ни с личным рекордом.
    func testRestoreDropsPaceBonusOfSessionSavedWhileRunning() {
        let clock = SplitClock()
        let saved = savedSnapshot(startedAt: 0, activeSeconds: 120,
                                  challengeSeconds: 120, suspendedAt: nil)
        XCTAssertTrue(saved.speedEligible,
                      "снимок обязан приходить с правом на бонус — иначе тест ничего не доказывает")

        clock.wall = Date(timeIntervalSinceReferenceDate: 500)
        var timer = GameTimer(snapshot: saved, clock: clock)
        timer.restore(wallClockNow: clock.wallClock)

        XCTAssertFalse(timer.snapshot.speedEligible,
                       "партия пережила перезапуск процесса — бонус темпа ей больше не положен")
        // Часы шли вперёд: аномалии нет, и Daily партия не теряет.
        XCTAssertFalse(timer.snapshot.clockAnomalyDetected)
        XCTAssertTrue(timer.snapshot.leaderboardEligible)

        timer.start()
        timer.resume()
        clock.value = 10
        XCTAssertEqual(timer.activeSeconds, 130, accuracy: 0.001,
                       "активное время обязано продолжиться, а не начаться заново")
    }

    /// Откат системных часов назад между запусками — это либо сбой, либо
    /// попытка удешевить соревновательное время. Партию доиграть можно,
    /// но в leaderboard она не идёт, и признак обязан дойти до потребителя.
    func testRestoreWithRolledBackClockLosesLeaderboardButNotTheGame() {
        let clock = SplitClock()
        let saved = savedSnapshot(startedAt: 1_000, activeSeconds: 60,
                                  challengeSeconds: 60, suspendedAt: 1_200)
        // Журнал помощи чист: право на leaderboard снимают именно часы.
        let ledger = AssistanceUsageLedger()
        let version = DailySchedule.competitionVersion(puzzleID: "p-1")
        XCTAssertTrue(DailyScore.isLeaderboardEligible(
            ledger: ledger, timing: saved,
            savedCompetitionVersion: version, activeCompetitionVersion: version),
                      "до восстановления партия имела право на leaderboard")

        // Часы переведены назад — до момента старта партии.
        clock.wall = Date(timeIntervalSinceReferenceDate: 900)
        var timer = GameTimer(snapshot: saved, clock: clock)
        timer.restore(wallClockNow: clock.wallClock)

        XCTAssertTrue(timer.snapshot.clockAnomalyDetected)
        XCTAssertFalse(timer.snapshot.leaderboardEligible)
        XCTAssertFalse(DailyScore.isLeaderboardEligible(
            ledger: ledger, timing: timer.snapshot,
            savedCompetitionVersion: version, activeCompetitionVersion: version),
                       "аномалия часов обязана дойти до правила leaderboard")
        XCTAssertEqual(timer.challengeElapsedSeconds, 60, accuracy: 0.001,
                       "откат часов не имеет права УМЕНЬШИТЬ соревновательное время")

        // Партия при этом играется дальше как обычно.
        timer.start()
        timer.resume()
        clock.value = 30
        XCTAssertEqual(timer.activeSeconds, 90, accuracy: 0.001)
    }

    /// Часы можно откатить и на меньшую величину — так, что старт партии
    /// остаётся в прошлом, а её приостановка оказывается «в будущем».
    /// Эта ветка ловит ровно тот случай, когда назад переводят уже во время
    /// паузы, и она обязана срабатывать самостоятельно.
    func testRestoreDetectsRollbackPastSuspensionOnly() {
        let clock = SplitClock()
        let saved = savedSnapshot(startedAt: 1_000, activeSeconds: 60,
                                  challengeSeconds: 60, suspendedAt: 1_200)
        clock.wall = Date(timeIntervalSinceReferenceDate: 1_100)
        var timer = GameTimer(snapshot: saved, clock: clock)
        timer.restore(wallClockNow: clock.wallClock)

        XCTAssertTrue(timer.snapshot.clockAnomalyDetected,
                      "приостановка «в будущем» — такая же аномалия, как старт в будущем")
        XCTAssertFalse(timer.snapshot.leaderboardEligible)
        XCTAssertEqual(timer.challengeElapsedSeconds, 60, accuracy: 0.001)
    }

    /// Откат часов ловится и у партии, сохранённой без приостановки: там
    /// сравнивать можно только с моментом старта, и эта ветка обязана
    /// работать сама по себе, без второй.
    func testRestoreDetectsRollbackBeforeStartWithoutSuspension() {
        let clock = SplitClock()
        let saved = savedSnapshot(startedAt: 1_000, activeSeconds: 60,
                                  challengeSeconds: 60, suspendedAt: nil)
        clock.wall = Date(timeIntervalSinceReferenceDate: 500)
        var timer = GameTimer(snapshot: saved, clock: clock)
        timer.restore(wallClockNow: clock.wallClock)

        XCTAssertTrue(timer.snapshot.clockAnomalyDetected,
                      "старт партии оказался в будущем — часы переводили назад")
        XCTAssertFalse(timer.snapshot.leaderboardEligible)
    }

    /// Приложение могут убить и второй раз подряд, ни разу не дойдя до
    /// возобновления. Каждое восстановление обязано переставить метку
    /// приостановки на «сейчас»: иначе следующее посчитало бы тот же
    /// мёртвый интервал заново и раздуло соревновательное время Daily.
    func testSecondRestoreDoesNotRecountTheSameDeadTime() {
        let first = SplitClock()
        let saved = savedSnapshot(startedAt: 0, activeSeconds: 300,
                                  challengeSeconds: 300, suspendedAt: 300)
        first.wall = Date(timeIntervalSinceReferenceDate: 900)
        var timer = GameTimer(snapshot: saved, clock: first)
        timer.restore(wallClockNow: first.wallClock)
        XCTAssertEqual(timer.snapshot.suspendedAt, first.wall,
                       "восстановление обязано переставить метку приостановки на «сейчас»")

        // Процесс убит снова, до `startTiming()`. На диск ушёл снимок как есть.
        let second = SplitClock()
        second.wall = Date(timeIntervalSinceReferenceDate: 1_500)
        var restarted = GameTimer(snapshot: timer.snapshot, clock: second)
        restarted.restore(wallClockNow: second.wallClock)

        // Партия началась в 0 по календарю, сейчас 1500: столько же обязано
        // быть и на соревновательных часах — ни секундой больше.
        XCTAssertEqual(restarted.challengeElapsedSeconds, 1_500, accuracy: 0.001,
                       "мёртвый интервал посчитан дважды")
        XCTAssertEqual(restarted.activeSeconds, 300, accuracy: 0.001)
    }

    /// Свежая партия проходит через ту же точку восстановления (она стоит
    /// в `init` игрового экрана и вызывается безусловно), и для неё вызов
    /// обязан быть no-op. Иначе КАЖДАЯ партия начиналась бы без права
    /// на бонус темпа — молча и на любых часах хоста.
    func testRestoreIsNoOpForFreshSession() {
        let clock = SplitClock()
        clock.wall = Date(timeIntervalSinceReferenceDate: -5_000)
        var timer = GameTimer(clock: clock)
        timer.restore(wallClockNow: clock.wallClock)

        XCTAssertNil(timer.snapshot.timingStartedAt)
        XCTAssertTrue(timer.snapshot.speedEligible,
                      "непачатая партия не имеет права терять бонус темпа")
        XCTAssertFalse(timer.snapshot.clockAnomalyDetected)
        XCTAssertTrue(timer.snapshot.leaderboardEligible)

        timer.start()
        clock.value = 40
        XCTAssertEqual(timer.activeSeconds, 40, accuracy: 0.001)
        XCTAssertEqual(timer.challengeElapsedSeconds, 40, accuracy: 0.001)
    }

    /// Системные часы обязаны быть неубывающими. Sleep в тесте не ставим —
    /// проверяется контракт на подряд идущих чтениях, а не скорость хода.
    func testSystemClockNeverGoesBackwards() {
        let clock = SystemMonotonicClock()
        var previous = clock.now
        for _ in 0..<2_000 {
            let current = clock.now
            XCTAssertGreaterThanOrEqual(current, previous)
            previous = current
        }
    }

    /// Монотонные часы обязаны жить на собственной шкале, а не на календарной.
    ///
    /// Проверка нарочно сформулирована БЕЗ обращения к календарю: сравнивать
    /// `now` с `timeIntervalSinceReferenceDate` значило бы молча требовать,
    /// чтобы на машине было верное системное время. На симуляторе со
    /// сброшенной датой, на CI с несинхронизированными часами и на устройстве,
    /// загруженном в эпоху Unix, такой тест падал бы на исправном коде.
    ///
    /// Границы держатся на том, что монотонная шкала стартует вместе с
    /// процессом: `now` не может быть отрицательным и ограничен временем
    /// жизни тестового прогона. Любая реализация через `Date()` — хоть
    /// от 2001 года, хоть от 1970-го — выходит за эти границы на порядки
    /// при любых мыслимых часах хоста.
    func testMonotonicScaleIsDetachedFromCalendarScale() {
        let clock = SystemMonotonicClock()
        let now = clock.now
        XCTAssertGreaterThanOrEqual(now, 0, "`now` ушёл в минус — это не монотонная шкала")
        XCTAssertLessThan(now, 600, "`now` считает календарное время, а не монотонное")
    }

    /// Монотонная шкала обязана идти С ТОЙ ЖЕ СКОРОСТЬЮ, что и календарная.
    /// Только это делает `activeSeconds` сопоставимым с медианой задачи
    /// (`expectedActiveSecondsP50`) и с прошлыми personal best. Часы, идущие
    /// вдвое медленнее, остаются и монотонными, и неубывающими, и оторванными
    /// от календаря — все остальные проверки они проходят, — но дарят игроку
    /// бонус темпа и рекорд за партию, которую он не отыграл.
    ///
    /// Сравниваются разности двух пар почти одновременных чтений, поэтому
    /// на результат влияет не длительность сна (под нагрузкой она может
    /// «переспать» сколько угодно), а только зазор внутри пары. Отсюда и
    /// допуск: 150 мс с запасом перекрывают вытеснение потока между двумя
    /// соседними строками, но более чем втрое меньше расхождения в 0.5 с,
    /// которое дала бы шкала со скоростью 0.5× или 2×.
    func testMonotonicClockAdvancesAtWallRate() async throws {
        let clock = SystemMonotonicClock()
        let monotonicStart = clock.now
        let wallStart = Date()

        try await Task.sleep(for: .seconds(1))

        let monotonicElapsed = clock.now - monotonicStart
        let wallElapsed = Date().timeIntervalSince(wallStart)
        XCTAssertEqual(monotonicElapsed, wallElapsed, accuracy: 0.15,
                       "монотонная шкала идёт не со скоростью календарной: "
                       + "\(monotonicElapsed) с против \(wallElapsed) с")
    }

    /// Детектор затыка считает только разности, поэтому он обязан работать
    /// на любой эпохе. У монотонных часов `now` в начале партии близко к нулю:
    /// признак «игрок ещё ничего не сделал» не имеет права зависеть от того,
    /// насколько велико абсолютное значение часов.
    func testStruggleIdleSignalDoesNotDependOnClockEpoch() {
        let detector = StruggleDetector()
        let signal = detector.evaluate(now: 61, gameSeconds: 61, expectedSeconds: 600,
                                       filledRatio: 0.1, hasLogicalStep: true)
        XCTAssertEqual(signal?.reason, .idleWithAvailableStep)

        // Любая активность гасит сигнал — и на маленьких значениях тоже.
        var active = StruggleDetector()
        active.recordActivity(at: 60)
        XCTAssertNil(active.evaluate(now: 61, gameSeconds: 61, expectedSeconds: 600,
                                     filledRatio: 0.1, hasLogicalStep: true))
    }

    @available(*, deprecated)
    func testDailyScorePenalties() {
        var ledger = AssistanceUsageLedger()
        ledger.record(hintLayer: .techniqueName)
        ledger.record(candidateAid: .wholeBoard)
        ledger.record(validationAid: .manualCheck)
        ledger.registerSolutionMismatch(cell: 1, digit: 2)

        // Проверяется СТАРАЯ формула: она больше не применяется к новым
        // партиям, но обязана продолжать читать архивные результаты
        // одинаково — иначе история Daily поедет.
        let score = legacyDailyScore(challengeElapsedSeconds: 600, ledger: ledger)
        XCTAssertEqual(score, 10000 - 600 - 250 - 800 - 600 - 400)
    }

    func testWeeklyRhythmCountsDistinctDays() {
        let calendar = Calendar(identifier: .iso8601)
        let now = Date()
        let dates = (0..<4).compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }
            + [now]   // дубликат сегодняшнего дня не должен считаться дважды
        let rhythm = WeeklyRhythm.compute(completionDates: dates, now: now, calendar: calendar)
        XCTAssertEqual(rhythm.completedDays, 4)
    }
}

/// Детектор затыка — единственное место в приложении, которое заговаривает
/// с игроком по собственной инициативе. Всё, что делает его НЕнавязчивым,
/// живёт здесь в виде четырёх порогов и трёх счётчиков, и ни один экран
/// об их нарушении не сообщит: слишком ранний или слишком частый нудж
/// выглядит как «работает», просто раздражает.
///
/// Поэтому проверяются именно границы (за секунду до порога и ровно на нём),
/// а не «сигнал в принципе появляется»: сдвиг любого порога на шаг —
/// это ровно та ошибка, которую нельзя увидеть глазами на симуляторе.
///
/// Часы здесь — обычные Double из монотонной шкалы, так что все тесты
/// детерминированы и не зависят ни от календаря, ни от порядка запуска.
final class StruggleDetectorTests: XCTestCase {

    /// `gameSeconds` по умолчанию равен `now`: это партия, начавшаяся
    /// в нуле монотонной шкалы и ни разу не приостановленная.
    /// `expectedSeconds: 600` держит порог «слишком долго» на 1080 секундах —
    /// заведомо дальше всех моментов, которые проверяются в других тестах,
    /// чтобы overtime не подменял собой проверяемую причину.
    private func signal(_ detector: StruggleDetector,
                        now: Double,
                        gameSeconds: Double? = nil,
                        expectedSeconds: Double = 600,
                        filledRatio: Double = 0.3,
                        hasLogicalStep: Bool = true) -> StruggleSignal? {
        detector.evaluate(now: now,
                          gameSeconds: gameSeconds ?? now,
                          expectedSeconds: expectedSeconds,
                          filledRatio: filledRatio,
                          hasLogicalStep: hasLogicalStep)
    }

    // MARK: - Пороги тишины

    /// Первая минута партии неприкосновенна, даже когда повод уже железный.
    /// Три конфликта подряд — сильнейший сигнал детектора, и всё равно он
    /// обязан промолчать: предложение помощи на 59-й секунде читается как
    /// «ты не справишься», а не как забота.
    func testNoNudgeBeforeFirstMinute() {
        var detector = StruggleDetector(startedAt: 0)
        detector.recordConflict(at: 10)
        detector.recordConflict(at: 20)
        detector.recordConflict(at: 30)

        XCTAssertNil(signal(detector, now: 59), "до минуты детектор обязан молчать")
        XCTAssertEqual(signal(detector, now: 60)?.reason, .repeatedConflicts,
                       "ровно на минуте порог уже пройден")
    }

    /// Два предложения за партию — потолок. Третье не появляется никогда,
    /// сколько бы поводов ни накопилось: игрок, дважды сказавший «нет»
    /// действием (не приняв подсказку), уже ответил.
    ///
    /// Последняя проверка нарочно сделана в момент, когда сработал бы и
    /// overtime: лимит обязан быть сильнее любой причины, а не только простоя.
    func testAtMostTwoNudgesPerGame() {
        var detector = StruggleDetector(startedAt: 0)

        guard let first = signal(detector, now: 100) else {
            return XCTFail("простой в 100 секунд обязан дать сигнал")
        }
        XCTAssertEqual(first.reason, .idleWithAvailableStep)
        detector.markShown(first, at: 100)

        guard let second = signal(detector, now: 220) else {
            return XCTFail("после кулдауна второе предложение допустимо")
        }
        detector.markShown(second, at: 220)
        XCTAssertEqual(detector.nudgesShown, 2)

        XCTAssertNil(signal(detector, now: 340), "третьего предложения не бывает")
        XCTAssertNil(signal(detector, now: 10_000),
                     "лимит сильнее даже overtime, порог которого здесь давно пройден")
    }

    /// Между предложениями — не меньше двух минут. Два ножа подряд
    /// превращают «мягкое предложение» в назойливость, а игрок в этот момент
    /// как раз думает.
    func testCooldownBetweenNudges() {
        var detector = StruggleDetector(startedAt: 0)
        guard let first = signal(detector, now: 100) else {
            return XCTFail("простой в 100 секунд обязан дать сигнал")
        }
        detector.markShown(first, at: 100)

        XCTAssertNil(signal(detector, now: 219.9), "119.9 секунды кулдауна ещё не истекли")
        XCTAssertEqual(signal(detector, now: 220)?.reason, .idleWithAvailableStep,
                       "ровно на 120 секундах детектор снова вправе говорить")
    }

    /// «Не сейчас» — это ответ на всю партию, а не на текущее предложение.
    /// Ни новый повод, ни последующая активность не возвращают детектор
    /// к жизни: иначе кнопка «не сейчас» врёт игроку.
    func testMuteSilencesDetectorForTheRestOfTheGame() {
        var detector = StruggleDetector(startedAt: 0)
        detector.recordConflict(at: 60)
        detector.recordConflict(at: 61)
        detector.recordConflict(at: 62)
        XCTAssertEqual(signal(detector, now: 63)?.reason, .repeatedConflicts,
                       "повод есть — иначе тест ничего не доказывает")

        detector.mute()
        XCTAssertTrue(detector.isMutedForGame)
        XCTAssertNil(signal(detector, now: 63))

        detector.recordActivity(at: 100)
        detector.recordConflict(at: 101)
        detector.recordConflict(at: 102)
        detector.recordConflict(at: 103)
        XCTAssertNil(signal(detector, now: 5_000), "молчание не снимается ничем до конца партии")
    }

    // MARK: - Простой

    /// Любое действие игрока обнуляет отсчёт простоя. Порог в 75 секунд
    /// считается от последнего действия, а не от начала партии, — иначе
    /// детектор лез бы к человеку, который спокойно и непрерывно играет.
    func testActivityResetsIdleSignal() {
        var detector = StruggleDetector(startedAt: 0)
        XCTAssertEqual(signal(detector, now: 80)?.reason, .idleWithAvailableStep)

        detector.recordActivity(at: 80)
        XCTAssertNil(signal(detector, now: 154), "с последнего действия прошло 74 секунды")
        XCTAssertEqual(signal(detector, now: 155)?.reason, .idleWithAvailableStep,
                       "ровно 75 секунд — порог простоя пройден")
    }

    /// Конфликт и откат — тоже действия игрока, а не «ничего не происходит».
    /// Если бы они не двигали отметку активности, детектор мог бы
    /// одновременно считать игрока и слишком активным, и простаивающим.
    func testConflictAndUndoCountAsActivity() {
        var conflicting = StruggleDetector(startedAt: 0)
        conflicting.recordConflict(at: 80)
        XCTAssertNil(signal(conflicting, now: 154), "конфликт — это действие, простой начался заново")

        var undoing = StruggleDetector(startedAt: 0)
        undoing.recordUndo(at: 80)
        XCTAssertNil(signal(undoing, now: 154), "откат — это действие, простой начался заново")
    }

    // MARK: - Окна конфликтов и откатов

    /// «Несколько конфликтов за короткое окно» — это про панику, а не про
    /// сумму ошибок за партию. Конфликты, разъехавшиеся дальше минуты,
    /// не имеют права накапливаться до порога.
    func testConflictsOutsideWindowDoNotAccumulate() {
        var detector = StruggleDetector(startedAt: 0)
        detector.recordConflict(at: 10)
        detector.recordConflict(at: 80)    // первый уехал за окно и выброшен
        detector.recordConflict(at: 130)
        XCTAssertNil(signal(detector, now: 131), "в окне только два конфликта из трёх записанных")

        detector.recordConflict(at: 135)
        XCTAssertEqual(signal(detector, now: 136)?.reason, .repeatedConflicts,
                       "три конфликта внутри окна — повод")
    }

    /// Откатов нужно больше, чем конфликтов, и в более узком окне: Undo —
    /// нормальный рабочий инструмент, паникой он становится только сериями.
    func testUndoNeedsFourInsideItsWindow() {
        var detector = StruggleDetector(startedAt: 0)
        detector.recordUndo(at: 60)
        detector.recordUndo(at: 70)
        detector.recordUndo(at: 80)
        XCTAssertNil(signal(detector, now: 81), "трёх откатов ещё недостаточно")

        detector.recordUndo(at: 90)
        XCTAssertEqual(signal(detector, now: 91)?.reason, .repeatedUndo)

        // Те же четыре отката, растянутые шире окна, — это не паника.
        var unhurried = StruggleDetector(startedAt: 0)
        for time in stride(from: 60.0, through: 260.0, by: 50.0) { unhurried.recordUndo(at: time) }
        XCTAssertNil(signal(unhurried, now: 261))
    }

    /// Порядок причин — часть контракта, а не деталь реализации: игроку
    /// показывают текст про конкретную беду («много конфликтов»), а не
    /// общий «вы давно не ходили». Совпасть могут все причины сразу.
    func testMostSpecificReasonWins() {
        var everything = StruggleDetector(startedAt: 0)
        for time in [60.0, 61, 62] { everything.recordConflict(at: time) }
        for time in [63.0, 64, 65, 66] { everything.recordUndo(at: time) }
        XCTAssertEqual(signal(everything, now: 200)?.reason, .repeatedConflicts,
                       "конфликты важнее откатов и простоя")

        var undoAndIdle = StruggleDetector(startedAt: 0)
        for time in [60.0, 61, 62, 63] { undoAndIdle.recordUndo(at: time) }
        XCTAssertEqual(signal(undoAndIdle, now: 200)?.reason, .repeatedUndo,
                       "откаты важнее простоя")
    }

    // MARK: - Overtime

    /// «Слишком долго» предлагается один раз за партию, даже когда лимит
    /// предложений ещё не исчерпан: повод не исчезает сам (время только
    /// растёт), и без этого флага он бился бы каждые две минуты до конца.
    func testOvertimeOffersOnlyOnce() {
        var detector = StruggleDetector(startedAt: 0)
        detector.recordActivity(at: 179)   // простой гасим, чтобы причина была ровно одна
        guard let overtime = signal(detector, now: 180, expectedSeconds: 100) else {
            return XCTFail("1.8× медианы при пустой доске обязаны дать overtime")
        }
        XCTAssertEqual(overtime.reason, .overtime)
        detector.markShown(overtime, at: 180)

        detector.recordActivity(at: 300)
        XCTAssertNil(signal(detector, now: 301, expectedSeconds: 100),
                     "кулдаун истёк и лимит не исчерпан, но overtime уже был")
    }

    /// Три условия overtime проверяются по отдельности: время сверх медианы,
    /// почти не тронутая доска и сама медиана. Каждое из них в одиночку
    /// превращает «застрял» в «просто играет медленно и успешно».
    func testOvertimeRequiresTimeAndStalledBoardAndKnownMedian() {
        var detector = StruggleDetector(startedAt: 0)
        detector.recordActivity(at: 179)

        XCTAssertNil(signal(detector, now: 179.9, expectedSeconds: 100),
                     "до 1.8× медианы это ещё не «слишком долго»")
        XCTAssertEqual(signal(detector, now: 180, expectedSeconds: 100)?.reason, .overtime)
        XCTAssertNil(signal(detector, now: 180, expectedSeconds: 100, filledRatio: 0.75),
                     "доска на три четверти собрана — человек не застрял, он идёт к концу")
        XCTAssertNil(signal(detector, now: 180, expectedSeconds: 0),
                     "медианы у задачи нет — сравнивать не с чем")
    }

    // MARK: - Наличие логического хода

    /// Отсутствие логического хода глушит ровно те две причины, которые
    /// предлагают «поищите ход»: звать искать несуществующее — издевательство.
    /// Конфликты и откаты про доску ничего не утверждают, они про состояние
    /// игрока, и обязаны проходить дальше.
    func testMissingLogicalStepSuppressesOnlyBoardBasedReasons() {
        let idle = StruggleDetector(startedAt: 0)
        XCTAssertEqual(signal(idle, now: 200, expectedSeconds: 100)?.reason, .idleWithAvailableStep)
        XCTAssertNil(signal(idle, now: 200, expectedSeconds: 100, hasLogicalStep: false),
                     "без логического хода молчат и простой, и overtime")

        var conflicting = StruggleDetector(startedAt: 0)
        for time in [60.0, 70, 80] { conflicting.recordConflict(at: time) }
        XCTAssertEqual(signal(conflicting, now: 90, hasLogicalStep: false)?.reason, .repeatedConflicts,
                       "конфликты не зависят от того, есть ли ход на доске")

        var undoing = StruggleDetector(startedAt: 0)
        for time in [60.0, 70, 80, 90] { undoing.recordUndo(at: time) }
        XCTAssertEqual(signal(undoing, now: 95, hasLogicalStep: false)?.reason, .repeatedUndo,
                       "откаты не зависят от того, есть ли ход на доске")
    }

    // MARK: - Последствия показа

    /// Показанное предложение забирает свой повод с собой. Иначе те же три
    /// конфликта выстрелили бы второй раз сразу после кулдауна и мгновенно
    /// съели лимит партии, ничего нового игроку не сообщив.
    func testShownNudgeConsumesItsReason() {
        var detector = StruggleDetector(startedAt: 0)
        for time in [60.0, 61, 62] { detector.recordConflict(at: time) }
        guard let conflicts = signal(detector, now: 63) else {
            return XCTFail("три конфликта обязаны дать сигнал")
        }
        detector.markShown(conflicts, at: 63)
        XCTAssertEqual(detector.nudgesShown, 1)

        XCTAssertEqual(signal(detector, now: 183)?.reason, .idleWithAvailableStep,
                       "старые конфликты списаны, остался только простой")
    }

    /// Игрок открыл подсказку сам — предлагать её же бессмысленно, но и
    /// лимит партии на это тратить нечестно: предложения он не видел.
    /// Детектор берёт паузу и обнуляет счётчики, а нудж остаётся в запасе.
    func testSelfServedHintPausesDetectorWithoutSpendingNudge() {
        var detector = StruggleDetector(startedAt: 0)
        for time in [60.0, 61, 62] { detector.recordConflict(at: time) }
        XCTAssertEqual(signal(detector, now: 63)?.reason, .repeatedConflicts)

        detector.recordHintOpened(at: 63)
        XCTAssertEqual(detector.nudgesShown, 0, "самостоятельная подсказка не тратит лимит")
        XCTAssertNil(signal(detector, now: 140),
                     "подсказка запускает тот же кулдаун, что и показанное предложение")
        XCTAssertEqual(signal(detector, now: 183)?.reason, .idleWithAvailableStep,
                       "после кулдауна детектор жив, но конфликты уже списаны")
    }
}

/// Решение разбирается в цифры ОДИН раз и дальше живёт кэшем: игровой экран
/// строит его в `init` и сверяет с ним каждый ход игрока.
///
/// Кэш здесь — самое тихое место для ошибки во всём приложении. Разойдись он
/// со строкой решения хоть на одну клетку или на один сдвиг — верные ходы
/// начнут отмечаться красным, неверные пройдут как правильные, счёт и рейтинг
/// посчитаются по ним же, и НИ ОДИН экран об этом не сообщит: сверять кэшу
/// не с чем, он и есть источник ответа. Поэтому проверяется не «работает
/// на примере», а «совпадает со строкой решения в каждой клетке».
final class PuzzleSolutionTests: XCTestCase {

    private static let solution =
        "534678912672195348198342567859761423426853791713924856961537284287419635345286179"

    /// Верная цифра принимается, любая другая — нет. Проверяется на всех 81
    /// клетке и всех девяти цифрах: одна выборочная клетка не отличила бы
    /// правильный кэш от сдвинутого на единицу или собранного задом наперёд.
    func testMatchesAgreesWithSolutionStringInEveryCell() {
        let solution = PuzzleSolution(Self.solution)
        let characters = Array(Self.solution)
        XCTAssertEqual(solution.count, 81)
        for cell in 0..<81 {
            guard let correct = characters[cell].wholeNumberValue else {
                return XCTFail("решение содержит не цифру в клетке \(cell)")
            }
            XCTAssertEqual(solution.digit(at: cell), correct, "клетка \(cell)")
            for digit in 1...9 {
                XCTAssertEqual(solution.matches(cell: cell, digit: digit),
                               digit == correct,
                               "клетка \(cell), цифра \(digit)")
            }
        }
    }

    /// Кэш обязан отвечать одно и то же сколько угодно раз: сверка вызывается
    /// и на каждый ход, и пачкой за Check, и повторно при воспроизведении
    /// журнала — три разных пути обязаны получить один ответ.
    func testRepeatedLookupsAreStable() {
        let solution = PuzzleSolution(Self.solution)
        let first = (0..<81).map { solution.digit(at: $0) }
        let second = (0..<81).map { solution.digit(at: $0) }
        XCTAssertEqual(first, second)
        XCTAssertEqual(solution, PuzzleSolution(Self.solution),
                       "два разбора одной строки разошлись")
    }

    /// Клетка вне решения — «неизвестно», а не «неверно». Молчаливый `false`
    /// на повреждённом каталоге превратил бы битые данные в поток «ошибок
    /// игрока»; `nil` заставляет вызывающего решить это явно.
    func testCellOutsideSolutionHasNoDigit() {
        let solution = PuzzleSolution(Self.solution)
        XCTAssertNil(solution.digit(at: 81))
        XCTAssertNil(solution.digit(at: -1))
        XCTAssertFalse(solution.matches(cell: 81, digit: 5))
    }

    /// Символ, который цифрой не является, не должен совпасть ни с чем.
    /// Обратное значило бы, что повреждённая клетка принимает любой ввод —
    /// худший из возможных исходов для проверки ходов.
    func testNonDigitCharacterMatchesNoDigit() {
        let solution = PuzzleSolution("x" + Self.solution.dropFirst())
        for digit in 1...9 {
            XCTAssertFalse(solution.matches(cell: 0, digit: digit), "цифра \(digit)")
        }
        // Соседние клетки от повреждённой не съезжают.
        XCTAssertEqual(solution.digit(at: 1), 3)
    }
}
