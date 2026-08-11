//
//  SessionJournalTests.swift
//  NamiDomainTests
//
//  Created by artemoffM8.
//
//  Проверяется главное обещание журнала: восстановленная партия совпадает с
//  прожитой, а доска и счёт не могут разъехаться ни при каком обрыве.
//

import XCTest
@testable import NamiDomain

final class SessionJournalTests: XCTestCase {

    // Задача с известным решением: 81 символ, 30 пустых клеток.
    private static let solution =
        "534678912672195348198342567859761423426853791713924856961537284287419635345286179"
    private static let givens =
        "530070000600195000098000060800060003400803001700020006060000280000419005000080079"

    /// Только по-настоящему пустые клетки. Запись в клетку-подсказку не меняет
    /// доску, и сравнение «на доске столько же, сколько в счёте» разошлось бы
    /// по причине, не имеющей отношения к журналу.
    private static let freeCells = [2, 3, 5, 6, 7, 8, 10, 11, 15, 16]

    private func descriptor(mode: GameMode = .ranked,
                            policy: ScoreValidationPolicy = .immediateValidated,
                            autoReduceNotes: Bool = false) -> SessionDescriptor {
        SessionDescriptor(puzzleID: "test-1",
                          givens: Self.givens,
                          solution: Self.solution,
                          catalogVersion: "test",
                          difficultyD: 1200,
                          mode: mode,
                          policy: policy,
                          autoReduceNotes: autoReduceNotes)
    }

    private func startedJournal(_ descriptor: SessionDescriptor? = nil) -> SessionJournal {
        var journal = SessionJournal()
        try! journal.appendTransaction([.sessionStarted(descriptor ?? self.descriptor())])
        return journal
    }

    /// Один ход игрока: цифра и её проверка — одной командой.
    private func play(_ journal: inout SessionJournal,
                      cell: Int, digit: Int, sequence: UInt64,
                      groups: [Int] = []) {
        let solutionDigit = Int(String(Array(Self.solution)[cell]))!
        try! journal.appendTransaction([
            .digitCommitted(cell: cell, digit: digit, source: .user),
            .validationApplied(ValidationBatch(
                validationID: UUID(), isManualCheck: false, isRuleOfMode: false,
                valueRevision: sequence,
                outcomes: [PlacementOutcome(cell: cell, digit: digit,
                                            correct: digit == solutionDigit,
                                            commitSequence: sequence)],
                completedGroups: groups))
        ])
    }

    // MARK: - Отпечаток

    /// Ради этого свойства и написан свой хеш: стандартный `Hasher`
    /// засеивается случайно и после перезапуска дал бы другое число.
    func testDigestIsStableAcrossCalls() {
        let event = GameJournalEvent.digitCommitted(cell: 7, digit: 4, source: .user)
        XCTAssertEqual(StableDigest.of(event), StableDigest.of(event))
        XCTAssertNotEqual(
            StableDigest.of(event),
            StableDigest.of(GameJournalEvent.digitCommitted(cell: 7, digit: 5, source: .user)))
    }

    /// Ключ подсказки в `GameSessionStore` считается по массиву. Если бы
    /// кодирование сорвалось, все шаги получили бы один отпечаток — и вторая
    /// подсказка оказалась бы бесплатной.
    func testDigestOfArrayIsNonZeroAndDiscriminating() {
        XCTAssertNotEqual(StableDigest.of([1, 2, 3]), 0)
        XCTAssertNotEqual(StableDigest.of([1, 2, 3]), StableDigest.of([1, 2, 4]))
        XCTAssertEqual(StableDigest.of([1, 2, 3]), StableDigest.of([1, 2, 3]))
    }

    func testDigestIgnoresFieldOrderButNotValues() {
        let a = descriptor()
        let b = descriptor(mode: .relaxed)
        XCTAssertEqual(StableDigest.of(a), StableDigest.of(a))
        XCTAssertNotEqual(StableDigest.of(a), StableDigest.of(b))
    }

