//
//  JournalArchiveTests.swift
//  NamiDomainTests
//
//  Created by artemoffM8.
//
//  Восстановление — самое опасное место: ошибка здесь молчит. Поэтому
//  проверяется не только счастливый путь, но и каждый способ испортить данные.
//

import XCTest
@testable import NamiDomain

final class JournalArchiveTests: XCTestCase {

    private static let solution =
        "534678912672195348198342567859761423426853791713924856961537284287419635345286179"
    private static let givens =
        "530070000600195000098000060800060003400803001700020006060000280000419005000080079"
    private static let freeCells = [2, 3, 5, 6, 7, 8, 10, 11]

    private func descriptor() -> SessionDescriptor {
        SessionDescriptor(puzzleID: "p", givens: Self.givens, solution: Self.solution,
                          catalogVersion: "test", difficultyD: 1200,
                          mode: .ranked, policy: .immediateValidated)
    }

    /// Партия из `moves` верных ходов. Возвращает журнал и доску, какой её
    /// увидит снимок.
    private func playedSession(moves: Int) -> (SessionJournal, BoardState) {
        var journal = SessionJournal()
        try! journal.appendTransaction([.sessionStarted(descriptor())])
        var sequence: UInt64 = 0
        for cell in Self.freeCells.prefix(moves) {
            sequence += 1
            let digit = Int(String(Array(Self.solution)[cell]))!
            try! journal.appendTransaction([
                .digitCommitted(cell: cell, digit: digit, source: .user),
                .validationApplied(ValidationBatch(
                    validationID: UUID(), isManualCheck: false, isRuleOfMode: false,
                    valueRevision: sequence,
                    outcomes: [PlacementOutcome(cell: cell, digit: digit,
                                                correct: true, commitSequence: sequence)],
                    completedGroups: []))
            ])
        }
        return (journal, journal.replay()!.board)
    }

    // MARK: - Счастливый путь

    /// Ради этого всё и делалось: до журнала счёт не сохранялся вообще,
    /// и восстановленная рейтинговая партия возвращала доску с нулём очков.
    func testScoreSurvivesRoundTrip() {
        let (journal, board) = playedSession(moves: 5)
        let live = journal.replay()!.score
        XCTAssertGreaterThan(live.displayScore, 0, "иначе тест ничего не проверяет")

        switch JournalArchive.restore(JournalArchive.encode(journal), board: board) {
        case let .restored(_, score):
            XCTAssertEqual(score, live)
            XCTAssertEqual(score.displayScore, live.displayScore)
            XCTAssertTrue(score.isRecordable)
        default:
            XCTFail("журнал обязан был восстановиться")
        }
    }

    func testStreakAndMultiplierSurvive() {
        let (journal, board) = playedSession(moves: 8)
        guard case let .restored(_, score) =
                JournalArchive.restore(JournalArchive.encode(journal), board: board) else {
            return XCTFail("не восстановилось")
        }
        XCTAssertEqual(score.streak, 8)
        XCTAssertGreaterThan(score.multiplierPermille, 1000, "множитель обязан пережить запись")
    }

    // MARK: - Совместимость

    /// Партии, сохранённые до появления журнала. Они обязаны открываться,
    /// а не считаться повреждёнными.
    func testEmptyArchiveIsNotAnError() {
        let (_, board) = playedSession(moves: 3)
        XCTAssertEqual(JournalArchive.restore(Data(), board: board), .empty)
    }

    // MARK: - Порча