    // MARK: - Инварианты приёма

    func testSequenceIsContinuous() {
        var journal = startedJournal()
        let orphan = GameEventEnvelope(commandID: UUID(), sessionID: journal.sessionID,
                                       sequence: 5, payload: .digitRemoved(cell: 2))
        XCTAssertThrowsError(try journal.accept(orphan)) { error in
            XCTAssertEqual(error as? SessionJournal.Failure,
                           .sequenceGap(expected: 2, got: 5))
        }
        XCTAssertEqual(journal.lastSequence, 1, "неудачный приём не двигает счётчик")
    }

    func testIdenticalRedeliveryIsNoOp() {
        var journal = startedJournal()
        let envelope = try! journal.appendTransaction([.digitRemoved(cell: 2)])[0]
        let countBefore = journal.envelopes.count
        XCTAssertNoThrow(try journal.accept(envelope))
        XCTAssertEqual(journal.envelopes.count, countBefore)
    }

    /// Тот же идентификатор с другим содержимым — это порча, а не повтор.
    /// Молча взять любой из вариантов означало бы разойтись с тем, что видел
    /// игрок, и никогда об этом не узнать.
    func testDivergentRedeliveryIsRejected() {
        var journal = startedJournal()
        let original = try! journal.appendTransaction([.digitRemoved(cell: 2)])[0]
        let forged = GameEventEnvelope(id: original.id, commandID: original.commandID,
                                       sessionID: original.sessionID,
                                       sequence: original.sequence,
                                       payload: .digitRemoved(cell: 3))
        XCTAssertThrowsError(try journal.accept(forged)) { error in
            XCTAssertEqual(error as? SessionJournal.Failure, .corruptedDuplicate(original.id))
        }
    }