    func testGarbageIsReportedNotCrashed() {
        let (_, board) = playedSession(moves: 3)
        guard case let .unreadable(reason) =
                JournalArchive.restore(Data("не json".utf8), board: board) else {
            return XCTFail("мусор обязан быть отвергнут")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    /// Потерянное событие обязано ОСТАНОВИТЬ восстановление. Если бы разрыв
    /// последовательности молча пропускался, партия открылась бы с неверным
    /// счётом и никто бы этого не заметил.
    func testMissingEventStopsRestoration() {
        let (journal, board) = playedSession(moves: 5)
        var envelopes = journal.envelopes
        envelopes.remove(at: 4)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(envelopes)

        guard case let .unreadable(reason) = JournalArchive.restore(data, board: board) else {
            return XCTFail("пропуск в последовательности обязан быть замечен")
        }
        XCTAssertTrue(reason.contains("sequenceGap") || reason.contains("Gap"),
                      "причина должна называть разрыв, а не что-то общее: \(reason)")
    }

    /// Испорченная на диске нагрузка обязана ОСТАНОВИТЬ восстановление.
    ///
    /// Здесь меняется только сама запись хода; поле `payloadDigest` остаётся
    /// прежним — именно так выглядит битый байт в файле. Пока отпечаток не
    /// пересчитывался из нагрузки, такой журнал открывался как здоровый, и
    /// партия молча продолжалась с чужой цифрой на доске и в счёте.
    func testCorruptedPayloadStopsRestoration() {
        let (journal, board) = playedSession(moves: 5)
        let data = JournalArchive.encode(journal)
        guard case .restored = JournalArchive.restore(data, board: board) else {
            return XCTFail("нетронутый журнал обязан восстанавливаться")
        }

        // Клетка 2 в этой задаче решается цифрой 4; подменяем её на 5.
        let json = String(decoding: data, as: UTF8.self)
        let needle = "\"cell\":2,\"digit\":4,\"source\":\"user\""
        XCTAssertTrue(json.contains(needle), "формат записи изменился: \(json.prefix(400))")
        let damaged = Data(json.replacingOccurrences(
            of: needle, with: "\"cell\":2,\"digit\":5,\"source\":\"user\"").utf8)
        XCTAssertNotEqual(damaged, data)

        guard case let .unreadable(reason) = JournalArchive.restore(damaged, board: board) else {
            return XCTFail("подмена нагрузки обязана быть замечена")
        }
        XCTAssertTrue(reason.contains("corruptedPayload"),
                      "причина должна называть порчу нагрузки, а не что-то общее: \(reason)")
    }

    /// Бонус за решённую задачу обязан пережить запись на диск ровно один раз:
    /// ни потеряться от защиты повтора, ни удвоиться при воспроизведении.
    func testCompletionBonusIsRestoredExactlyOnce() {
        let (played, board) = playedSession(moves: 5)
        var journal = played
        try! journal.appendTransaction([
            .puzzleCompleted(elapsedMs: 400_000, expectedMs: 600_000, paceEligible: false)])
        let live = journal.replay()!.score
        XCTAssertGreaterThan(live.budget.completionBonus, 0, "иначе тест ничего не проверяет")

        guard case let .restored(_, score) =
                JournalArchive.restore(JournalArchive.encode(journal), board: board) else {
            return XCTFail("завершённая партия обязана восстановиться")
        }
        XCTAssertEqual(score, live)
        XCTAssertEqual(score.structureTotal, score.budget.completionBonus,
                       "бонус завершения начисляется ровно один раз, групп здесь не было")
        XCTAssertTrue(score.sealed)
    }

    func testTruncatedArchiveRestoresShorterGame() {
        let (journal, _) = playedSession(moves: 6)
        // Обрыв на границе команды — ровно то, что может лежать на диске.
        let cut = journal.envelopeCount(throughCommand: 4)
        var shorter = SessionJournal(sessionID: journal.sessionID)
        for envelope in journal.envelopes.prefix(cut) { try! shorter.accept(envelope) }
        let board = shorter.replay()!.board

        guard case let .restored(_, score) =
                JournalArchive.restore(JournalArchive.encode(shorter), board: board) else {
            return XCTFail("укороченный журнал — это нормальное состояние")
        }
        XCTAssertEqual(score.awardedCellCount, 3)
    }

    // MARK: - Рассинхронизация

    /// Журнал и снимок из разных моментов. Партию не выбрасываем — доска цела,
    /// — но счёт теряет право на таблицу лидеров.
    func testDivergenceKeepsBoardButDropsRecordability() {
        let (journal, _) = playedSession(moves: 5)
        let (_, staleBoard) = playedSession(moves: 2)

        guard case let .distrusted(_, score, reason) =
                JournalArchive.restore(JournalArchive.encode(journal), board: staleBoard) else {
            return XCTFail("расхождение обязано быть замечено")
        }
        XCTAssertFalse(score.isRecordable, "счёту доверять нельзя")
        XCTAssertGreaterThan(score.displayScore, 0, "но партия остаётся играбельной")
        XCTAssertTrue(reason.contains("5") && reason.contains("2"),
                      "причина должна называть оба числа: \(reason)")
    }

    func testMatchingBoardIsTrusted() {
        for moves in 1...8 {
            let (journal, board) = playedSession(moves: moves)
            guard case .restored = JournalArchive.restore(
                JournalArchive.encode(journal), board: board) else {
                return XCTFail("ложное срабатывание сверки на \(moves) ходах")
            }
        }
    }

    func testIntegrityFlagIsSticky() {
        var score = SessionScoreState(budget: SessionScoreBudget(puzzleRating: 1200,
                                                                emptyCellCount: 51))
        XCTAssertTrue(score.isRecordable)
        score.markIntegrityBroken()
        XCTAssertFalse(score.isRecordable)
        SessionScoreReducer.apply(
            .placementConfirmed(cell: 2, digit: 4, correct: true), to: &score)
        XCTAssertFalse(score.isRecordable, "продолжение игры не возвращает доверие")
    }
}