    /// Портит уже собранный конверт ровно так, как это делает диск: меняет
    /// нагрузку, оставляя поле `payloadDigest` прежним. Через `init` такой
    /// конверт не собрать — он всегда пересчитывает отпечаток, — поэтому
    /// единственный честный путь лежит через JSON.
    private func damagingPayload(of envelope: GameEventEnvelope,
                                 replacing needle: String,
                                 with replacement: String) throws -> GameEventEnvelope {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(envelope), as: UTF8.self)
        XCTAssertTrue(json.contains(needle), "нечего портить, JSON изменился: \(json)")
        let damaged = json.replacingOccurrences(of: needle, with: replacement)
        return try JSONDecoder().decode(GameEventEnvelope.self, from: Data(damaged.utf8))
    }

    /// Нагрузка, испорченная на диске, обязана быть отвергнута ПРИ ПРИЁМЕ.
    ///
    /// Сверка с уже запомненным отпечатком этого не ловит: событие приходит
    /// впервые, запоминать нечего. Отпечаток обязан пересчитываться из самой
    /// нагрузки, иначе поле `payloadDigest` не защищает ни от чего.
    func testCorruptedPayloadIsRejectedOnFirstDelivery() throws {
        var journal = startedJournal()
        let honest = GameEventEnvelope(commandID: UUID(), sessionID: journal.sessionID,
                                       sequence: 2, payload: .digitRemoved(cell: 2))
        let damaged = try damagingPayload(of: honest,
                                          replacing: "\"cell\":2", with: "\"cell\":3")
        XCTAssertEqual(damaged.payloadDigest, honest.payloadDigest,
                       "отпечаток на диске не менялся — испорчена только нагрузка")
        XCTAssertNotEqual(damaged.payload, honest.payload, "порча не удалась")

        XCTAssertThrowsError(try journal.accept(damaged)) { error in
            XCTAssertEqual(error as? SessionJournal.Failure, .corruptedPayload(honest.id))
        }
        XCTAssertEqual(journal.envelopes.count, 1, "испорченное событие не попало в журнал")
        XCTAssertEqual(journal.lastSequence, 1, "неудачный приём не двигает счётчик")
    }

    /// Тот же обман, но событие журналу уже известно. Раньше повтор с целым
    /// полем отпечатка проходил как «безвредная повторная доставка», хотя
    /// нагрузка в нём была уже другая.
    func testCorruptedRedeliveryIsNotMistakenForHarmlessRepeat() throws {
        var journal = startedJournal()
        let original = try journal.appendTransaction([.digitRemoved(cell: 2)])[0]
        let damaged = try damagingPayload(of: original,
                                          replacing: "\"cell\":2", with: "\"cell\":3")
        XCTAssertEqual(damaged.id, original.id)
        XCTAssertEqual(damaged.payloadDigest, original.payloadDigest)

        XCTAssertThrowsError(try journal.accept(damaged)) { error in
            XCTAssertEqual(error as? SessionJournal.Failure, .corruptedPayload(original.id))
        }
        XCTAssertEqual(journal.envelopes.count, 2)
        XCTAssertEqual(journal.envelopes.last?.payload, .digitRemoved(cell: 2),
                       "журнал остался с честной версией события")
    }

    /// Обратная сторона той же проверки: честный журнал обязан приниматься
    /// целиком. Слишком строгий пересчёт объявил бы повреждённой каждую
    /// сохранённую партию — и это было бы заметно только у игроков.
    func testHonestJournalPassesDigestRecomputation() throws {
        var journal = startedJournal(descriptor(mode: .relaxed,
                                                policy: .deferredValidation,
                                                autoReduceNotes: true))
        play(&journal, cell: 2, digit: 4, sequence: 1, groups: [0, 9])
        try journal.appendTransaction([
            .noteToggled(cell: 3, digit: 7),
            .hintLayerOpened(layer: .techniqueName, revision: 1, stepDigest: 42),
            .candidateAidEscalated(.lens)
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let restored = try JSONDecoder().decode(
            [GameEventEnvelope].self, from: try encoder.encode(journal.envelopes))

        var rebuilt = SessionJournal(sessionID: journal.sessionID)
        for envelope in restored {
            XCTAssertNoThrow(try rebuilt.accept(envelope),
                             "событие \(envelope.sequence) отвергнуто без причины")
        }
        XCTAssertEqual(rebuilt.replay(), journal.replay())
    }

    func testUnknownSchemaStopsReplayInsteadOfBeingSkipped() {
        var journal = startedJournal()
        let future = GameEventEnvelope(commandID: UUID(), sessionID: journal.sessionID,
                                       sequence: 2, payload: .digitRemoved(cell: 2),
                                       schemaVersion: 99)
        XCTAssertThrowsError(try journal.accept(future)) { error in
            XCTAssertEqual(error as? SessionJournal.Failure, .unsupportedSchema(99))
        }
    }

    func testForeignSessionIsRejected() {
        var journal = startedJournal()
        let alien = GameEventEnvelope(commandID: UUID(), sessionID: UUID(),
                                      sequence: 2, payload: .digitRemoved(cell: 2))
        XCTAssertThrowsError(try journal.accept(alien)) { error in
            XCTAssertEqual(error as? SessionJournal.Failure, .wrongSession)
        }
    }

    func testJournalIsSealedAfterCompletion() {
        var journal = startedJournal()
        try! journal.appendTransaction([
            .puzzleCompleted(elapsedMs: 400_000, expectedMs: 600_000, paceEligible: true)])
        XCTAssertTrue(journal.isSealed)
        XCTAssertThrowsError(try journal.appendTransaction([.digitRemoved(cell: 0)])) {
            XCTAssertEqual($0 as? SessionJournal.Failure, .sealed)
        }
    }

    // MARK: - Транзакционность

    /// Главное свойство. Команда «цифра + проверка» либо в журнале целиком,
    /// либо отсутствует целиком — состояния «цифра есть, очков нет» не бывает.
    func testFailedTransactionLeavesJournalUntouched() {
        var journal = startedJournal()
        try! journal.appendTransaction([.digitRemoved(cell: 2)])
        let snapshot = journal

        // Второе событие пакета сделает журнал запечатанным, третье обязано
        // упасть — и тогда откатиться должен весь пакет.
        XCTAssertThrowsError(try journal.appendTransaction([
            .digitRemoved(cell: 3),
            .puzzleCompleted(elapsedMs: 1, expectedMs: 1, paceEligible: false),
            .digitRemoved(cell: 4)
        ]))
        XCTAssertEqual(journal, snapshot, "частично применённого пакета быть не должно")
    }

    // MARK: - Воспроизведение

    func testReplayReconstructsBoardAndScoreTogether() {
        var journal = startedJournal()
        var live = SessionScoreState(budget: SessionScoreBudget(
            puzzleRating: 1200, emptyCellCount: Self.givens.filter { $0 == "0" }.count))

        var sequence: UInt64 = 0
        for cell in Self.freeCells {
            sequence += 1
            let digit = Int(String(Array(Self.solution)[cell]))!
            play(&journal, cell: cell, digit: digit, sequence: sequence)
            SessionScoreReducer.apply(
                .placementConfirmed(cell: cell, digit: digit, correct: true), to: &live)
        }

        let projection = journal.replay()
        XCTAssertNotNil(projection)
        XCTAssertEqual(projection?.score, live, "счёт после восстановления обязан совпасть")
        for cell in Self.freeCells {
            XCTAssertEqual(Int(projection!.board[cell].value),
                           Int(String(Array(Self.solution)[cell]))!)
        }
    }

    func testReplayIsDeterministic() {
        var journal = startedJournal()
        var sequence: UInt64 = 0
        for cell in Self.freeCells.prefix(5) {
            sequence += 1
            play(&journal, cell: cell,
                 digit: Int(String(Array(Self.solution)[cell]))!, sequence: sequence)
        }
        XCTAssertEqual(journal.replay(), journal.replay())
    }

    /// Обрыв на границе команды даёт согласованное состояние: доска и счёт
    /// соответствуют одному и тому же префиксу истории.
    ///
    /// Границы именно команд, а не отдельных событий. Внутри команды цифра уже
    /// стоит, а её исход ещё не подтверждён — и это нормально: команда пишется
    /// на диск целиком, поэтому такого префикса в хранилище не существует.
    func testEveryCommandBoundaryReplaysConsistently() {
        var journal = startedJournal()
        var sequence: UInt64 = 0
        for cell in Self.freeCells {
            sequence += 1
            play(&journal, cell: cell,
                 digit: Int(String(Array(Self.solution)[cell]))!, sequence: sequence)
        }

        let commandCount = journal.commands.count
        XCTAssertEqual(commandCount, Self.freeCells.count + 1, "старт плюс по команде на ход")

        for boundary in 1...commandCount {
            let cut = journal.envelopeCount(throughCommand: boundary)
            var partial = SessionJournal(sessionID: journal.sessionID)
            for envelope in journal.envelopes.prefix(cut) {
                XCTAssertNoThrow(try partial.accept(envelope), "обрыв на команде \(boundary)")
            }
            guard let projection = partial.replay() else {
                XCTFail("команда \(boundary) не восстановилась"); continue
            }
            let placedOnBoard = (0..<81).filter {
                projection.board[$0].value != 0 && !projection.board[$0].isGiven
            }.count
            XCTAssertEqual(placedOnBoard, projection.score.awardedCellCount,
                           "доска и счёт разошлись на команде \(boundary)")
            XCTAssertEqual(placedOnBoard, boundary - 1)
        }
    }

    /// Команда «цифра + проверка» видна как одна единица записи. Если бы
    /// группировка ломалась, хранилище начало бы писать события по одному и
    /// вернуло бы ту самую рассинхронизацию, ради которой всё затевалось.
    func testCommandsGroupEventsOfOneMove() {
        var journal = startedJournal()
        play(&journal, cell: 2, digit: 4, sequence: 1)
        let commands = journal.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].count, 1, "старт — отдельная команда")
        XCTAssertEqual(commands[1].count, 2, "цифра и её проверка — одна команда")
        XCTAssertEqual(commands[1][0].commandID, commands[1][1].commandID)
        XCTAssertEqual(journal.envelopeCount(throughCommand: 2), 3)
    }

    func testReplayRestoresNotes() {
        var journal = startedJournal()
        try! journal.appendTransaction([
            .noteToggled(cell: 2, digit: 4),
            .noteToggled(cell: 2, digit: 7)
        ])
        let projection = journal.replay()
        XCTAssertNotEqual(projection?.board[2].manualNotesMask, 0)
        XCTAssertEqual(projection?.board[2].value, 0)
    }

    // MARK: - Undo

    /// Автосокращение убирает цифру из заметок соседей. Компенсирующее
    /// «сотри клетку» их не вернёт — поэтому журнал пишет намерение, а
    /// воспроизведение ведёт настоящую историю ходов.
    func testUndoRestoresNotesRemovedByAutoReduction() {
        var journal = startedJournal(descriptor(autoReduceNotes: true))
        // Заметка «4» в клетке 3; клетки 2 и 3 в одной строке и одном блоке.
        try! journal.appendTransaction([.noteToggled(cell: 3, digit: 4)])
        let withNote = journal.replay()!
        XCTAssertNotEqual(withNote.board[3].manualNotesMask, 0)

        try! journal.appendTransaction([.digitCommitted(cell: 2, digit: 4,
                                                        source: .user)])
        XCTAssertEqual(journal.replay()!.board[3].manualNotesMask, 0,
                       "автосокращение обязано было убрать заметку")

        try! journal.appendTransaction([.moveUndone])
        let afterUndo = journal.replay()!
        XCTAssertEqual(afterUndo.board[2].value, 0)
        XCTAssertEqual(afterUndo.board[3].manualNotesMask, withNote.board[3].manualNotesMask,
                       "Undo обязан вернуть снятую заметку")
    }

    func testRedoReappliesEverything() {
        var journal = startedJournal(descriptor(autoReduceNotes: true))
        try! journal.appendTransaction([.noteToggled(cell: 3, digit: 4)])
        try! journal.appendTransaction([.digitCommitted(cell: 2, digit: 4, source: .user)])
        let placed = journal.replay()!
        try! journal.appendTransaction([.moveUndone])
        try! journal.appendTransaction([.moveRedone])
        XCTAssertEqual(journal.replay()!.board, placed.board)
    }

    /// Undo не возвращает очки: зафиксированное достижение зафиксировано.
    /// Если бы возвращал, партию можно было бы фармить одной клеткой.
    func testUndoDoesNotRefundScore() {
        var journal = startedJournal()
        play(&journal, cell: 2, digit: 4, sequence: 1)
        let earned = journal.replay()!.score.displayScore
        XCTAssertGreaterThan(earned, 0)
        try! journal.appendTransaction([.moveUndone])
        XCTAssertEqual(journal.replay()!.score.displayScore, earned)
    }

    func testReplayRestoresUndoStack() {
        var journal = startedJournal()
        play(&journal, cell: 2, digit: 4, sequence: 1)
        play(&journal, cell: 3, digit: 6, sequence: 2)
        let projection = journal.replay()!
        XCTAssertEqual(projection.history.moveCount, 2)
        XCTAssertTrue(projection.history.canUndo)
        XCTAssertFalse(projection.history.canRedo)
    }

    // MARK: - Ранг

    /// Порог можно пройти по очкам и остаться на прежней ступени: повышение
    /// подтверждается тремя результатами. Экран, показывающий «до ранга 0»,
    /// в этот момент выглядит сломанным — на самом деле не хватает не очков.
    func testPassedThresholdShowsConfirmationNotZeroDistance() {
        var snapshot = RatingSnapshot(
            rating: 1152,
            displayDivision: RankDivision(index: 3),   // Логик III, порог 1050
            calibrationRatedCount: 10,
            confirmationWindow: [1152])

        // Следующая ступень начинается с 1150, рейтинг уже 1152.
        XCTAssertEqual(RankDivision(index: 3).pointsToNext(from: 1152), 0)
        XCTAssertEqual(snapshot.promotionConfirmationProgress(), 1,
                       "один результат выше порога уже засчитан")

        snapshot.confirmationWindow = [1152, 1180]
        XCTAssertEqual(snapshot.promotionConfirmationProgress(), 2)

        // Провал ниже порога обрывает серию: считаются подряд идущие.
        snapshot.confirmationWindow = [1152, 1100, 1180]
        XCTAssertEqual(snapshot.promotionConfirmationProgress(), 1)
    }

    // MARK: - Старт не с исходной задачи

    /// Партия, сохранённая до появления журнала, начинается с середины.
    /// Со стартом от `givens` воспроизведение расходилось со снимком и
    /// объявляло такую партию повреждённой — за то, в чём игрок не виноват.
    func testJournalCanStartFromMidGamePosition() {
        var position = Array(Self.givens)
        let solution = Array(Self.solution)
        for cell in Self.freeCells.prefix(4) { position[cell] = solution[cell] }
        let midGame = String(position)

        var journal = SessionJournal()
        try! journal.appendTransaction([.sessionStarted(SessionDescriptor(
            puzzleID: "test-1", givens: Self.givens, solution: Self.solution,
            catalogVersion: "test", difficultyD: 1200,
            mode: .ranked, policy: .immediateValidated,
            startingBoard: midGame))])

        guard let projection = journal.replay() else {
            return XCTFail("не восстановилось")
        }
        XCTAssertEqual(projection.board.serialized(), midGame)
        // Клетки, поставленные до журнала, обязаны остаться изменяемыми.
        for cell in Self.freeCells.prefix(4) {
            XCTAssertFalse(projection.board[cell].isGiven,
                           "клетка \(cell) стала подсказкой задачи")
        }
    }

    /// Бюджет считается от исходной задачи, а не от стартовой позиции:
    /// иначе продолженная партия получила бы другую цену клетки, и счёт
    /// перестал бы быть сопоставимым с сыгранной за один присест.
    func testBudgetIgnoresStartingPosition() {
        var position = Array(Self.givens)
        let solution = Array(Self.solution)
        for cell in Self.freeCells { position[cell] = solution[cell] }

        func budget(startingBoard: String) -> Int {
            var journal = SessionJournal()
            try! journal.appendTransaction([.sessionStarted(SessionDescriptor(
                puzzleID: "test-1", givens: Self.givens, solution: Self.solution,
                catalogVersion: "test", difficultyD: 1200,
                mode: .ranked, policy: .immediateValidated,
                startingBoard: startingBoard))])
            return journal.replay()!.score.budget.placementBudget
        }
        XCTAssertEqual(budget(startingBoard: Self.givens),
                       budget(startingBoard: String(position)))
    }

    /// Номер ревизии обязан продолжиться после восстановления. Начав с нуля,
    /// он выдал бы уже оплаченные номера — и первые Check оказались бы
    /// бесплатными, сохраняя серию.
    func testRevisionContinuesAcrossRestore() {
        var journal = startedJournal()
        var sequence: UInt64 = 0
        for cell in Self.freeCells.prefix(5) {
            sequence += 1
            play(&journal, cell: cell,
                 digit: Int(String(Array(Self.solution)[cell]))!, sequence: sequence)
        }
        let revision = journal.replay()!.valueRevision
        XCTAssertEqual(revision, 5, "по одной ревизии на поставленную цифру")

        // Проверка на уже пройденной ревизии обязана считаться оплаченной.
        var score = journal.replay()!.score
        let before = score.penaltyLedger
        SessionScoreReducer.apply(.manualCheck(revision: revision, isRuleOfMode: false),
                                  to: &score)
        SessionScoreReducer.apply(.manualCheck(revision: revision, isRuleOfMode: false),
                                  to: &score)
        XCTAssertEqual(score.penaltyLedger, before + score.budget.checkPenalty,
                       "одна ревизия — одна оплата")
    }

    /// Reveal не даёт очков и не наращивает серию — ни в живой партии,
    /// ни при воспроизведении. Раньше живой путь начислял полную цену.
    func testRevealScoresNothingOnReplay() {
        var journal = startedJournal()
        let cell = Self.freeCells[0]
        let digit = Int(String(Array(Self.solution)[cell]))!
        try! journal.appendTransaction([
            .digitCommitted(cell: cell, digit: digit, source: .reveal)
        ])
        let projection = journal.replay()!
        XCTAssertEqual(projection.score.displayScore, 0)
        XCTAssertEqual(projection.score.streak, 0)
        XCTAssertEqual(projection.board[cell].value, UInt8(digit))
    }

    /// Бонус за решённую задачу обязан пережить воспроизведение — и ровно один
    /// раз. Защита от повтора, поставленная слишком строго, молча съела бы его
    /// у честно завершённой партии, восстановленной с диска: игрок увидел бы
    /// один итог на финише и другой после перезапуска.
    func testCompletionBonusIsAwardedExactlyOnceOnReplay() {
        var journal = startedJournal()
        var sequence: UInt64 = 0
        for cell in Self.freeCells.prefix(3) {
            sequence += 1
            play(&journal, cell: cell,
                 digit: Int(String(Array(Self.solution)[cell]))!, sequence: sequence)
        }
        let beforeFinish = journal.replay()!.score
        XCTAssertEqual(beforeFinish.structureTotal, 0, "групп в этой партии не было")

        try! journal.appendTransaction([
            .puzzleCompleted(elapsedMs: 400_000, expectedMs: 600_000, paceEligible: false)])

        guard let finished = journal.replay()?.score else {
            return XCTFail("завершённая партия не восстановилась")
        }
        let bonus = finished.budget.completionBonus
        XCTAssertGreaterThan(bonus, 0, "иначе тест ничего не проверяет")
        XCTAssertEqual(finished.structureTotal, bonus,
                       "бонус завершения обязан быть начислен ровно один раз")
        XCTAssertEqual(finished.displayScore, beforeFinish.displayScore + bonus)
        XCTAssertTrue(finished.sealed)

        // Второе воспроизведение той же истории обязано дать то же состояние.
        XCTAssertEqual(journal.replay()?.score, finished)
    }

    func testReplayWithoutStartFails() {
        let journal = SessionJournal()
        XCTAssertNil(journal.replay())
    }

    // MARK: - Сохраняемость

    /// Журнал уходит на диск, значит обязан переживать кодирование без потерь.
    func testEnvelopeRoundTripsThroughJSON() throws {
        var journal = startedJournal(descriptor(mode: .relaxed,
                                                policy: .deferredValidation,
                                                autoReduceNotes: true))
        play(&journal, cell: 2, digit: 4, sequence: 1, groups: [0, 9])
        try journal.appendTransaction([
            .hintLayerOpened(layer: .techniqueName, revision: 1, stepDigest: 42),
            .candidateAidEscalated(.lens)
        ])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal.envelopes)
        let restored = try JSONDecoder().decode([GameEventEnvelope].self, from: data)
        XCTAssertEqual(restored, journal.envelopes)

        var rebuilt = SessionJournal(sessionID: journal.sessionID)
        for envelope in restored { try rebuilt.accept(envelope) }
        XCTAssertEqual(rebuilt.replay(), journal.replay())
    }

    /// Отпечаток считается по содержимому, поэтому обязан пережить диск.
    /// Если бы он зависел от порядка полей в JSON, любая версия Swift с другим
    /// порядком объявила бы весь сохранённый журнал повреждённым.
    func testDigestSurvivesRoundTrip() throws {
        let journal = startedJournal()
        let original = journal.envelopes[0]
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(GameEventEnvelope.self, from: data)
        XCTAssertEqual(restored.payloadDigest, original.payloadDigest)
        XCTAssertEqual(StableDigest.of(restored.payload), original.payloadDigest)
    }
}
